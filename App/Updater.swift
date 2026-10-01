import AppKit
import Sparkle

/// Sparkle, reading the appcast at Info.plist's `SUFeedURL`. scripts/release.sh publishes it.
@MainActor
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // A menu bar app has no Dock icon to badge: Sparkle shows found updates without taking focus from your work.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
