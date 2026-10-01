// Run: swiftc App/SideEyeBlink.swift App/EyeMotion.swift App/EyeIcon.swift scripts/check-eye-motion.swift -o build/check-eye-motion && build/check-eye-motion
import AppKit

@main
struct CheckEyeMotion {
    static func near(_ a: Double, _ b: Double, _ message: String) {
        precondition(abs(a - b) < 0.00001, message)
    }

    @MainActor
    static func main() throws {
        var motion = EyeMotion()
        motion.change(to: .neutral, at: 0, animated: true)
        precondition(!motion.isAnimating(at: 0), "Launch should show the current state immediately")
        motion.change(to: .offTask, at: 1, animated: true)
        near(motion.pose(at: 1).open, 1, "Drift begins from the current pose")
        near(motion.pose(at: 1.34).open, 0.62, "Drift reaches the approved squint")
        near(motion.pose(at: 1.34).pupilX, 12.35, "Drift shifts the pupil sideways")

        motion.change(to: .onTask, at: 2, animated: true)
        for offset in stride(from: 0.0, through: 1.03, by: 0.01) {
            let pose = motion.pose(at: 2 + offset)
            near(pose.red + pose.green, 1, "Recovery must never include the neutral gray color")
        }
        let recovery = motion.pose(at: 2.31)
        near(recovery.open, 1.32, "Recovery briefly lifts the lid")
        near(motion.pose(at: 3.03).open, 1, "Recovery settles to the normal gaze")

        motion.startBlink(at: 4, double: true)
        near(motion.pose(at: 4.05).open, 0, "First fast blink closes")
        near(motion.pose(at: 4.18).open, 1, "The short gap is open")
        near(motion.pose(at: 4.27).open, 0, "Second fast blink closes")
        near(motion.pose(at: 4.363).open, 1, "Fast double blink ends after 363 ms")
        precondition(!motion.isAnimating(at: 4.364))

        motion.change(to: .resting, at: 5, animated: true)
        let asleep = motion.pose(at: 5.75)
        near(asleep.open, 0, "Break eye closes fully")
        near(asleep.lidLine, 0, "Break eye has no line")
        motion.startBlink(at: 6, double: true)
        precondition(!motion.isAnimating(at: 6), "Never blink during a break")
        motion.change(to: .neutral, at: 7, animated: true)
        near(motion.pose(at: 7).open, 0, "Wake from the closed eye")
        near(motion.pose(at: 7.77).open, 1, "Wake finishes after 770 ms")

        motion.change(to: .offTask, at: 8, animated: true)
        let interrupted = motion.pose(at: 8.1)
        motion.change(to: .onTask, at: 8.1, animated: true)
        let resumed = motion.pose(at: 8.1)
        near(resumed.open, interrupted.open, "Interruptions do not jump to a stale pose")
        near(resumed.red, interrupted.red, "Interruptions preserve the visible color")
        motion.change(to: .onTask, at: 8.2, animated: false)
        precondition(!motion.isAnimating(at: 8.2), "Disabling motion cancels the transition")
        near(motion.pose(at: 8.2).open, 1, "Disabling motion snaps to the correct pose")
        motion.change(to: .resting, at: 9, animated: false)
        near(motion.pose(at: 9).lidLine, 0, "Reduced Motion still uses a solid break icon")

        let poses = [EyeState.neutral.pose, EyeState.offTask.pose, recovery, EyeState.onTask.pose, asleep]
        let names = ["Ready", "Off task", "Welcome back", "On task", "Resting"]
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 140,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 140).fill()
        for (index, pose) in poses.enumerated() {
            let icon = EyeIcon.image(pose: pose)
            precondition(icon.size == NSSize(width: 18, height: 18), "The layout never changes size")
            precondition(icon.isTemplate == (pose.red + pose.green == 0), "Neutral icons adapt to the menu bar appearance")
            icon.isTemplate = false // Contact sheet shows the underlying artwork, without AppKit template recoloring.
            icon.draw(in: NSRect(x: index * 120 + 20, y: 42, width: 80, height: 80))
            (names[index] as NSString).draw(at: NSPoint(x: index * 120 + 15, y: 15),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/eye-motion-check.png"))
        print("Eye motion checks passed: transitions, color continuity, fast double blink, solid rest, wake, interruption, disabling motion, and native rendering.")
    }
}
