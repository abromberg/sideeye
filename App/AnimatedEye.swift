import AppKit
import SwiftUI

/// Shared playback for the menu bar and floating window; each appearance owns its own cancellable task.
struct AnimatedEye<Content: View>: View {
    let state: EyeState
    let enabled: Bool
    @ViewBuilder let content: (NSImage) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = EyeMotion()
    @State private var pose = EyePose()

    private struct Request: Equatable {
        let state: EyeState
        let enabled: Bool
    }

    private var request: Request {
        Request(state: state, enabled: enabled && !reduceMotion)
    }

    var body: some View {
        content(EyeIcon.image(pose: pose))
            .task(id: request) {
                await animate(request)
            }
    }

    private func animate(_ request: Request) async {
        do {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            motion.change(to: request.state, at: now, animated: request.enabled)
            pose = motion.pose(at: now)
            guard request.enabled else { return }
            while true {
                try Task.checkCancellation()
                let time = ProcessInfo.processInfo.systemUptime
                pose = motion.pose(at: time)
                if motion.isAnimating(at: time) {
                    try await Task.sleep(for: .milliseconds(16))
                } else {
                    guard request.state != .resting else { return }
                    try await Task.sleep(for: .seconds(Double.random(in: SideEyeBlink.interval)))
                    try Task.checkCancellation()
                    motion.startBlink(at: ProcessInfo.processInfo.systemUptime, double: Int.random(in: 0..<5) == 0)
                }
            }
        } catch {
            // The next task owns the visible pose; cancellation of an older task must not reset it.
        }
    }
}
