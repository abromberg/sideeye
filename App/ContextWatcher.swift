import AppKit
import FocusCore

enum Trigger: String {
    case activation, window, heartbeat, start, taskSwitch
}

/// Emits a snapshot whenever the frontmost app, focused window, title, or URL changes, plus a heartbeat.
@MainActor
final class ContextWatcher {
    var onSnapshot: ((ContextSnapshot, Trigger) -> Void)?
    var heartbeatInterval: TimeInterval = 45

    private var axObserver: AXAppObserver?
    private var heartbeat: Timer?
    private var debounce: Task<Void, Never>?
    private var activationToken: NSObjectProtocol?
    private var lastEmittedKey: String?
    private var enhancedPIDs = Set<pid_t>()
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostChanged() }
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(.heartbeat, delay: 0) }
        }
        frontmostChanged(trigger: .start)
    }

    func stop() {
        running = false
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        heartbeat?.invalidate()
        heartbeat = nil
        axObserver?.invalidate()
        axObserver = nil
        debounce?.cancel()
        lastEmittedKey = nil
    }

    private func frontmostChanged(trigger: Trigger = .activation) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        if let bundleID = app.bundleIdentifier, !enhancedPIDs.contains(pid) {
            enhancedPIDs.insert(pid)
            AX.enableEnhancedTree(pid: pid, bundleID: bundleID)
        }
        axObserver?.invalidate()
        axObserver = AXAppObserver(pid: pid) { [weak self] in self?.schedule(.window, delay: 0.3) }
        schedule(trigger, delay: 0.15)
    }

    private func schedule(_ trigger: Trigger, delay: TimeInterval) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.running else { return }
            guard let snap = await Self.capture() else { return }
            guard !Task.isCancelled else { return }
            // Heartbeats and title events that don't change the key are no-ops.
            if snap.cacheKey == self.lastEmittedKey, trigger != .start { return }
            self.lastEmittedKey = snap.cacheKey
            self.onSnapshot?(snap, trigger)
        }
    }

    /// Reads metadata off the main thread — AX calls block on slow apps.
    static func capture() async -> ContextSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? "unknown"
        let name = app.localizedName ?? bundleID
        return await Task.detached(priority: .userInitiated) {
            let title = AX.windowTitle(pid)
            let url = AX.browserURL(pid, bundleID: bundleID)
            return ContextSnapshot(appName: name, bundleID: bundleID, pid: pid, windowTitle: title, url: url)
        }.value
    }

}
