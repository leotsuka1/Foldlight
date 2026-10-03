import AppKit
import AVFoundation
import CoreVideo
import Metal

/// Exports the same Metal effect used by the live overlay, with a sample desktop.
enum PreviewMovie {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func export(to path: String) throws {
        _ = NSApplication.shared
        let width = 1280, height = 800, framesPerSecond: Int32 = 60
        let duration = FoldMotion.previewDuration
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".foldlight-preview-\(UUID().uuidString).mp4")
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: temporary) } }

        let renderer = FoldRenderer()
        renderer.softness = 0.85
        renderer.texture = DemoDesktop.texture(device: renderer.device)
        guard renderer.texture != nil else { throw Failure(description: "Unable to create the preview desktop.") }

        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: Int(framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: Int(framesPerSecond),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = framesPerSecond
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        guard writer.canAdd(input) else { throw Failure(description: "The video encoder is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(description: "Unable to start the preview encoder.") }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw Failure(description: "Unable to allocate video frames.")
        }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache else {
            writer.cancelWriting()
            throw Failure(description: "Unable to connect Metal to the video encoder.")
        }

        do {
            for index in 0..<Int(duration * Double(framesPerSecond)) {
                try autoreleasepool {
                    let deadline = Date().addingTimeInterval(20)
                    while !input.isReadyForMoreMediaData {
                        guard writer.status == .writing else {
                            throw writer.error ?? Failure(description: "The preview encoder stopped.")
                        }
                        guard Date() < deadline else { throw Failure(description: "The preview encoder did not accept the next frame.") }
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                          let buffer else { throw Failure(description: "Unable to allocate a preview frame.") }
                    var mapped: CVMetalTexture?
                    let attributes = [kCVMetalTextureUsage as String: MTLTextureUsage.renderTarget.rawValue] as CFDictionary
                    guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer,
                        attributes, .bgra8Unorm, width, height, 0, &mapped) == kCVReturnSuccess,
                          let mapped, let output = CVMetalTextureGetTexture(mapped),
                          let command = renderer.queue.makeCommandBuffer() else {
                        throw Failure(description: "Unable to prepare a preview frame for Metal.")
                    }
                    renderer.progress = Float(FoldMotion.preview(at: Double(index) / Double(framesPerSecond)))
                    renderer.encode(to: output, command: command)
                    command.commit()
                    command.waitUntilCompleted()
                    // The writer may retain the buffer after append; the adaptor owns that lifetime.
                    // Until append, keep both the IOSurface and its Metal wrapper alive through rendering.
                    withExtendedLifetime((buffer, mapped)) {}
                    guard command.status == .completed else {
                        throw command.error ?? Failure(description: "Metal could not render a preview frame.")
                    }
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: framesPerSecond)) else {
                        throw writer.error ?? Failure(description: "Unable to encode a preview frame.")
                    }
                }
            }
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: framesPerSecond))
            input.markAsFinished()
            let completion = DispatchSemaphore(value: 0)
            // Invoke finalization from a worker queue, so the callback never depends on an AppKit run loop.
            DispatchQueue.global(qos: .userInitiated).async {
                writer.finishWriting { completion.signal() }
            }
            guard completion.wait(timeout: .now() + 45) == .success else {
                throw Failure(description: "The preview encoder timed out while finishing the movie.")
            }
            guard writer.status == .completed else {
                throw writer.error ?? Failure(description: "Unable to finish the preview movie.")
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        finished = true
        print("Exported 8-second preview: \(destination.path)")
    }

}
