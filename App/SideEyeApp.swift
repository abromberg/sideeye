import AppKit
import FocusCore
import SwiftUI

@main
struct SideEyeApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    /// Shown while setup is unfinished. Demo states and the other layout-check windows skip it.
    private var showsWelcomeAtLaunch: Bool {
        let args = CommandLine.arguments
        if args.contains("--show-welcome") { return true }
        return model.needsSetup && !args.contains { $0.hasPrefix("--demo") || $0.hasPrefix("--show-") }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBarIcon },
                                         set: { model.menuBarIconVisibilityChanged($0) })) {
            MenuView(model: model, settings: model.settings)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsView(model: model, settings: model.settings)
        }

        // Opens on launch while setup isn't finished (`--show-welcome` forces it, for layout checks).
        Window("Welcome to Side Eye", id: WelcomeView.id) {
            WelcomeView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(showsWelcomeAtLaunch ? .presented : .suppressed)

        // Development: the menu's content in a normal window (`--show-menu-preview`), for layout checks.
        Window("Menu Preview", id: "menu-preview") {
            MenuView(model: model, settings: model.settings)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            AnimatedEye(state: eyeState, enabled: model.settings.blinkMenuBarIcon) { icon in
                Image(nsImage: Self.label(icon: icon, countdown: model.countdown))
                    .accessibilityLabel(iconDescription)
            }
        }
        .onAppear {
            SettingsOpener.action = openSettings
            WelcomeOpener.action = openWindow
            // Development: open Settings on launch to check its layout.
            if CommandLine.arguments.contains("--show-settings") {
                NSApp.activate()
                openSettings()
            }
            if CommandLine.arguments.contains("--show-menu-preview") {
                openWindow(id: "menu-preview")
            }
        }
    }

    /// Icon and countdown drawn as one image. The menu bar ignores SwiftUI font modifiers (so `Text` digits jitter)
    /// and shows only one image, so the countdown is drawn here with fixed-width digits.
    /// A template icon keeps the whole image template (the menu bar colors it); with a colored icon, the text is drawn
    /// in `labelColor`, resolved at draw time against the menu bar's own light/dark appearance.
    private static func label(icon: NSImage, countdown: String?) -> NSImage {
        guard let countdown else { return icon }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let textSize = (countdown as NSString).size(withAttributes: [.font: font])
        let gap: CGFloat = 4
        let size = NSSize(width: icon.size.width + gap + ceil(textSize.width), height: max(icon.size.height, ceil(textSize.height)))
        let template = icon.isTemplate
        let image = NSImage(size: size, flipped: false) { rect in
            icon.draw(in: NSRect(x: 0, y: (rect.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            (countdown as NSString).draw(
                at: NSPoint(x: icon.size.width + gap, y: (rect.height - textSize.height) / 2),
                withAttributes: [.font: font, .foregroundColor: template ? NSColor.black : NSColor.labelColor])
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Side Eye \(countdown)"
        return image
    }

    private var eyeState: EyeState {
        if case .onBreak = model.phase { return .resting }
        guard model.isWorking else { return .neutral }
        if model.showsOffTask { return .offTask }
        return model.judgment == .on || model.probablyOnTask ? .onTask : .neutral
    }

    private var iconDescription: String {
        switch model.phase {
        case .idle: return "Side Eye, ready to focus"
        case .onBreak: return "Side Eye, on break"
        case .working:
            if model.showsOffTask { return "Side Eye, off task" }
            if model.excluded { return "Side Eye, not judged" }
            if model.judgment == .on { return "Side Eye, on task" }
            if model.probablyOnTask { return "Side Eye, probably on task" }
            return "Side Eye, checking focus"
        }
    }

}

/// Opening the app again (Finder, Spotlight, `open`) while it's running shows Settings, or the welcome window until
/// setup's done: the way back in when the menu bar icon is hidden.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { _ = Updater.shared }
    }

    /// Closing Settings must not quit the app (with the menu bar icon hidden it's the only regular window).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !AX.isTrusted() || Keychain.openRouterKey() == nil { WelcomeOpener.open() } else { SettingsOpener.open() }
        }
        return false
    }
}

/// Where to let Side Eye into the menu bar when macOS is hiding its icon.
@MainActor
enum MenuBarAccess {
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
    }

    static func explain() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "macOS is hiding Side Eye's menu bar icon"
        alert.informativeText = "Turn on Side Eye in System Settings → Menu Bar → Allow in the Menu Bar, then show the icon again."
        alert.addButton(withTitle: "Open Menu Bar Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }
}

/// Opens the Settings scene from anywhere. SwiftUI only hands out `openSettings` inside views, so the first view
/// that appears registers it here (the floating window and the menu bar label both do).
@MainActor
enum SettingsOpener {
    static var action: OpenSettingsAction?

    static func open() {
        NSApp.activate()
        action?()
    }
}
