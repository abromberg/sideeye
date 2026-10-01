import FocusCore
import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel
    @Bindable var settings: Settings
    @FocusState private var taskFocused: Bool
    @State private var taskSelection: TextSelection?
    /// Editing the task mid-block to move on to another one.
    @State private var switchingTask = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.needsSetup { setupCard }
            Group {
                switch model.phase {
                case .idle: idleCard
                case .working: workingCard
                case .onBreak: breakCard
                }
            }
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            Divider().padding(.horizontal, 4)

            VStack(spacing: 0) {
                MenuRow("Show Floating Window", checked: settings.showFloatingPanel) {
                    settings.showFloatingPanel.toggle()
                }
                MenuRow("Settings…", shortcut: "⌘,") { showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                MenuRow("Check for Updates…") { Updater.shared.checkForUpdates() }
                MenuRow("Quit Side Eye", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(10)
        .frame(width: 300)
        .onChange(of: model.phase) { endSwitching() }
        .onAppear {
            endSwitching()
            model.refreshPermissions()
            if model.phase == .idle {
                // Fresh each open: cursor at the end, nothing selected (focusing alone selects all).
                taskFocused = true
                DispatchQueue.main.async { taskSelection = TextSelection(insertionPoint: model.taskDraft.endIndex) }
            }
        }
    }

    private func showSettings() {
        SettingsOpener.action = openSettings
        SettingsOpener.open()
    }

    // MARK: Setup

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish setting up").font(.headline)
            SetupStep(done: model.axTrusted, title: "Allow Accessibility",
                      detail: "Lets Side Eye see which app and window you're in.", action: "Allow…") {
                _ = AX.isTrusted(prompt: true)
                AX.openAccessibilitySettings()
            }
            SetupStep(done: model.hasAPIKey, title: "Add your OpenRouter key",
                      detail: "Used to judge whether you're on task.", action: "Add…") {
                WelcomeOpener.open()
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: States

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What are you working on?", text: $model.taskDraft, selection: $taskSelection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1...3)
                .focused($taskFocused)
                .onSubmit(start)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Toggle("Pomodoro", isOn: $settings.usePomodoro)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
                if settings.usePomodoro {
                    Picker("Length", selection: $settings.workMinutes) {
                        ForEach(Settings.workLengths, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .font(.callout)

            Button(action: start) {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.taskDraft.trimmingCharacters(in: .whitespaces).isEmpty || !model.canStart)

            if model.pomosToday > 0 || model.lastSummary != nil {
                VStack(alignment: .leading, spacing: 2) {
                    PomoCount(count: model.pomosToday)
                    if let summary = model.lastSummary {
                        Text("Last block: \(summary)").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func start() {
        model.start(task: model.taskDraft)
    }

    private func beginSwitching() {
        model.taskDraft = model.task
        switchingTask = true
        DispatchQueue.main.async { taskFocused = true }
    }

    private func endSwitching() {
        guard switchingTask else { return }
        switchingTask = false
        model.taskDraft = model.task
    }

    private var workingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if switchingTask {
                    TextField("What's next?", text: $model.taskDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .lineLimit(1...3)
                        .focused($taskFocused)
                        .onSubmit {
                            model.switchTask(to: model.taskDraft)
                            switchingTask = false
                        }
                        .onExitCommand(perform: endSwitching)
                } else {
                    Button(action: beginSwitching) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(model.task)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Switch to another task — the timer keeps running")
                }
                Spacer(minLength: 8)
                if let countdown = model.countdown {
                    Text(countdown)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let remaining = model.graceRemaining {
                    GraceRing(remaining: remaining, lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                } else {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.callout)
                    if let snap = model.current, !snap.displayTitle.isEmpty, snap.displayTitle != snap.shortLabel {
                        Text(snap.displayTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Text(model.stats.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if model.showsOffTask || model.probablyOnTask {
                    Button { model.markCurrentOnTask() } label: {
                        Label(model.showsOffTask ? "I'm on task!" : "Yes, on task", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                }
                // Same effect either way (ends the block); the walk nudge only makes sense when you've drifted.
                let drifted = model.judgment == .off
                Button { model.goForWalk() } label: {
                    Label(drifted ? "Go for a Walk" : "Stop Session", systemImage: drifted ? "figure.walk" : "stop.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
    }

    private var breakCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Break", systemImage: "cup.and.saucer.fill").font(.headline)
                Spacer()
                if let countdown = model.countdown {
                    Text(countdown)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            if let summary = model.lastSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PomoCount(count: model.pomosToday).font(.caption)
            Button { model.skipTimer() } label: {
                Label("Skip Break", systemImage: "forward.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    // MARK: Status

    private var statusSymbol: String {
        if model.excluded { return "eye.slash.fill" }
        if model.showsOffTask { return "exclamationmark.circle.fill" }
        if model.probablyOnTask { return "checkmark.circle" }
        return model.judgment == .on ? "checkmark.circle.fill" : "circle.dotted"
    }

    private var statusColor: Color {
        if model.excluded { return .secondary }
        if model.showsOffTask { return .red }
        if model.probablyOnTask { return .yellow }
        return model.judgment == .on ? .green : .secondary
    }

    private var statusTitle: String {
        guard let snap = model.current else { return "Watching…" }
        // Just where you are; the window's title is on the line below.
        if model.excluded { return "\(snap.shortLabel) · not looked at" }
        return snap.shortLabel
    }
}

/// One line of the setup checklist.
private struct SetupStep: View {
    let done: Bool
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).strikethrough(done, color: .secondary)
                if !done { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if !done {
                Button(action, action: perform).controlSize(.small)
            }
        }
    }
}

/// A row that looks and behaves like a native menu item: full-width, highlighted on hover. Like a native menu, every
/// row keeps a checkmark gutter so titles line up whether or not a row is checked.
private struct MenuRow: View {
    let title: String
    var shortcut: String?
    var checked = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, shortcut: String? = nil, checked: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.checked = checked
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 10)
                    .opacity(checked ? 1 : 0)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .foregroundStyle(hovering && isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                if hovering && isEnabled {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}
