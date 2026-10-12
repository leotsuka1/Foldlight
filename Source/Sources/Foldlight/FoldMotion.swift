import Foundation

struct FoldMotion {
    private(set) var value = 0.0
    private(set) var velocity = 0.0

    mutating func reset() { value = 0; velocity = 0 }

    mutating func advance(to target: Double, delta: Double) -> Double {
        guard target.isFinite, delta.isFinite, delta > 0 else { return value }
        // Exact critically damped response: fluid starts and stops without bounce.
        let frequency = 36.0
        let boundedTarget = min(1, max(0, target))
        let displacement = value - boundedTarget
        let impulse = velocity + frequency * displacement
        let decay = exp(-frequency * delta)
        value = boundedTarget + (displacement + impulse * delta) * decay
        velocity = (velocity - frequency * impulse * delta) * decay
        value = min(1, max(0, value))
        if value == 0 || value == 1 { velocity = 0 }
        return value
    }

    static let previewDuration = 8.0

    static func preview(at time: Double) -> Double {
        func smoother(_ x: Double) -> Double {
            let t = min(1, max(0, x))
            // Zero velocity, acceleration and jerk at both ends.
            return t * t * t * t * (35 + t * (-84 + t * (70 - 20 * t)))
        }
        if time < 0.55 { return 0 }
        if time < 2.95 { return 0.97 * smoother((time - 0.55) / 2.4) }
        if time < 3.5 { return 0.97 }
        if time < 6.4 { return 0.97 * (1 - smoother((time - 3.5) / 2.9)) }
        return 0
    }

    static func previewVelocity(at time: Double) -> Double {
        let start: Double, duration: Double, direction: Double
        if time >= 0.55 && time < 2.95 { start = 0.55; duration = 2.4; direction = 1 }
        else if time >= 3.5 && time < 6.4 { start = 3.5; duration = 2.9; direction = -1 }
        else { return 0 }
        let t = (time - start) / duration
        return direction * 0.97 * 140 * pow(t * (1 - t), 3) / duration
    }
}
