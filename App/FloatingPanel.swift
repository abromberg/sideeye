import AppKit
import FocusCore
import SwiftUI

/// Borderless, non-activating, always-on-top panel. Clicking it never pulls focus from the app you're judged on,
/// but it can still take keys for the task field.
///
/// The window is a viewport onto the top corner of a fixed-size SwiftUI canvas. The glass changes shape inside the
/// canvas with SwiftUI animations; the window grows at once to make room and shrinks to fit once the glass settles.
/// Resizing the window never re-lays out SwiftUI, which draws a frame behind the window and made every resize jump.
final class FloatingPanel: NSPanel {
    static let cornerRadius: CGFloat = 24
    /// Clear space around the glass. The glass draws its shadow and edge light slightly outside its shape;
    /// without room, the window bounds clip that into a visible rectangle.
    static let margin: CGFloat = 24
    /// Wide enough for the full panel, taller than it ever gets.
    static let canvas = CGSize(width: FloatingStatusView.fullWidth + 2 * margin, height: 400)
    /// Long enough for the glass's spring to settle before the window shrinks around it.
    private static let settle: TimeInterval = 0.6

    let state: PanelState
    private let hosting: NSView
    private var shrinkWork: DispatchWorkItem?

    init(hosting: NSView, state: PanelState, hover: PanelHover) {
        self.state = state
        self.hosting = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: 368, height: 98),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        // Tracks the mouse over the glass. At rest the window hugs the glass, so this is the glass's shape.
        let hoverRegion = NSView(frame: container.bounds.insetBy(dx: Self.margin, dy: Self.margin))
        hoverRegion.autoresizingMask = [.width, .height]
        container.addSubview(hoverRegion)
        hover.track(hoverRegion)
        container.addSubview(hosting)
        contentView = container
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        // The glass draws its own edge and depth; a window shadow adds a dark hairline around the shape.
        hasShadow = false
        animationBehavior = .utilityWindow
        let autosaveName = "FloatingStatus"
        // Restore the whole saved frame: `setFrameUsingName` keeps only the top-left corner of a window that can't be
        // resized, and the pinned side needs the real right edge.
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)")?
            .split(separator: " ").prefix(4).compactMap { Double($0) }
        setFrameAutosaveName(autosaveName)
        let restored = saved?.count == 4
        if let saved, restored {
            setFrame(NSRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3]), display: false)
        }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -4, dy: -4).contains(frame) }
        if !restored || !onScreen, let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: f.maxX - frame.width - 16, y: f.maxY - 12))
        }
        state.pinRight = prefersPinRight
        placeHosting()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.updatePin() }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Text should only look selected while you're actually typing in the panel.
    override func resignKey() {
        super.resignKey()
        makeFirstResponder(nil)
    }

    /// Collapsed, a click (not a drag) expands the panel. Handled here rather than with a SwiftUI tap gesture, which
    /// would stop the icon from dragging the window.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control), state.collapsed else {
            return super.sendEvent(event)
        }
        let start = event.locationInWindow
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if state.expandsToTextField { makeKey() }
                state.expanded = true
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                performDrag(with: event)
                return
            }
        }
    }

    /// The glass is changing to `size`. Grow at once so its animation has room; shrink once it has settled.
    func glassSizeChanged(_ size: CGSize) {
        let target = CGSize(width: ceil(size.width) + 2 * Self.margin, height: ceil(size.height) + 2 * Self.margin)
        shrinkWork?.cancel()
        let room = CGSize(width: max(frame.width, target.width), height: max(frame.height, target.height))
        resize(to: room)
        guard room != target else { return }
        let work = DispatchWorkItem { [weak self] in self?.resize(to: target) }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// Keeps the top edge where the user put it, and the pinned side.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let x = state.pinRight ? frame.maxX - size.width : frame.minX
        setFrame(NSRect(x: x, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// The side nearer the screen's edge stays put, so the glass grows into the screen rather than off it.
    private var prefersPinRight: Bool {
        (screen ?? NSScreen.main).map { frame.midX > $0.visibleFrame.midX } ?? true
    }

    /// The canvas hangs from the window's top edge and pinned side, so resizing the window only reveals more of it.
    private func placeHosting() {
        let bounds = contentView?.bounds ?? .zero
        hosting.frame = NSRect(x: state.pinRight ? bounds.width - Self.canvas.width : 0,
                               y: bounds.height - Self.canvas.height,
                               width: Self.canvas.width, height: Self.canvas.height)
        hosting.autoresizingMask = state.pinRight ? [.minXMargin, .minYMargin] : [.maxXMargin, .minYMargin]
    }

    /// Dragged across the middle of the screen: pin the other side. At rest the glass sits in the same spot either way.
    private func updatePin() {
        let right = prefersPinRight
        guard right != state.pinRight else { return }
        state.pinRight = right
        // Re-align the SwiftUI glass before moving the canvas, so the two don't draw a frame apart.
        hosting.layoutSubtreeIfNeeded()
        placeHosting()
    }
}

/// Whether the mouse is over the panel's glass. Tracked in AppKit rather than with SwiftUI's `onHover`, which only
/// works while the app is active. Leaving waits a moment before hiding the buttons, so skimming the edge can't
/// flicker them.
@MainActor @Observable
final class PanelHover {
    private(set) var isHovering = false
    @ObservationIgnored private var exitWork: DispatchWorkItem?
    @ObservationIgnored private lazy var responder = Responder(owner: self)

    func track(_ view: NSView) {
        view.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: responder))
    }

    func entered() {
        exitWork?.cancel()
        if !isHovering { isHovering = true }
    }

    func exited() {
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isHovering = false }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Tracking areas message their owner; this forwards to the model.
    private final class Responder: NSResponder {
        weak var owner: PanelHover?
        init(owner: PanelHover) {
            self.owner = owner
            super.init()
        }
        required init?(coder: NSCoder) { fatalError() }
        override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { owner?.entered() } }
        override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { owner?.exited() } }
    }
}

