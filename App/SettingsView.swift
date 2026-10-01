import FocusCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: Settings

    var body: some View {
        TabView {
            // Each tab sizes to its content; the window animates between them like System Settings.
            GeneralPane(model: model, settings: settings)
                .frame(width: 520, height: 650)
                .tabItem { Label("General", systemImage: "gearshape") }
            JudgingPane(settings: settings)
                .frame(width: 520, height: 300)
                .tabItem { Label("Judging", systemImage: "scale.3d") }
            PrivacyPane(model: model, settings: settings)
                .frame(width: 520, height: 590)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            AccountPane(model: model, settings: settings)
                .frame(width: 520, height: 400)
                .tabItem { Label("Account", systemImage: "key") }
        }
        .onAppear { model.refreshPermissions() }
    }
}

// MARK: - General

private struct GeneralPane: View {
    let model: AppModel
    @Bindable var settings: Settings
    @State private var openAtLogin = false
    @State private var checkForUpdates = false

    var body: some View {
        Form {
            Section {
                Toggle("Use pomodoro timer", isOn: $settings.usePomodoro)
                Picker("Focus length", selection: $settings.workMinutes) {
                    ForEach(Settings.workLengths, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .disabled(!settings.usePomodoro)
                Picker("Break length", selection: $settings.breakMinutes) {
                    ForEach(Settings.breakLengths, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .disabled(!settings.usePomodoro)
            } header: {
                Text("Focus Sessions")
            }

            Section("Floating Window") {
                Toggle("Show floating window", isOn: $settings.showFloatingPanel)
                Picker("Style", selection: $settings.panelStyle) {
                    ForEach(PanelStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.showFloatingPanel)
                Toggle("Show timer", isOn: $settings.showPanelTimer)
                    .disabled(!settings.showFloatingPanel)
                Toggle("Animate icon", isOn: $settings.blinkFloatingPanelIcon)
                    .disabled(!settings.showFloatingPanel)
            }

            Section("Menu Bar") {
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                    .disabled(!settings.showFloatingPanel)
                if settings.menuBarIconBlocked {
                    LabeledContent {
                        Button("Open Menu Bar Settings…") { MenuBarAccess.openSettings() }
                    } label: {
                        Label("macOS is hiding the icon", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Toggle("Animate menu bar eye", isOn: $settings.blinkMenuBarIcon)
                    .disabled(!settings.showMenuBarIcon)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        settings.openAtLogin = on
                        openAtLogin = settings.openAtLogin
                    }
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { _, on in Updater.shared.automaticallyChecks = on }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            openAtLogin = settings.openAtLogin
            checkForUpdates = Updater.shared.automaticallyChecks
        }
    }
}

// MARK: - Judging

private struct JudgingPane: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker("Strictness", selection: $settings.strictness) {
                    ForEach(Strictness.allCases) { Text($0.title).tag(Optional($0)) }
                    if settings.strictness == nil { Text("Custom").tag(Strictness?.none) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("Grace period", selection: $settings.gracePeriod) {
                    ForEach(Settings.gracePeriods, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    let model: AppModel
    @Bindable var settings: Settings
    @State private var screenPermission = ScreenReader.hasPermission
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Always") {
                    Text("App, window title, website address").foregroundStyle(.secondary)
                }
                Toggle("Read text in the window when unsure", isOn: $settings.useAXText)
                Toggle("Take a screenshot when there's little text", isOn: $settings.useScreenshots)
                .onChange(of: settings.useScreenshots) { _, on in
                    if on, !ScreenReader.hasPermission { ScreenReader.requestPermission() }
                    screenPermission = ScreenReader.hasPermission
                }
                if settings.useScreenshots, !screenPermission {
                    LabeledContent {
                        Button("Open Settings…") {
                            // Asking is what adds Side Eye to the Screen Recording list.
                            if ScreenReader.requestPermission() { screenPermission = true; return }
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    } label: {
                        Label("Needs Screen Recording permission", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Toggle("Describe screenshots with AI", isOn: $settings.useDescriber)
                .disabled(!settings.useScreenshots)
                Toggle("Learn from your other tasks and corrections", isOn: $settings.useTaskBrief)
                Toggle("Learn what the task is about from text in on-task windows", isOn: $settings.useOnTaskText)
                .disabled(!settings.useTaskBrief || !settings.useAXText)
            } header: {
                Text("What Side Eye Looks At")
            } footer: {
                Text("Emails, phone numbers, card numbers, SSNs and API keys are removed from text and blacked out in screenshots before anything leaves your Mac. Note: this process may be imperfect; note that AI calls only use zero-data-retention providers.")
            }

            Section {
                List(selection: $selection) {
                    // Uninstalled defaults (e.g. 1Password when you use another manager) stay excluded but aren't listed.
                    ForEach(settings.excludedBundleIDs.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                            id: \.self) { id in
                        AppRow(bundleID: id).tag(id)
                    }
                }
                .frame(minHeight: 130)
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 0) {
                    Button { addApp() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                    Button {
                        if let selection { settings.excludedBundleIDs.removeAll { $0 == selection } }
                        selection = nil
                    } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Never Look At")
            }

            Section {
                LabeledContent("Activity log") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.defaultURL]) }
                }
                Toggle("Debug mode (saves additional data)", isOn: $settings.debugLogging)
            }
        }
        .formStyle(.grouped)
        .onAppear { screenPermission = ScreenReader.hasPermission }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Never Look At"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.excludedBundleIDs.contains(id) {
                settings.excludedBundleIDs.append(id)
            }
        }
    }
}

/// An app's icon and name, from its bundle ID; falls back to the ID if it isn't installed.
private struct AppRow: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.secondary)
                Text(bundleID).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Account

private struct AccountPane: View {
    let model: AppModel
    @Bindable var settings: Settings
    @State private var keyDraft = ""
    @State private var editingKey = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                if model.hasAPIKey && !editingKey {
                    LabeledContent("API key") {
                        HStack {
                            Label("Saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Change…") { editingKey = true }
                        }
                    }
                } else {
                    LabeledContent("API key") {
                        HStack {
                            SecureField("sk-or-…", text: $keyDraft).labelsHidden()
                            Button("Save") {
                                Keychain.setOpenRouterKey(keyDraft)
                                keyDraft = ""
                                editingKey = false
                                model.refreshPermissions()
                            }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                LabeledContent("Connection") {
                    HStack {
                        if testing {
                            ProgressView().controlSize(.small)
                        } else if let testResult {
                            Text(testResult).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Button("Test") {
                            testing = true
                            Task {
                                testResult = await model.testConnection()
                                testing = false
                            }
                        }
                        .disabled(!model.hasAPIKey || testing)
                    }
                }
                LabeledContent("Spent today", value: model.costToday(), format: .currency(code: "USD").precision(.fractionLength(4)))
            } header: {
                Text("OpenRouter")
            } footer: {
                Link("Get a key", destination: WelcomeView.keysURL).font(.caption)
            }

            Section("Models") {
                TextField("Judge", text: $settings.jevModel)
                TextField("Screenshot describer", text: $settings.describerModel)
                TextField("Task brief", text: $settings.briefModel)
                if let provider = model.describerProvider {
                    LabeledContent("Last describer provider", value: provider)
                }
            }
        }
        .formStyle(.grouped)
    }
}
