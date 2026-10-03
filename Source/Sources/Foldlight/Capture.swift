import AppKit
import ScreenCaptureKit
import CoreMedia

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var acceptedStreamID: ObjectIdentifier?
    private(set) var running = false
    var onFailure: ((String) -> Void)?

    func start(displayID: CGDirectDisplayID, excludingWindowIDs: Set<CGWindowID>) async throws {
        // Include offscreen windows: a menu bar app need not have an open settings window.
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        for _ in 0..<3 where !excludingWindowIDs.isSubset(of: Set(content.windows.map(\.windowID))) {
            try await Task.sleep(nanoseconds: 80_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "Foldlight", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in display is unavailable."])
        }
        let identities = content.windows.map { window in
            CaptureWindowIdentity(id: window.windowID, processID: window.owningApplication?.processID,
                                  bundleID: window.owningApplication?.bundleIdentifier)
        }
        let excluded = try CaptureExclusion.windowIDs(identities, required: excludingWindowIDs,
            processID: getpid(), bundleID: Bundle.main.bundleIdentifier)
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains($0.windowID) })
        let config = SCStreamConfiguration()
        config.width = CGDisplayPixelsWide(displayID)
        config.height = CGDisplayPixelsHigh(displayID)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3; config.showsCursor = true; config.capturesAudio = false
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Foldlight.capture"))
        stream = newStream
        lock.withLock { acceptedStreamID = ObjectIdentifier(newStream); frame = nil }
        do { try await newStream.startCapture(); running = true }
        catch {
            stream = nil
            lock.withLock { acceptedStreamID = nil; frame = nil }
            throw error
        }
    }

    func stop() async {
        let old = stream; stream = nil; running = false
        lock.withLock { acceptedStreamID = nil; frame = nil }
        try? await old?.stopCapture()
    }

    func latest() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return frame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock {
            guard acceptedStreamID == ObjectIdentifier(stream) else { return }
            frame = image
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.running = false; self.onFailure?(error.localizedDescription)
        }
    }
}
