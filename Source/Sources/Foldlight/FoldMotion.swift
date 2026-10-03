import Foundation

struct FoldMotion {
    private(set) var value = 0.0
    private(set) var velocity = 0.0

    mutating func reset() { value = 0; velocity = 0 }

    mutating func advance(to target: Double, delta: Double) -> Double {
        guard target.isFinite, delta.isFinite, delta > 0 else { return value }
        // Exact critically damped response: fluid starts and stops without bounce.
        let frequency = 46.0
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
            return t * t * t * (t * (t * 6 - 15) + 10)
        }
        if time < 0.5 { return 0 }
        if time < 2.9 { return 0.93 * smoother((time - 0.5) / 2.4) }
        if time < 3.5 { return 0.93 }
        if time < 6.2 { return 0.93 * (1 - smoother((time - 3.5) / 2.7)) }
        return 0
    }
}
