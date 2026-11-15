import AppKit
import SwiftUI

/// One screen's cover: borderless, above everything (full-screen apps and other Spaces included), and able to take
/// keys without activating the app, so the task field works even when macOS won't bring Side Eye to the front.
final class CoverPanel: NSPanel {
    init(screen: NSScreen, content: NSView) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // After `isFloatingPanel`, which sets the level back to floating.
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = content
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Puts the cover up on every screen and takes it down. While it's up, it also hides the Dock and menu bar and turns
/// off Cmd-Tab and the Force Quit window, which macOS only allows while Side Eye is the active app.
@MainActor
final class HardcoreCoverController {
    private var panels: [CoverPanel] = []
    private weak var model: AppModel?
    private var screenObserver: NSObjectProtocol?
    /// The displays the panels were made for. Hiding the Dock and menu bar also posts a screen change, so only a
    /// display being added, removed or rearranged rebuilds the panels.
    private var coveredFrames: [CGRect] = []
    var isShown: Bool { !panels.isEmpty }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown, let model = self.model,
                      NSScreen.screens.map(\.frame) != self.coveredFrames else { return }
                self.removePanels()
                self.makePanels(model: model)
                self.focusMainPanel()
            }
        }
    }

    func setShown(_ shown: Bool, model: AppModel) {
        guard shown != isShown else { return }
        if shown { show(model: model) } else { hide() }
    }

    /// Called every second while the cover is up: anything that took the keyboard away (a click through to another
    /// app, a system shortcut) gives it back.
    func reassert() {
        guard isShown else { return }
        for panel in panels where !panel.isVisible { panel.orderFrontRegardless() }
        if !panels.contains(where: \.isKeyWindow) { focusMainPanel() }
        if !NSApp.isActive { NSApp.activate() }
    }

    private func show(model: AppModel) {
        makePanels(model: model)
        NSApp.activate()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableHideApplication]
        focusMainPanel()
    }

    private func hide() {
        NSApp.presentationOptions = []
        removePanels()
    }

    private func makePanels(model: AppModel) {
        self.model = model
        coveredFrames = NSScreen.screens.map(\.frame)
        panels = NSScreen.screens.map { screen in
            let blur = NSVisualEffectView()
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: HardcoreCoverView(model: model, settings: model.settings))
            hosting.sizingOptions = []
            hosting.frame = blur.bounds
            hosting.autoresizingMask = [.width, .height]
            blur.addSubview(hosting)
            let panel = CoverPanel(screen: screen, content: blur)
            panel.orderFrontRegardless()
            return panel
        }
    }

    private func removePanels() {
        for panel in panels { panel.orderOut(nil) }
        panels = []
    }

    /// The screen with the mouse on it gets the keyboard; that's where you're looking.
    private func focusMainPanel() {
        let mouse = NSEvent.mouseLocation
        let panel = panels.first { $0.frame.contains(mouse) } ?? panels.first
        panel?.makeKeyAndOrderFront(nil)
    }
}

/// What's on the cover: the eye giving you a look, and the task field. Starting a pomodoro takes the cover down.
struct HardcoreCoverView: View {
    @Bindable var model: AppModel
    @Bindable var settings: Settings
    @FocusState private var taskFocused: Bool

    private var canStart: Bool { !model.taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.canStart }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 0) {
                AnimatedEye(state: .offTask, enabled: settings.blinkFloatingPanelIcon) { icon in
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 112, height: 112)
                        .accessibilityHidden(true)
                }
                .padding(.bottom, 20)

                Text("What are you working on?")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.bottom, 8)
                Text("Start a pomodoro to get back to your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 28)

                TextField("What are you working on?", text: $model.taskDraft, prompt: Text("Draft the lease memo"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .medium))
                    .focused($taskFocused)
                    .onSubmit(start)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18)))
                    .frame(width: 480)
                    .padding(.bottom, 14)

                HStack(spacing: 12) {
                    if settings.usePomodoro {
                        Picker("Length", selection: $settings.workMinutes) {
                            ForEach(Settings.workLengths, id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .controlSize(.large)
                    }
                    Button(action: start) {
                        Label("Start", systemImage: "play.fill").frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                }

                if model.pomosToday > 0 {
                    PomoCount(count: model.pomosToday)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 22)
                }
            }
            .padding(.bottom, 60)

            VStack {
                Spacer()
                footer.padding(.bottom, 36)
            }
        }
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
        .environment(\.controlActiveState, .key)
        .onAppear { DispatchQueue.main.async { taskFocused = true } }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label(model.hardcoreStatus, systemImage: model.reallyHardcore ? "lock.fill" : "flame.fill")
                .foregroundStyle(.secondary)
            if model.hardcore?.canTurnOff == true {
                Button("Turn Off Hardcore") { model.turnOffHardcore() }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func start() {
        guard canStart else { return }
        model.start(task: model.taskDraft)
    }
}

