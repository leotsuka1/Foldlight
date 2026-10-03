import AppKit
import MetalKit

enum DemoDesktop {
    static func image() -> CGImage {
        let width = 1280, height = 800
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let background = NSGradient(colors: [NSColor(red: 0.02, green: 0.17, blue: 0.20, alpha: 1),
            NSColor(red: 0.16, green: 0.46, blue: 0.43, alpha: 1),
            NSColor(red: 0.64, green: 0.86, blue: 0.73, alpha: 1)])!
        background.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 38)
        for i in 0..<5 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: -100, y: -120 + i * 100))
            path.curve(to: NSPoint(x: 1400, y: 200 + i * 120),
                controlPoint1: NSPoint(x: 200, y: 640 + i * 80), controlPoint2: NSPoint(x: 900, y: -260 + i * 100))
            path.line(to: NSPoint(x: 1400, y: -100)); path.line(to: NSPoint(x: -100, y: -100)); path.close()
            NSColor.white.withAlphaComponent(0.035 + Double(i) * 0.02).setFill(); path.fill()
        }
        func card(_ rect: NSRect, opacity: Double = 0.12) {
            NSColor.white.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
        }
        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, alpha: Double = 1) {
            (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
        }
        NSColor.black.withAlphaComponent(0.13).setFill(); NSRect(x: 0, y: 774, width: 1280, height: 26).fill()
        text("◉   Finder     File     Edit     View     Go     Window     Help", x: 20, y: 780, size: 12, weight: .medium)
        text("Sample desktop     9:41", x: 1080, y: 780, size: 12)
        card(NSRect(x: 40, y: 554, width: 194, height: 180))
        text("FRIDAY", x: 62, y: 698, size: 11, weight: .semibold, alpha: 0.7)
        text("02", x: 59, y: 600, size: 82, weight: .light)
        text("A fresh perspective.", x: 62, y: 578, size: 13, alpha: 0.8)
        card(NSRect(x: 250, y: 554, width: 210, height: 180))
        text("☀", x: 270, y: 652, size: 38)
        text("23°", x: 270, y: 596, size: 48, weight: .light)
        text("Clear skies", x: 270, y: 578, size: 13, alpha: 0.8)
        text("Everything", x: 675, y: 420, size: 68, weight: .light)
        text("has a little", x: 675, y: 340, size: 68, weight: .light)
        text("give.", x: 675, y: 260, size: 68, weight: .semibold)
        text("F O L D L I G H T", x: 679, y: 218, size: 12, weight: .medium, alpha: 0.65)
        card(NSRect(x: 385, y: 16, width: 510, height: 70), opacity: 0.2)
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemPink, .systemGreen, .systemTeal, .systemGray, .systemIndigo]
        for (index, color) in palette.enumerated() {
            let rect = NSRect(x: 405 + index * 60, y: 29, width: 44, height: 44)
            color.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            text(["F", "◎", "✦", "♫", "●", "↗", "⚙", "▤"][index], x: rect.minX + 12, y: rect.minY + 9, size: 23, weight: .medium)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func texture(device: MTLDevice) -> MTLTexture? {
        try? MTKTextureLoader(device: device).newTexture(cgImage: image(), options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
    }

    static func renderCheck(to directory: String) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let renderer = FoldRenderer()
        renderer.texture = texture(device: renderer.device)
        guard let source = renderer.texture else { throw NSError(domain: "Foldlight", code: 2) }
        for (name, progress) in [("Open", Float(0)), ("Half-fold", Float(0.5)), ("Closed", Float(0.88)),
                                 ("Closing-94", Float(0.94)), ("Closing-97", Float(0.97)), ("Closing-99", Float(0.99))] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: source.width, height: source.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
            let output = renderer.device.makeTexture(descriptor: descriptor)!
            renderer.progress = progress
            let command = renderer.queue.makeCommandBuffer()!
            renderer.encode(to: output, command: command); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw command.error ?? NSError(domain: "Foldlight", code: 3) }
            var pixels = [UInt8](repeating: 0, count: source.width * source.height * 4)
            output.getBytes(&pixels, bytesPerRow: source.width * 4, from: MTLRegionMake2D(0, 0, source.width, source.height), mipmapLevel: 0)
            // BGRA is converted to RGBA for the PNG encoder.
            for offset in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(offset, offset + 2) }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: source.width, height: source.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: source.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            print("Rendered \(name)")
        }
    }
}
