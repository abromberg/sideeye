import Foundation

enum EyeState: Equatable {
    case neutral, onTask, offTask, resting

    var pose: EyePose {
        switch self {
        case .neutral: EyePose()
        case .onTask: EyePose(green: 1)
        case .offTask: EyePose(open: 0.62, pupilX: 12.35, red: 1)
        case .resting: EyePose(open: 0, lidLine: 0)
        }
    }
}

struct EyePose: Sendable {
    var open = 1.0
    var pupilX = 11.7
    // Independent weights let recovery blend red → green without passing through the neutral template color.
    var red = 0.0
    var green = 0.0
    var lidLine = 1.0

    func blended(to other: EyePose, progress: Double) -> EyePose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        return EyePose(open: mix(open, other.open), pupilX: mix(pupilX, other.pupilX),
                       red: mix(red, other.red), green: mix(green, other.green), lidLine: mix(lidLine, other.lidLine))
    }
}

/// Pure, monotonic-time animation state. New states interrupt from the currently visible pose.
struct EyeMotion {
    private(set) var state: EyeState = .neutral
    private var initialized = false
    private var transition: Transition?
    private var blink: Blink?

    private struct Transition {
        let from: EyePose
        let start: Double
        let duration: Double
        let recovery: Bool
    }

    private struct Blink {
        let start: Double
        let double: Bool
        var duration: Double { double ? 0.363 : 0.282 }
    }

    mutating func change(to next: EyeState, at time: Double, animated: Bool) {
        let from = pose(at: time)
        let previous = state
        state = next
        blink = nil
        guard initialized, animated else {
            initialized = true
            transition = nil
            return
        }
        let recovery = previous == .offTask && next == .onTask
        let duration: Double
        if next == .resting { duration = 0.750 }
        else if previous == .resting { duration = 0.770 }
        else if recovery { duration = 1.030 }
        else if next == .offTask { duration = 0.340 }
        else { duration = 0.200 }
        transition = Transition(from: from, start: time, duration: duration, recovery: recovery)
    }

    mutating func startBlink(at time: Double, double: Bool) {
        guard state != .resting, !isAnimating(at: time) else { return }
        transition = nil
        blink = Blink(start: time, double: double)
    }

    func isAnimating(at time: Double) -> Bool {
        if let transition, time < transition.start + transition.duration { return true }
        if let blink, time < blink.start + blink.duration { return true }
        return false
    }

    func pose(at time: Double) -> EyePose {
        if let transition, time < transition.start + transition.duration {
            let elapsed = max(0, time - transition.start)
            if transition.recovery {
                let lift = Self.ease(elapsed / 0.310)
                let settle = Self.ease((elapsed - 0.500) / 0.530)
                let lifted = transition.from.blended(to: EyePose(open: 1.32, green: 1), progress: lift)
                return lifted.blended(to: state.pose, progress: settle)
            }
            return transition.from.blended(to: state.pose, progress: Self.ease(elapsed / transition.duration))
        }
        var result = state.pose
        if let blink, time < blink.start + blink.duration {
            let elapsed = max(0, time - blink.start)
            let opening = blink.double
                ? min(Self.blinkOpening(at: elapsed * 1.8), Self.blinkOpening(at: (elapsed - 0.222) * 2))
                : Self.blinkOpening(at: elapsed)
            result.open *= opening
        }
        return result
    }

    private static func blinkOpening(at time: Double) -> Double {
        guard time >= 0, time < 0.282 else { return 1 }
        var end = 0.0
        for step in SideEyeBlink.steps {
            end += Double(step.milliseconds) / 1_000
            if time < end { return SideEyeBlink.openness[step.frame] }
        }
        return 1
    }

    static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