/// Shared by the panel (which sees clicks and moves) and the SwiftUI content (which decides the glass's shape).
@MainActor @Observable
final class PanelState {
    /// Compact mode, clicked open.
    var expanded = false
    /// The side of the canvas the glass hangs from; see `FloatingPanel.updatePin`.
    var pinRight = true
    /// Whether the content is showing just the icon.
    @ObservationIgnored var collapsed = false
    /// Expanding shows the task field (idle), so the panel should take keys.
    @ObservationIgnored var expandsToTextField = false
    /// The glass's latest target size, kept for the first one, which SwiftUI reports before the panel exists.
    @ObservationIgnored var glassSize: CGSize?
}

@MainActor
final class FloatingPanelController {
    private var panel: FloatingPanel?

    func setVisible(_ visible: Bool, model: AppModel) {
        if visible {
            if panel == nil {
                let hover = PanelHover()
                let state = PanelState()
                // Development: toggle hover every 1.5 s to check the expand/collapse without a mouse.
                if CommandLine.arguments.contains("--demo-hover-toggle") {
                    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                        MainActor.assumeIsolated { hover.isHovering ? hover.exited() : hover.entered() }
                    }
                }
                weak var sizedPanel: FloatingPanel?
                let hosting = NSHostingView(rootView: FloatingStatusView(
                    model: model, settings: model.settings, hover: hover, state: state,
                    onGlassSizeChange: { sizedPanel?.glassSizeChanged($0) }))
                // The canvas is sized by the panel; SwiftUI mustn't size the window.
                hosting.sizingOptions = []
                let panel = FloatingPanel(hosting: hosting, state: state, hover: hover)
                sizedPanel = panel
                if let size = state.glassSize { panel.glassSizeChanged(size) }
                // SwiftUI focuses the first text field on its own; don't start with a selected, focused task field.
                DispatchQueue.main.async { panel.makeFirstResponder(nil) }
                self.panel = panel
            }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }
}

