import Foundation
import FocusCore
import Observation
import ServiceManagement

/// How readily a window counts as on or off task. Maps to Jev probability bands; anything between escalates.
enum Strictness: String, CaseIterable, Identifiable {
    case relaxed, balanced, strict

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var bands: Bands {
        switch self {
        case .relaxed: .relaxed
        case .balanced: .balanced
        case .strict: .strict
        }
    }
}

/// Full shows the task, status and timer at all times. Compact shrinks to the status icon while nothing needs you,
/// expands on a click, and opens on its own when you drift.
enum PanelStyle: String, CaseIterable, Identifiable {
    case full, compact

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// User-tunable settings, persisted in UserDefaults.
@MainActor @Observable
final class Settings {
    private let d = UserDefaults.standard

    var onBand: Double { didSet { d.set(onBand, forKey: "onBand") } }
    var offBand: Double { didSet { d.set(offBand, forKey: "offBand") } }
    /// Seconds after Start before an off-task verdict turns anything red.
    var gracePeriod: Double { didSet { d.set(gracePeriod, forKey: "gracePeriod") } }

    var usePomodoro: Bool { didSet { d.set(usePomodoro, forKey: "usePomodoro") } }
    var workMinutes: Int { didSet { d.set(workMinutes, forKey: "workMinutes") } }
    var breakMinutes: Int { didSet { d.set(breakMinutes, forKey: "breakMinutes") } }

    var useAXText: Bool { didSet { d.set(useAXText, forKey: "useAXText") } }
    var useScreenshots: Bool { didSet { d.set(useScreenshots, forKey: "useScreenshots") } }
    var useDescriber: Bool { didSet { d.set(useDescriber, forKey: "useDescriber") } }
    /// Write a task brief at Start from your other tasks and the windows you've confirmed (see BriefWriter).
    var useTaskBrief: Bool { didSet { d.set(useTaskBrief, forKey: "useTaskBrief") } }
    /// Tell the brief what you've been writing or reading in on-task windows, so it knows what the task is about now.
    var useOnTaskText: Bool { didSet { d.set(useOnTaskText, forKey: "useOnTaskText") } }
    /// Keep the window text read at each switch and every model call (request, response, host, timing) in the log.
    var debugLogging: Bool { didSet { d.set(debugLogging, forKey: "debugLogging") } }

    var jevModel: String { didSet { d.set(jevModel, forKey: "jevModel") } }
    var describerModel: String { didSet { d.set(describerModel, forKey: "describerModel") } }
    var briefModel: String { didSet { d.set(briefModel, forKey: "briefModel") } }
    var excludedBundleIDs: [String] { didSet { d.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    var lastTask: String { didSet { d.set(lastTask, forKey: "lastTask") } }
    /// At least one of the floating window and the menu bar icon is always shown, so the app stays reachable.
    var showFloatingPanel: Bool {
        didSet {
            d.set(showFloatingPanel, forKey: "showFloatingPanel")
            if !showFloatingPanel, !showMenuBarIcon { showMenuBarIcon = true }
        }
    }
    var showMenuBarIcon: Bool {
        didSet {
            d.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            if !showMenuBarIcon, !showFloatingPanel { showMenuBarIcon = true }
            menuBarIconBlocked = false
            if showMenuBarIcon { menuBarIconShownAt = Date() }
        }
    }
    /// macOS hid the menu bar icon (System Settings → Menu Bar → Allow in the Menu Bar). Not saved: it's checked
    /// again each time the icon is shown. See `AppModel.menuBarIconVisibilityChanged`.
    var menuBarIconBlocked = false
    @ObservationIgnored var menuBarIconShownAt: Date?
    var panelStyle: PanelStyle { didSet { d.set(panelStyle.rawValue, forKey: "panelStyle") } }
    var showPanelTimer: Bool { didSet { d.set(showPanelTimer, forKey: "showPanelTimer") } }
    var blinkFloatingPanelIcon: Bool { didSet { d.set(blinkFloatingPanelIcon, forKey: "blinkFloatingPanelIcon") } }
    var blinkMenuBarIcon: Bool { didSet { d.set(blinkMenuBarIcon, forKey: "blinkMenuBarIcon") } }

    static let defaultExcluded = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.bitwarden.desktop", "com.apple.systempreferences",
    ]

    init() {
        d.register(defaults: [
            "onBand": 0.6, "offBand": 0.35, "gracePeriod": 5.0,
            "usePomodoro": true, "workMinutes": 25, "breakMinutes": 5,
            "useAXText": true, "useScreenshots": true, "useDescriber": true, "useTaskBrief": true, "useOnTaskText": true, "debugLogging": false,
            "jevModel": "jev-latest", "describerModel": "~deepseek/deepseek-flash-latest",
            "briefModel": BriefWriter.defaultModel,
            "excludedBundleIDs": Self.defaultExcluded, "lastTask": "", "showFloatingPanel": true, "showMenuBarIcon": true, "showPanelTimer": true, "blinkMenuBarIcon": true,
            "blinkFloatingPanelIcon": true, "panelStyle": PanelStyle.full.rawValue,
        ])
        onBand = d.double(forKey: "onBand")
        offBand = d.double(forKey: "offBand")
        gracePeriod = d.double(forKey: "gracePeriod")
        usePomodoro = d.bool(forKey: "usePomodoro")
        workMinutes = d.integer(forKey: "workMinutes")
        breakMinutes = d.integer(forKey: "breakMinutes")
        useAXText = d.bool(forKey: "useAXText")
        useScreenshots = d.bool(forKey: "useScreenshots")
        useDescriber = d.bool(forKey: "useDescriber")
        useTaskBrief = d.bool(forKey: "useTaskBrief")
        useOnTaskText = d.bool(forKey: "useOnTaskText")
        debugLogging = d.bool(forKey: "debugLogging")
        jevModel = d.string(forKey: "jevModel") ?? "jev-latest"
        describerModel = d.string(forKey: "describerModel") ?? "~deepseek/deepseek-flash-latest"
        briefModel = d.string(forKey: "briefModel") ?? BriefWriter.defaultModel
        excludedBundleIDs = d.stringArray(forKey: "excludedBundleIDs") ?? Self.defaultExcluded
        lastTask = d.string(forKey: "lastTask") ?? ""
        let panel = d.bool(forKey: "showFloatingPanel")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon") || !panel
        showFloatingPanel = panel
        panelStyle = d.string(forKey: "panelStyle").flatMap(PanelStyle.init) ?? .full
        showPanelTimer = d.bool(forKey: "showPanelTimer")
        blinkFloatingPanelIcon = d.bool(forKey: "blinkFloatingPanelIcon")
        blinkMenuBarIcon = d.bool(forKey: "blinkMenuBarIcon")
    }

    static let workLengths = [15, 20, 25, 30, 45, 50, 60, 90]
    static let breakLengths = [3, 5, 10, 15, 20]
    static let gracePeriods: [(seconds: Double, label: String)] = [
        (0, "None"), (5, "5 seconds"), (10, "10 seconds"), (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"),
    ]

    var bands: Bands { Bands(on: onBand, off: offBand) }

    /// nil when the bands were hand-tuned to something that isn't a preset.
    var strictness: Strictness? {
        get { Strictness.allCases.first { $0.bands == bands } }
        set {
            guard let newValue else { return }
            onBand = newValue.bands.on
            offBand = newValue.bands.off
        }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}
