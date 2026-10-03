import Foundation
import CoreGraphics

struct CaptureWindowIdentity {
    let id: CGWindowID
    let processID: pid_t?
    let bundleID: String?
}

enum CaptureExclusion {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "The animation window could not be excluded from screen capture. Please reopen Foldlight."
        }
    }

    static func windowIDs(_ windows: [CaptureWindowIdentity], required: Set<CGWindowID>,
                          processID: pid_t, bundleID: String?) throws -> Set<CGWindowID> {
        let excluded = Set(windows.filter { window in
            required.contains(window.id) || window.processID == processID ||
                (bundleID != nil && window.bundleID == bundleID)
        }.map(\.id))
        // Never start an unfiltered display stream if our hidden app is absent.
        guard !required.isEmpty, !required.contains(0), required.isSubset(of: excluded) else {
            throw Failure()
        }
        return excluded
    }
}
