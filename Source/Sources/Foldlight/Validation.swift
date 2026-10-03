import Foundation
import MetalKit
import CoreVideo

// Dependency-free verification, usable with Command Line Tools alone.
enum Validation {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() throws {
        func check(_ condition: Bool, _ label: String) throws {
            if !condition { throw Failure(description: "FAIL: \(label)") }
        }
        let closedSettingsWindows = [
            CaptureWindowIdentity(id: 42, processID: nil, bundleID: nil),
            CaptureWindowIdentity(id: 43, processID: 100, bundleID: "local.foldlight.mac"),
            CaptureWindowIdentity(id: 44, processID: 200, bundleID: "local.foldlight.mac"),
            CaptureWindowIdentity(id: 45, processID: 300, bundleID: "another.app")
        ]
        let exclusions = try CaptureExclusion.windowIDs(closedSettingsWindows, required: [42], processID: 100, bundleID: "local.foldlight.mac")
        try check(exclusions == [42, 43, 44], "Hidden overlay excluded even without visible app metadata")
        var rejectedMissingOverlay = false
        do {
            _ = try CaptureExclusion.windowIDs(Array(closedSettingsWindows.dropFirst()), required: [42], processID: 100, bundleID: "local.foldlight.mac")
        } catch { rejectedMissingOverlay = true }
        try check(rejectedMissingOverlay, "Capture refuses a missing overlay exclusion")
        print("PASS: closed settings window cannot remove overlay exclusion")
        for (angle, expected) in [(120.0, 0.0), (100, 0), (50, 0.5), (0, 1), (-10, 1)] {
            try check(FoldMath.progress(angle: angle, threshold: 100) == expected, "Lid mapping at \(angle)°")
        }
        try check(FoldMath.progress(angle: .nan, threshold: 100) == 0, "Invalid angle")
        try check(FoldMath.progress(angle: 30, threshold: 0) == 0, "Invalid threshold")
        print("PASS: lid angle endpoints, threshold and invalid readings")
        var singleMotion = FoldMotion(), doubleMotion = FoldMotion()
        let once = singleMotion.advance(to: 1, delta: 1 / 30)
        _ = doubleMotion.advance(to: 1, delta: 1 / 60)
        let twice = doubleMotion.advance(to: 1, delta: 1 / 60)
        try check(abs(once - twice) < 1e-10, "Smoothing frame independence")
        try check(singleMotion.advance(to: 1, delta: 0) == once, "Zero-time smoothing")
        var tracker = FoldMotion()
        var previous = 0.0
        for _ in 0..<180 {
            let value = tracker.advance(to: 1, delta: 1 / 120)
            try check(value >= previous && value <= 1, "Closing has no bounce")
            previous = value
        }
        for _ in 0..<180 {
            let value = tracker.advance(to: 0, delta: 1 / 120)
            try check(value <= previous && value >= 0, "Opening has no bounce")
            previous = value
        }
        try check(FoldMotion.preview(at: 0) == 0 && FoldMotion.preview(at: 8) == 0, "Preview ends open")
        try check(FoldMotion.preview(at: 3) == 0.93, "Preview pauses at closed position")
        print("PASS: smooth motion at different frame rates")
        let renderer = FoldRenderer()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .renderTarget]
        guard let source = renderer.device.makeTexture(descriptor: descriptor),
              let output = renderer.device.makeTexture(descriptor: descriptor) else {
            throw Failure(description: "GPU texture allocation failed")
        }
        let input = [UInt8](repeating: 180, count: 64 * 64 * 4)
        source.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: input, bytesPerRow: 64 * 4)
        renderer.texture = source
        func render(_ progress: Float) throws -> [UInt8] {
            renderer.progress = progress
            guard let command = renderer.queue.makeCommandBuffer() else { throw Failure(description: "GPU command creation failed") }
            renderer.encode(to: output, command: command); command.commit(); command.waitUntilCompleted()
            try check(command.status == .completed, "GPU command completed")
            var data = [UInt8](repeating: 0, count: 64 * 64 * 4)
            output.getBytes(&data, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            return data
        }
        let open = try render(0)
        let upper = (8 * 64 + 32) * 4, lower = (59 * 64 + 32) * 4
        try check(abs(Int(open[upper]) - 180) <= 1 && abs(Int(open[lower]) - 180) <= 1, "Open desktop preserves pixels")
        print("PASS: open desktop renders correctly")
        try check(open[0] == 180 && open[(64 * 64 - 1) * 4] == 180, "Open screen edges remain intact")
        let folded = try render(0.65)
        try check(folded[upper] < 4 && folded[lower] > 0, "Desktop folds toward bottom hinge")
        print("PASS: folded desktop geometry and shading")
        let reopened = try render(0)
        try check(reopened[upper] == open[upper], "Reopening restores original pixels")
        print("PASS: reopening restores desktop")
        func frame(color: UInt8) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let properties = [kCVPixelBufferMetalCompatibilityKey as String: true,
                              kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, properties, &buffer) == kCVReturnSuccess,
                  let buffer else { throw Failure(description: "Capture test buffer allocation failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                base.initializeMemory(as: UInt8.self, repeating: color, count: CVPixelBufferGetBytesPerRow(buffer) * 64)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }
        let captured = try frame(color: 180)
        renderer.update(captured)
        renderer.texture = nil
        renderer.update(captured)
        try check(renderer.texture != nil, "Same captured frame restores after preview source switch")
        let firstFrame = try render(0.65)
        renderer.update(try frame(color: 40))
        let changedFrame = try render(0.65)
        let contentPoint = (47 * 64 + 32) * 4
        try check(Int(firstFrame[contentPoint]) - Int(changedFrame[contentPoint]) > 60,
                  "Blur updates when frame dimensions are unchanged")
        for progress: Float in [0.94, 0.97, 0.99, 1] {
            let closed = try render(progress)
            try check(closed[upper] < 4, "Late closure stays behind the hinge")
        }
        print("PASS: source restoration, live blur refresh, and final closure")
    }
}
