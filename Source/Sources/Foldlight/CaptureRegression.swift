import AppKit
import CoreVideo
import Metal

enum CaptureRegression {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    @MainActor static func run() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw Failure(reason: "Screen recording access is required for the live capture check.")
        }
        guard let screen = NSScreen.screens.first(where: {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) != 0
        }), let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw Failure(reason: "A built-in display is required for the live capture check.")
        }
        let renderer = FoldRenderer()
        let overlay = OverlayWindow(screen: screen, renderer: renderer)
        let settings = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 300, height: 120),
                                styleMask: [.titled], backing: .buffered, defer: false)
        settings.title = "Foldlight capture check"; settings.isReleasedWhenClosed = false
        settings.orderFrontRegardless(); settings.close()
        defer { overlay.close(); settings.close() }
        let windowID = overlay.registerForCapture()
        let capture = ScreenCapture()
        try await capture.start(displayID: number.uint32Value, excludingWindowIDs: [windowID])
        do {
            for _ in 0..<100 where capture.latest() == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            guard let baseline = capture.latest() else { throw Failure(reason: "The capture stream produced no complete frames.") }
            let baselineCount = markerCount(baseline)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let marker = renderer.device.makeTexture(descriptor: descriptor) else {
                throw Failure(reason: "Unable to prepare the regression marker.")
            }
            var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
            for offset in stride(from: 0, to: pixels.count, by: 4) { pixels[offset + 1] = 0 }
            marker.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 64 * 4)
            renderer.texture = marker; renderer.progress = 0.5
            overlay.redraw(); overlay.reveal()
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 40_000_000)
                overlay.redraw()
                guard let frame = capture.latest() else { throw Failure(reason: "The capture stream lost its frames.") }
                guard markerCount(frame) <= baselineCount + 20 else {
                    throw Failure(reason: "The animation appeared in its own capture stream.")
                }
            }
            overlay.orderOut(nil)
            await capture.stop()
            // Repeatedly hide/register/show the same window without any settings window.
            let secondID = overlay.registerForCapture()
            guard secondID == windowID else { throw Failure(reason: "The animation window ID changed after hiding.") }
            try await capture.start(displayID: number.uint32Value, excludingWindowIDs: [secondID])
            for _ in 0..<100 where capture.latest() == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            overlay.redraw(); overlay.reveal()
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let second = capture.latest(), markerCount(second) <= baselineCount + 20 else {
                throw Failure(reason: "Capture restarted without excluding the animation.")
            }
            overlay.orderOut(nil); await capture.stop()
            print("PASS: live capture excludes the overlay with settings closed and after restarting capture")
        } catch {
            overlay.orderOut(nil); await capture.stop(); throw error
        }
    }

    private static func markerCount(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let pixels = address.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var count = 0
        for y in stride(from: height / 2, to: height - 20, by: max(1, height / 80)) {
            for x in stride(from: width / 8, to: width * 7 / 8, by: max(1, width / 80)) {
                let index = y * rowBytes + x * 4
                if pixels[index] > 100 && pixels[index + 2] > 100 && pixels[index + 1] < 30 { count += 1 }
            }
        }
        return count
    }
}
