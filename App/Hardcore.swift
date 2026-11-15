import AppKit
import ServiceManagement

/// Hardcore mode: for a while, Side Eye covers every screen whenever no pomodoro or break is running, and only
/// starting one gets you back to your Mac. See `HardcoreCover` for the cover itself.
enum HardcoreLevel: String, Codable, CaseIterable, Identifiable {
    /// You can turn it off whenever you like.
    case hardcore
    /// Can't be turned off until it runs out, can't be quit, and comes back if it's killed or the Mac restarts.
    case really

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hardcore: "Hardcore"
        case .really: "Really Hardcore"
        }
    }
}

/// What you signed up for: how hard, and until when.
struct HardcoreCommitment: Codable, Equatable {
    var level: HardcoreLevel
    /// nil: until you turn it off. Only regular hardcore can run without an end.
    var until: Date?

    func isActive(at now: Date) -> Bool { until.map { now < $0 } ?? true }
    var canTurnOff: Bool { level == .hardcore }

    /// "5:40 PM", "midnight", or "tomorrow at 3:00 PM".
    static func endText(_ end: Date, now: Date) -> String {
        let calendar = Calendar.current
        if end == calendar.startOfDay(for: end), end > now, end.timeIntervalSince(now) <= 86_400 { return "midnight" }
        let time = end.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(end, inSameDayAs: now) { return time }
        if calendar.isDateInTomorrow(end) { return "tomorrow at \(time)" }
        return end.formatted(date: .abbreviated, time: .shortened)
    }

    private static let key = "hardcore"

    static func load() -> HardcoreCommitment? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(HardcoreCommitment.self, from: data) else { return nil }
        // Really hardcore always has an end. One without is a damaged or hand-edited setting; don't lock anyone in for good.
        guard saved.level == .hardcore || saved.until != nil else { return nil }
        return saved
    }

    static func save(_ commitment: HardcoreCommitment?) {
        if let commitment, let data = try? JSONEncoder().encode(commitment) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// How long to go hardcore for, as picked in the menu.
enum HardcoreLength: Hashable, Identifiable {
    case hours(Double)
    case restOfToday
    case custom
    case always

    static let presets: [HardcoreLength] = [.hours(1), .hours(2), .hours(4), .hours(8), .restOfToday, .custom, .always]
    /// Custom lengths are capped, so a typo doesn't lock you in for days.
    static let maxCustomHours: Double = 24

    var id: String { title }
    var title: String {
        switch self {
        case let .hours(h): h == 1 ? "1 hour" : "\(Int(h)) hours"
        case .restOfToday: "Rest of today"
        case .custom: "Custom"
        case .always: "Always"
        }
    }

    /// When it ends, starting at `now`. nil for `.always`, or a custom length that isn't a usable number.
    func end(from now: Date, customHours: Double?) -> Date? {
        switch self {
        case let .hours(h): now.addingTimeInterval(h * 3600)
        case .restOfToday: Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        case .custom:
            customHours.flatMap { $0 > 0 ? now.addingTimeInterval(min($0, Self.maxCustomHours) * 3600) : nil }
        case .always: nil
        }
    }
}

/// Whether Side Eye refuses to quit. Read by `AppDelegate.applicationShouldTerminate`.
@MainActor
enum QuitGuard {
    /// Set by `AppModel` while the cover is up, and for the whole of really hardcore.
    static var blocking = false
    /// Logging out, restarting and shutting down always go through, and so does Sparkle relaunching into an update.
    static var allowQuit = false

    static func shouldTerminate() -> Bool {
        guard blocking, !allowQuit, !systemIsQuitting else { return true }
        NSSound.beep()
        return false
    }

    /// The quit came from macOS logging out, restarting or shutting down.
    private static var systemIsQuitting: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.typeCodeValue else { return false }
        let systemReasons = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
        return systemReasons.contains { UInt32($0) == reason }
    }
}

/// During really hardcore, a launch agent reopens Side Eye within seconds if it isn't running: after a force quit,
/// a `kill`, or a restart. Side Eye removes it again when really hardcore runs out. The agent is
/// `Contents/Library/LaunchAgents/energy.experimental.sideeye.keepalive.plist` in the app.
@MainActor
enum KeepAlive {
    private static let service = SMAppService.agent(plistName: "energy.experimental.sideeye.keepalive.plist")

    /// macOS asks before letting an app run things in the background, and you can switch it off in
    /// System Settings → General → Login Items & Extensions.
    static var needsApproval: Bool { service.status == .requiresApproval }

    static func set(_ on: Bool) {
        let d = UserDefaults.standard
        var enabled = service.status == .enabled || service.status == .requiresApproval
        do {
            if on {
                // The agent reopens this copy of the app: another one with the same bundle ID may not know hardcore mode.
                d.set(Bundle.main.bundlePath, forKey: "keepAliveApp")
                // launchd keeps the agent as it was first registered, so a different build re-registers it to load
                // its own copy of the plist.
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                if enabled, d.string(forKey: "keepAliveBuild") != build || d.string(forKey: "keepAliveRegisteredFrom") != Bundle.main.bundlePath {
                    try service.unregister()
                    enabled = false
                }
                if !enabled {
                    try service.register()
                    d.set(build, forKey: "keepAliveBuild")
                    d.set(Bundle.main.bundlePath, forKey: "keepAliveRegisteredFrom")
                }
            } else if enabled {
                try service.unregister()
            }
        } catch {
            NSLog("Side Eye: couldn't \(on ? "register" : "unregister") the keep-alive agent: \(error.localizedDescription)")
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
