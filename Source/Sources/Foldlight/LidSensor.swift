import Foundation
import IOKit.hid

// Feature report layout documented by samhenrigold/LidAngleSensor.
final class LidSensor {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var device: IOHIDDevice?

    init() {
        let match = [kIOHIDVendorIDKey: 0x05AC,
                     kIOHIDDeviceUsagePageKey: 0x20,
                     kIOHIDDeviceUsageKey: 0x8A] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, match)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { continue }
            if Self.read(candidate) != nil { device = candidate; break }
            IOHIDDeviceClose(candidate, 0)
        }
    }

    private static func read(_ device: IOHIDDevice) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 8)
        var size = bytes.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &size)
        guard result == kIOReturnSuccess, size >= 3 else { return nil }
        let degrees = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard degrees <= 180 else { return nil }
        return Double(degrees)
    }

    func angle() -> Double? { device.flatMap { Self.read($0) } }

    deinit {
        if let device { IOHIDDeviceClose(device, 0) }
        IOHIDManagerClose(manager, 0)
    }
}

enum FoldMath {
    static func progress(angle: Double, threshold: Double) -> Double {
        guard angle.isFinite, threshold.isFinite, threshold > 0 else { return 0 }
        return min(1, max(0, (threshold - angle) / threshold))
    }

    static func smoothing(previous: Double, target: Double, delta: Double) -> Double {
        previous + (target - previous) * (1 - exp(-max(0, delta) / 0.042))
    }
}
