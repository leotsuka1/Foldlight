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
        try check(FoldMotion.preview(at: 3) == 0.97, "Preview pauses at closed position")
        for time in [0.0, 0.55, 2.95, 3.0, 3.5, 6.4, 8.0] {
            try check(abs(FoldMotion.previewVelocity(at: time)) < 1e-10, "Preview rests smoothly at each boundary")
        }
        for time in stride(from: 0.6, through: 6.3, by: 0.05) {
            let derivative = (FoldMotion.preview(at: time + 0.00001) - FoldMotion.preview(at: time - 0.00001)) / 0.00002
            try check(abs(derivative - FoldMotion.previewVelocity(at: time)) < 1e-6, "Exposure follows actual preview speed")
        }
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
        try verifyOptics(renderer, check: check)
    }

    private static func verifyOptics(_ renderer: FoldRenderer, check: (Bool, String) throws -> Void) throws {
        let width = 1280, height = 800
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .renderTarget]
        guard let source = renderer.device.makeTexture(descriptor: descriptor),
              let output = renderer.device.makeTexture(descriptor: descriptor) else {
            throw Failure(description: "Optical test textures unavailable")
        }
        var pattern = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let shade: UInt8 = (x / 4 + y / 4) % 2 == 0 ? 40 : 220
            let offset = (y * width + x) * 4
            pattern[offset] = shade; pattern[offset + 1] = shade; pattern[offset + 2] = shade
        } }
        source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                       withBytes: pattern, bytesPerRow: width * 4)
        renderer.texture = source
        func render(progress: Float, softness: Float, motion: Float = 0) throws -> [UInt8] {
            renderer.progress = progress; renderer.softness = softness; renderer.motion = motion
            guard let command = renderer.queue.makeCommandBuffer() else { throw Failure(description: "Optical test command unavailable") }
            renderer.encode(to: output, command: command); command.commit(); command.waitUntilCompleted()
            try check(command.status == .completed, "Optical render completes")
            var data = [UInt8](repeating: 0, count: pattern.count)
            output.getBytes(&data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return data
        }
        let open = try render(progress: 0, softness: 1.5, motion: 1)
        try check(zip(open, pattern).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 1 }, "Native sharp pixels survive maximum softness when open")
        func detail(_ data: [UInt8]) -> Int {
            var energy = 0
            for y in 420..<600 { for x in 400..<800 {
                let index = (y * width + x) * 4
                energy += abs(Int(data[index]) - Int(data[index + 4]))
            } }
            return energy
        }
        let clear = try render(progress: 0.5, softness: 0)
        let soft = try render(progress: 0.5, softness: 0.95)
        let softer = try render(progress: 0.5, softness: 1.5)
        try check(detail(soft) < detail(clear) / 3, "Progressive blur removes fine detail")
        try check(detail(softer) <= detail(soft), "Softness control increases blur monotonically")
        let moving = try render(progress: 0.5, softness: 0.95, motion: 1)
        try check(detail(moving) <= detail(soft), "Motion exposure softens rather than sharpens")
        print("PASS: progressive optical blur, motion exposure, and native sharp endpoint")
    }
}