struct FloatingStatusView: View {
    static let fullWidth: CGFloat = 320
    /// 18 pt icon plus 15 pt padding: at the 24 pt corner radius, a circle.
    private static let compactSize = CGSize(width: 48, height: 48)
    private static let shape = RoundedRectangle(cornerRadius: FloatingPanel.cornerRadius, style: .continuous)

    @Bindable var model: AppModel
    @Bindable var settings: Settings
    let hover: PanelHover
    let state: PanelState
    let onGlassSizeChange: (CGSize) -> Void
    private var hovering: Bool { hover.isHovering }
    @State private var fullSize = CGSize(width: fullWidth, height: 50)
    @FocusState private var taskFocused: Bool
    /// Editing the task mid-block to move on to another one.
    @State private var switchingTask = false
    /// The status icon exists in both layouts; this makes the two move as one while they cross-fade.
    @Namespace private var icon
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var offTask: Bool { model.showsOffTask }
    /// Compact shows just the icon until you click it, and opens on its own when you drift.
    private var collapsed: Bool { settings.panelStyle == .compact && !state.expanded && !offTask }
    /// A clicked-open compact panel stays open while the mouse is over it or you're typing in it.
    private var staysOpen: Bool { hovering || taskFocused }
    private var glassSize: CGSize { collapsed ? Self.compactSize : fullSize }
    private var morph: Animation? { reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.12) }
    private var tint: Color { offTask ? Color(nsColor: .systemRed).opacity(0.78) : .black.opacity(0.38) }

    var body: some View {
        // Both layouts stay in place and cross-fade while the glass morphs between their sizes. Pinned to the leading
        // edge, they ride along as it moves: opening leftward, the status icon glides from the circle to its spot.
        ZStack(alignment: .topLeading) {
            full
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { fullSize = $0 }
                .opacity(collapsed ? 0 : 1)
                .allowsHitTesting(!collapsed)
            compact
                .opacity(collapsed ? 1 : 0)
                .allowsHitTesting(collapsed)
        }
        .frame(width: glassSize.width, height: glassSize.height, alignment: .topLeading)
        // Clear glass: regular glass drops to a flat, foggy look whenever its window isn't key, and this panel almost
        // never is. The tint is the dimming Apple recommends for legibility on clear glass, red when off task.
        .background(tint, in: Self.shape)
        .clipShape(Self.shape)
        .glassEffect(.clear, in: Self.shape)
        .contextMenu { menu }
        .padding(FloatingPanel.margin)
        .frame(width: FloatingPanel.canvas.width, height: FloatingPanel.canvas.height,
               alignment: state.pinRight ? .topTrailing : .topLeading)
        .onChange(of: glassSize, initial: true) { _, size in
            state.glassSize = size
            onGlassSizeChange(size)
        }
        .onChange(of: collapsed, initial: true) { _, collapsed in state.collapsed = collapsed }
        .onChange(of: model.phase, initial: true) { _, phase in
            state.expandsToTextField = phase == .idle
            state.expanded = false
            switchingTask = false
        }
        .onChange(of: settings.panelStyle) { state.expanded = false }
        .onChange(of: state.expanded) { _, expanded in
            // Clicked open to type a task: put the cursor in the field.
            if expanded, model.phase == .idle { DispatchQueue.main.async { taskFocused = true } }
        }
        .task(id: staysOpen) {
            guard state.expanded, !staysOpen else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { state.expanded = false }
        }
        .environment(\.colorScheme, .dark)
        .animation(morph, value: glassSize)
        .animation(morph, value: collapsed)
        .animation(morph, value: hovering)
        .animation(.smooth(duration: 0.25), value: offTask)
        .animation(.smooth(duration: 0.25), value: model.phase)
        .focusEffectDisabled()
        // The panel never becomes the active window; keep controls from drawing in their inactive (dimmed) state.
        .environment(\.controlActiveState, .key)
        .onAppear {
            SettingsOpener.action = openSettings
            WelcomeOpener.action = openWindow
            if CommandLine.arguments.contains("--open-settings-from-panel") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SettingsOpener.open() }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Settings…") { SettingsOpener.open() }
        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        Button(settings.panelStyle == .compact ? "Use Full Window" : "Use Compact Window") {
            settings.panelStyle = settings.panelStyle == .compact ? .full : .compact
        }
        Button(settings.showMenuBarIcon ? "Hide Menu Bar Icon" : "Show Menu Bar Icon") {
            settings.showMenuBarIcon.toggle()
        }
        Divider()
        Button("Quit Side Eye") { NSApp.terminate(nil) }
    }

    private var full: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 10) {
                switch model.phase {
                case .idle: idle
                case .working: working
                case .onBreak: onBreak
                }
            }
        }
        .padding(14)
        .frame(width: Self.fullWidth, alignment: .leading)
    }

    // MARK: States

    /// The status icon alone.
    private var compact: some View {
        Group {
            switch model.phase {
            case .idle: idleEye
            case .working: statusIcon
            case .onBreak:
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .matchedGeometryEffect(id: "icon", in: icon, isSource: collapsed)
        .frame(width: Self.compactSize.width, height: Self.compactSize.height)
        .help(compactHelp)
    }

    private var compactHelp: String {
        switch model.phase {
        case .idle: "Click to start a session"
        case .working: "\(model.task) · \(statusText)"
        case .onBreak: "Break"
        }
    }

    private var idleEye: some View {
        AnimatedEye(state: .neutral, enabled: settings.blinkFloatingPanelIcon && settings.showFloatingPanel) { icon in
            Image(nsImage: icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var idle: some View {
        HStack(spacing: 10) {
            idleEye
                .matchedGeometryEffect(id: "icon", in: icon, isSource: !collapsed)
            TextField("What are you working on?", text: $model.taskDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($taskFocused)
                .onSubmit { model.start(task: model.taskDraft) }
            if model.needsSetup {
                GlassButton("Set Up", symbol: "checklist", prominent: true) { WelcomeOpener.open() }
            } else if model.outOfCredit {
                GlassButton("Add Credits", symbol: "creditcard", prominent: true) { NSWorkspace.shared.open(Credit.addCreditPage) }
                    .help("Your OpenRouter account is out of credits. Side Eye notices once they're added.")
            } else {
                GlassButton("Start", symbol: "play.fill", prominent: true) { model.start(task: model.taskDraft) }
                    .disabled(model.taskDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                statusIcon
                    .matchedGeometryEffect(id: "icon", in: icon, isSource: !collapsed)
                VStack(alignment: .leading, spacing: 1) {
                    workingTask
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(offTask ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transaction { $0.animation = nil }
                        .help(model.judgeFailed ? model.lastError ?? "" : "")
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    if settings.showPanelTimer, let countdown = model.countdown {
                        Countdown(text: countdown)
                    }
                    PomoCount(count: model.pomosToday).font(.system(size: 11))
                }
            }
            if hovering || offTask || model.outOfCredit {
                HStack(spacing: 8) {
                    if model.outOfCredit {
                        GlassButton("Add Credits", symbol: "creditcard", prominent: true) {
                            NSWorkspace.shared.open(Credit.addCreditPage)
                        }
                    } else if offTask {
                        GlassButton("I'm on task!", symbol: "checkmark") { model.markCurrentOnTask() }
                    } else if model.probablyOnTask {
                        GlassButton("Yes, on task", symbol: "checkmark") {
                            model.markCurrentOnTask()
                            state.expanded = false
                        }
                    }
                    Spacer(minLength: 0)
                    // Same effect either way (ends the block); the walk nudge only makes sense when you've drifted.
                    if model.judgment == .off {
                        GlassButton("Go for a walk", symbol: "figure.walk") { model.goForWalk() }
                    } else {
                        GlassButton("Stop session", symbol: "stop.fill") { model.goForWalk() }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var onBreak: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .matchedGeometryEffect(id: "icon", in: icon, isSource: !collapsed)
            VStack(alignment: .leading, spacing: 1) {
                Text("Break").font(.system(size: 14, weight: .semibold))
                PomoCount(count: model.pomosToday).font(.system(size: 12))
            }
            Spacer(minLength: 8)
            if settings.showPanelTimer, let countdown = model.countdown { Countdown(text: countdown) }
            GlassButton("Skip", symbol: "forward.fill") { model.skipTimer() }
        }
    }

    /// The task, or while switching, a field for the next one. Click the task to switch; Return switches, Esc or
    /// clicking away keeps the current one.
    @ViewBuilder private var workingTask: some View {
        if switchingTask {
            TextField("What's next?", text: $model.taskDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .focused($taskFocused)
                .onSubmit {
                    model.switchTask(to: model.taskDraft)
                    switchingTask = false
                }
                .onExitCommand { endSwitching() }
                .onChange(of: taskFocused) { _, focused in if !focused { endSwitching() } }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.task)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                if hovering {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { beginSwitching() }
            .help("Switch to another task — the timer keeps running")
        }
    }

    private func beginSwitching() {
        model.taskDraft = model.task
        switchingTask = true
        // Clicks don't make the panel key on their own while the text field isn't there yet.
        NSApp.windows.first { $0 is FloatingPanel }?.makeKey()
        DispatchQueue.main.async { taskFocused = true }
    }

    private func endSwitching() {
        guard switchingTask else { return }
        switchingTask = false
        model.taskDraft = model.task
    }

    // MARK: Status

    /// A window switch shows at once: new title, spinning dotted circle. Nothing animates here.
    private var statusIcon: some View {
        Group {
            if model.evaluating, !model.excluded, !model.outOfCredit {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.rotate, options: .repeat(.continuous))
            } else if let remaining = model.graceRemaining {
                GraceRing(remaining: remaining, lineWidth: 2.5)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: 18, height: 18)
        .transaction { $0.animation = nil }
    }

    private var statusSymbol: String {
        if model.outOfCredit { return "creditcard.trianglebadge.exclamationmark" }
        if model.excluded { return "eye.slash.fill" }
        if model.judgeFailed { return "exclamationmark.triangle.fill" }
        switch model.judgment {
        case .on: return "checkmark.circle.fill"
        case .off: return "exclamationmark.circle.fill"
        case .unsure: return "checkmark.circle"  // probably on task; hover to confirm it
        default: return "circle.dotted"
        }
    }

    private var statusColor: Color {
        if model.outOfCredit || model.judgeFailed { return .orange }
        if model.excluded { return .secondary }
        switch model.judgment {
        case .on: return .green
        case .unsure: return .yellow
        case .off: return .white  // the whole panel is red; a red icon would vanish
        default: return .secondary
        }
    }

    private var statusText: String {
        if model.outOfCredit { return "Out of OpenRouter credits · not judging" }
        guard let snap = model.current else { return "Watching…" }
        if model.excluded { return "\(snap.shortLabel) · not judged" }
        if model.judgeFailed { return "\(snap.shortLabel) · couldn't judge" }
        return snap.statusLabel
    }
}

// MARK: - Pieces

private struct Countdown: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: text)
    }
}

/// Capsule glass button (prominent = tinted primary action).
struct GlassButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    init(_ title: String, symbol: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
        }
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
        if prominent {
            // Drawn by hand: the system's prominent styles render grey whenever the window isn't key,
            // and this panel almost never is.
            button.buttonStyle(AccentCapsuleStyle())
        } else {
            button.buttonStyle(.glass)
        }
    }
}

private struct AccentCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// Countdown ring for the grace period: full when it starts, empty when drifting starts to show. No number.
struct GraceRing: View {
    let remaining: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.35), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: remaining)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        // `now` ticks once a second; animate each step so the ring drains smoothly.
        .animation(.linear(duration: 1), value: remaining)
        .accessibilityLabel("Grace period")
    }
}

struct PomoCount: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count) today", systemImage: "timer")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help("\(count) pomodoro\(count == 1 ? "" : "s") completed today")
        }
    }
}
