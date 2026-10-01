import AppKit
import FocusCore
import SwiftUI

/// First-run setup: Accessibility and the OpenRouter key (required), Screen Recording (for screenshots, on by
/// default), then how the app works. Opens on launch while a required step is missing; the menu's setup card and the
/// floating window's Set Up button open it too.
struct WelcomeView: View {
    let model: AppModel
    @State private var openAtLogin = true
    @State private var keyDraft = ""
    @State private var checking = false
    @State private var keyError: String?
    @State private var keyNote: String?
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    static let id = "welcome"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 16) {
                WelcomeStep(number: 1, done: model.axTrusted, title: "Allow Accessibility",
                            detail: "Lets Side Eye see which app, window and web page is in front. Turn on Side Eye in the list that opens.") {
                    Button("Open System Settings…") {
                        _ = AX.isTrusted(prompt: true)
                        AX.openAccessibilitySettings()
                    }
                }
                WelcomeStep(number: 2, done: model.screenRecording, title: "Allow Screen Recording",
                            detail: "Lets Side Eye read windows that don't expose their text, like PDFs and some apps. It reads the screenshot on your Mac first; only if that's not enough is it described by AI, with personal details blacked out.") {
                    Button("Open System Settings…") {
                        // Asking is what adds Side Eye to the Screen Recording list.
                        if !ScreenReader.requestPermission() {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        model.refreshPermissions()
                    }
                }
                WelcomeStep(number: 3, done: model.hasAPIKey, title: "Add your OpenRouter key",
                            detail: "Side Eye asks AI models whether a window fits your task, through OpenRouter. It costs about a cent per hour of focus. The key is kept in your Mac Keychain. Only providers with zero data-retention according to OpenRouter are used.") {
                    keyEntry
                }
                if let keyNote, model.hasAPIKey {
                    Label(keyNote, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 30)
                }
            }

            if !model.needsSetup { howItWorks }

            HStack {
                if model.needsSetup {
                    Text("You can finish this later from the menu bar eye.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Open Side Eye at login", isOn: $openAtLogin)
                }
                Spacer()
                if model.needsSetup {
                    Button("Later") { dismissWindow(id: Self.id) }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                } else {
                    Button("Start Focusing") {
                        if openAtLogin { model.settings.openAtLogin = true }
                        dismissWindow(id: Self.id)
                    }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.25), value: model.needsSetup)
        .onAppear {
            WelcomeOpener.action = openWindow
            NSApp.activate()
            model.refreshPermissions()
        }
        // Permissions are granted in System Settings; come back to the next step when one is.
        .onChange(of: model.axTrusted) { _, trusted in
            if trusted { NSApp.activate() }
        }
        .onChange(of: model.screenRecording) { _, granted in
            if granted { NSApp.activate() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Side Eye").font(.title2.weight(.semibold))
                Text("Tell it what you're working on. It gives you the side-eye when you drift.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("sk-or-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let keyError {
                Label(keyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Get a key at openrouter.ai") { NSWorkspace.shared.open(Self.keysURL) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    /// Tries the key before saving it, so a typo shows up here rather than at the first Start. Only a rejected key
    /// isn't saved: a key that works but has no credit, or a network error, still counts.
    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        checking = true
        keyError = nil
        keyNote = nil
        Task {
            defer { checking = false }
            do {
                _ = try await model.checkKey(key)
            } catch OpenRouterError.http(401, _) {
                keyError = "OpenRouter didn't accept that key. Check that it's copied in full."
                return
            } catch OpenRouterError.http(402, _) {
                keyNote = "Saved, but your OpenRouter account is out of credit. Add some at openrouter.ai/settings/credits."
            } catch {
                keyNote = "Saved, but Side Eye couldn't reach OpenRouter to check it: \(error.localizedDescription)"
            }
            Keychain.setOpenRouterKey(key)
            keyDraft = ""
            model.refreshPermissions()
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You're set. Here's how it works:").font(.headline)
            HowItWorksRow(symbol: "pencil.line", color: .secondary,
                          text: "Type what you're working on in the floating window or the menu bar eye, and press Start.")
            HowItWorksRow(symbol: "checkmark.circle.fill", color: .green,
                          text: "Green: the window in front fits your task.")
            HowItWorksRow(symbol: "exclamationmark.circle.fill", color: .red,
                          text: "Red: you've drifted. If it's wrong, press I'm on task! and Side Eye learns that windows like it count.")
            HowItWorksRow(symbol: "checkmark.circle", color: .yellow,
                          text: "Yellow: probably on task. Hover the floating window to confirm.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
    }

    static let keysURL = URL(string: "https://openrouter.ai/settings/keys")!
}

/// A numbered step: a check once it's done, otherwise its explanation and controls.
private struct WelcomeStep<Controls: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "\(number).circle").foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(done ? .secondary : .primary)
                if !done {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    controls
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: done)
    }
}

private struct HowItWorksRow: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Opens the welcome window from anywhere, like `SettingsOpener`.
@MainActor
enum WelcomeOpener {
    static var action: OpenWindowAction?

    static func open() {
        NSApp.activate()
        action?(id: WelcomeView.id)
    }
}
