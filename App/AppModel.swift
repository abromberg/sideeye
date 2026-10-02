import AppKit
import FocusCore
import Observation

enum Phase: Equatable {
    case idle
    case working
    case onBreak(until: Date)
}

/// Orchestrates: context watcher → pipeline (Jev, escalating) → on/off state shown in the floating window and menu bar,
/// inside pomodoro blocks.
@MainActor @Observable
final class AppModel {
    let settings = Settings()
    @ObservationIgnored private let watcher = ContextWatcher()
    @ObservationIgnored private let screenReader = ScreenReader()
    @ObservationIgnored private let floatingPanel = FloatingPanelController()
    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var evalTask: Task<Void, Never>?
    @ObservationIgnored private var wasShowingOffTask = false
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var cache: [String: Verdict] = [:]
    @ObservationIgnored private var exceptionKeys = Set<String>()
    /// The brief being written. Verdicts wait for it, up to `briefWait`; after that they use `lastBrief`.
    @ObservationIgnored private var briefTask: Task<String?, Never>?
    /// The last brief written for this task, used while a rewrite is slow or if it fails.
    @ObservationIgnored private var lastBrief: String?
    /// Windows confirmed this session; cleaned of app chrome when the brief is written.
    @ObservationIgnored private var confirmedNow: [ContextSnapshot] = []
    /// The running block's length, logged on every session row in it (a task switch opens a new row mid-block).
    @ObservationIgnored private var blockMinutes: Int?
    /// Text last read from each window judged on task this session, by cache key: the brief learns from it what the
    /// task is about right now. Re-read every few seconds while such a window is in front.
    @ObservationIgnored private var onTaskText: [String: SeenText] = [:]
    /// The on-task text the current brief was written from, by cache key.
    @ObservationIgnored private var briefOnTaskText: [String: String] = [:]
    @ObservationIgnored private var lastOnTaskRead = Date.distantPast
    @ObservationIgnored private var lastTextRewrite = Date.distantPast
    @ObservationIgnored private var lastCreditCheck = Date.distantPast
    /// Demo mode: fake state, so nothing checks OpenRouter.
    @ObservationIgnored private var isDemo = false

    private(set) var phase: Phase = .idle
    /// The task field's text, shared by the floating window and the menu bar so editing either updates both.
    var taskDraft = ""
    private(set) var task = ""
    private(set) var sessionID: Int64?
    private(set) var blockEndsAt: Date?
    private(set) var exceptions: [String] = []
    private(set) var current: ContextSnapshot?
    private(set) var currentEventID: Int64?
    private(set) var verdict: Verdict?
    private(set) var excluded = false
    private(set) var evaluating = false
    private(set) var stats = BlockStats()
    private(set) var lastSummary: String?
    private(set) var lastError: String?
    private(set) var describerProvider: String?
    private(set) var now = Date()
    private(set) var axTrusted = AX.isTrusted()
    private(set) var screenRecording = ScreenReader.hasPermission
    private(set) var hasAPIKey = Keychain.openRouterKey() != nil
    /// OpenRouter has no credit left (a 402, or the balance check). Nothing is judged until it's back; while it's out,
    /// the balance is checked every `creditRecheck` so judging picks up again on its own.
    private(set) var outOfCredit = false
    private(set) var pomosToday = 0
    /// Until then, off-task verdicts aren't shown (Settings → grace period), so you can get to your work first.
    private(set) var graceEndsAt: Date?

    init() {
        do {
            store = try Store()
        } catch {
            lastError = "Couldn't open the log database: \(error.localizedDescription)"
        }
        taskDraft = settings.lastTask
        observePanelSetting()
        refreshPomoCount()
        if let demo = CommandLine.arguments.first(where: { $0.hasPrefix("--demo=") }) { showDemo(String(demo.dropFirst(7))) }
        if let probe = CommandLine.arguments.first(where: { $0.hasPrefix("--probe-screenshot=") }) {
            runScreenshotProbe(into: URL(fileURLWithPath: String(probe.dropFirst(19))))
        }
        if let probe = CommandLine.arguments.first(where: { $0.hasPrefix("--probe-text=") }) {
            runTextProbe(into: URL(fileURLWithPath: String(probe.dropFirst(13))))
        }
        watcher.onSnapshot = { [weak self] snap, trigger in self?.evaluate(snap, trigger: trigger) }
        checkCredit()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Derived state

    var judgment: Judgment? { excluded ? nil : verdict?.judgment }
    /// Still in between the bands once every evidence step has run. Shown as a softer on task, never red: a middling
    /// score is a coin flip, and a false alarm costs more than a missed drift. You can confirm it with "Yes, on task".
    var probablyOnTask: Bool { phase == .working && judgment == .unsure }
    var isWorking: Bool { phase == .working }
    /// Off task *and* past the grace period — what the UI shows as red. Judging runs from the start; showing waits.
    var showsOffTask: Bool {
        guard phase == .working, judgment == .off else { return false }
        return graceEndsAt.map { now >= $0 } ?? true
    }
    /// Judged off task but still inside the grace period: the share of grace left (1 → 0), shown as a countdown ring.
    var graceRemaining: Double? {
        guard phase == .working, judgment == .off, let end = graceEndsAt, now < end, settings.gracePeriod > 0 else { return nil }
        return min(1, max(0, end.timeIntervalSince(now) / settings.gracePeriod))
    }
    var canStart: Bool { !needsSetup && !outOfCredit }
    /// The welcome window's required steps. Until both are done, Start is disabled.
    var needsSetup: Bool { !(axTrusted && hasAPIKey) }
    /// The window in front went unjudged because the call failed (not for lack of credit, which shows on its own).
    var judgeFailed: Bool { phase == .working && !outOfCredit && !excluded && !evaluating && verdict == nil && lastError != nil }

    var countdown: String? {
        let end: Date? = switch phase {
        case .working: blockEndsAt
        case let .onBreak(until): until
        case .idle: nil
        }
        guard let end else { return nil }
        let s = max(0, Int(end.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Session lifecycle

    func start(task rawTask: String) {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, canStart else { return }
        blockMinutes = settings.usePomodoro ? settings.workMinutes : nil
        blockEndsAt = blockMinutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        wasShowingOffTask = false
        stats = BlockStats()
        lastSummary = nil
        lastError = nil
        verdict = nil
        current = nil
        lastTick = Date()
        phase = .working
        beginTask(task)
        watcher.start()
    }

    /// Moves the running block on to another task (the last one's done, say). The timer and the block's stats carry
    /// on; the log gets a new session row, so each task keeps its own windows and confirmations.
    func switchTask(to rawTask: String) {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .working, !task.isEmpty else { return }
        guard task != self.task else {
            taskDraft = task
            return
        }
        evalTask?.cancel()
        evaluating = false
        verdict = nil
        if let sessionID { try? store?.endSession(sessionID, reason: "switched", summary: stats.summary) }
        beginTask(task)
        // The watcher only speaks up when the window changes; judge the one in front against the new task now.
        if var snap = current {
            snap.at = Date()
            evaluate(snap, trigger: .taskSwitch)
        }
    }

    /// Opens a session row for `task` and sets up everything that's judged per task.
    private func beginTask(_ task: String) {
        if task != self.task {
            // Exceptions and cached verdicts only hold for the task they were made under.
            cache = [:]
            exceptionKeys = []
            exceptions = []
            confirmedNow = []
            onTaskText = [:]
            briefOnTaskText = [:]
            lastBrief = nil
        }
        self.task = task
        taskDraft = task
        settings.lastTask = task
        sessionID = try? store?.startSession(task: task, pomodoroMinutes: blockMinutes)
        // A fresh grace period: you've usually just finished something and need a moment to open the next thing.
        graceEndsAt = Date().addingTimeInterval(settings.gracePeriod)
        writeBrief()
    }

    /// (Re)writes the brief from your other tasks, this session's confirmations, and the text of this session's
    /// on-task windows. Verdicts cached under the old brief are dropped once the new one is in.
    private func writeBrief() {
        guard settings.useTaskBrief, let store else {
            briefTask = nil
            return
        }
        let writer = BriefWriter(model: settings.briefModel, record: recorder(event: nil), apiKey: { Keychain.openRouterKey() })
        let task = self.task, sessionID = self.sessionID, confirmed = confirmedNow
        let recent = onTaskTextEnabled
            ? Array(onTaskText.values.sorted { $0.at > $1.at }.prefix(BriefWriter.onTaskWindows)) : []
        for seen in recent { briefOnTaskText[seen.snap.cacheKey] = seen.text }
        briefTask = Task.detached {
            let past = (try? store.pastTasks(excludingSession: sessionID)) ?? []
            let chrome = (try? store.titleChrome()) ?? TitleChrome()
            let onTask = recent.map { OnTaskText(window: $0.snap.briefExample(chrome: chrome) ?? $0.snap.appName, text: $0.text) }
            return try? await writer.write(task: task, past: past, confirmedNow: confirmed.compactMap { $0.briefExample(chrome: chrome) },
                                           onTaskText: onTask)
        }
        let pending = briefTask
        Task { [weak self] in
            let brief = await pending?.value
            guard let self, self.briefTask == pending, self.task == task, let brief else { return }
            self.lastBrief = brief
            self.cache = [:]
        }
    }

    /// Ends the work block. `next` decides what follows (a break, or nothing).
    func endBlock(reason: String, next: Phase = .idle) {
        guard phase == .working else {
            phase = next
            return
        }
        evalTask?.cancel()
        watcher.stop()
        let summary = stats.summary
        lastSummary = summary
        if let sessionID { try? store?.endSession(sessionID, reason: reason, summary: summary) }
        blockEndsAt = nil
        evaluating = false
        phase = next
    }

    /// Ends the block — no walk timer; the point is to step away.
    func goForWalk() {
        if let sessionID { try? store?.logAction(session: sessionID, event: currentEventID, action: "walk", cacheKey: current?.cacheKey) }
        endBlock(reason: "walk")
    }

    func skipTimer() {
        phase = .idle
    }

    // MARK: Evaluation

    private func evaluate(_ snap: ContextSnapshot, trigger: Trigger) {
        guard phase == .working else { return }
        if snap.bundleID == Bundle.main.bundleIdentifier || snap.bundleID == "com.apple.loginwindow" { return }
        evalTask?.cancel()
        // The on-task window you're leaving: what you wrote or read there may change what the task is about.
        let leaving = judgment == .on && !evaluating ? current.flatMap { $0.cacheKey == snap.cacheKey ? nil : $0 } : nil
        current = snap
        lastOnTaskRead = .distantPast
        currentEventID = sessionID.flatMap { try? self.store?.logContext(session: $0, snapshot: snap, trigger: trigger.rawValue) }

        if settings.excludedBundleIDs.contains(snap.bundleID) {
            excluded = true
            verdict = nil
            evaluating = false
            return
        }
        excluded = false
        if settings.debugLogging { logDebugText(for: snap) }
        guard !outOfCredit else {
            verdict = nil
            evaluating = false
            return
        }

        let key = snap.cacheKey
        let known = exceptionKeys.contains(key)
            ? Verdict(onTask: 1, category: nil, stage: .exception, judgment: .on)
            : cache[key].flatMap { $0.judgment == .on ? Verdict(onTask: $0.onTask, category: $0.category, stage: .cache, judgment: .on) : nil }
        if let known {
            // Already on task; the brief can catch up with the window you left in the background.
            apply(known, to: snap, log: true)
            if let leaving { Task { await self.settleOnTaskText(leaving, reread: leaving.pid != snap.pid) } }
            return
        }
        guard let leaving, onTaskTextEnabled else { return judge(snap, useCache: true) }
        // Pending: keep the previous verdict's colour (only the icon spins while checking) so the UI doesn't flash
        // to neutral and back on every switch.
        evaluating = true
        evalTask = Task { [weak self] in
            // Before judging this window, let the brief see what you just wrote: a doc opened right after writing
            // about it in your journal is on task.
            let rewrote = await self?.settleOnTaskText(leaving, reread: leaving.pid != snap.pid) ?? false
            guard let self, !Task.isCancelled, self.current?.cacheKey == key else { return }
            self.judge(snap, useCache: !rewrote)
        }
    }

    /// Judges the window in front: from the cache if there's a verdict for it (and `useCache`), else through the pipeline.
    private func judge(_ snap: ContextSnapshot, useCache: Bool) {
        let key = snap.cacheKey
        if useCache, let cached = cache[key] {
            apply(Verdict(onTask: cached.onTask, category: cached.category, stage: .cache, judgment: cached.judgment),
                  to: snap, log: true)
            return
        }
        evaluating = true

        let pipeline = Pipeline(judge: JevJudge(model: settings.jevModel, record: recorder(event: currentEventID),
                                                apiKey: { Keychain.openRouterKey() }), bands: settings.bands)
        let sources = evidenceSources(for: snap)
        let task = self.task, exceptions = self.exceptions
        let eventID = currentEventID
        let store = self.store
        let briefTask = self.briefTask, lastBrief = self.lastBrief
        evalTask = Task { [weak self] in
            do {
                let brief = await Self.brief(from: briefTask, previous: lastBrief)
                try Task.checkCancellation()
                let v = try await pipeline.run(task: task, brief: brief, exceptions: exceptions, snapshot: snap, sources: sources) { step in
                    if let eventID {
                        try? store?.logVerdict(event: eventID, verdict: step.verdict, model: step.result.model,
                                               cost: step.result.cost, latencyMs: step.latencyMs, stateDigest: step.stateDigest)
                    }
                    if let provider = step.describerProvider {
                        await MainActor.run { self?.describerProvider = provider }
                    }
                }
                guard let self, !Task.isCancelled, self.current?.cacheKey == key else { return }
                self.lastError = nil
                self.apply(v, to: snap, log: false)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch OpenRouterError.http(402, _) {
                self?.setOutOfCredit(true)
            } catch {
                guard let self, self.current?.cacheKey == key else { return }
                self.lastError = error.localizedDescription
                self.evaluating = false
                self.verdict = nil  // no answer for this window; don't leave the previous window's verdict showing
            }
        }
    }

    /// Gemini briefs take 2–3 s but now and then 20: a verdict waits this long for one, then uses the previous brief.
    private static let briefWait: Duration = .seconds(6)

    /// The brief being written, or the previous one if it's slow (see `briefWait`) or fails.
    private nonisolated static func brief(from task: Task<String?, Never>?, previous: String?) async -> String? {
        guard let task else { return previous }
        // A race, not a task group: a group would wait for the brief anyway, since waiting on a task can't be cancelled.
        return await withCheckedContinuation { done in
            let once = Once()
            Task {
                let brief = await task.value
                if once.claim() { done.resume(returning: brief ?? previous) }
            }
            Task {
                try? await Task.sleep(for: briefWait)
                if once.claim() { done.resume(returning: previous) }
            }
        }
    }

    // MARK: On-task text

    private var onTaskTextEnabled: Bool { settings.useOnTaskText && settings.useAXText && settings.useTaskBrief }

    /// On leaving a window judged on task: takes its latest text (read again if it's in another app, whose focused
    /// window is still that one; otherwise the last read from while it was in front) and rewrites the brief if the
    /// text has gained enough words since the brief saw it. Returns whether it did.
    @discardableResult
    private func settleOnTaskText(_ left: ContextSnapshot, reread: Bool) async -> Bool {
        guard onTaskTextEnabled else { return false }
        if reread, let text = await Self.readText(of: left) { note(text, for: left) }
        guard let seen = onTaskText[left.cacheKey], Date().timeIntervalSince(lastTextRewrite) >= 180,
              OnTaskText.newWords(seen.text, since: briefOnTaskText[left.cacheKey]) >= BriefWriter.rewriteAfterNewWords
        else { return false }
        lastTextRewrite = Date()
        writeBrief()
        return true
    }

    /// Keeps the text of the on-task window in front current, every 10 s (see `tickWorking`).
    private func readOnTaskText(_ snap: ContextSnapshot) {
        Task { [weak self] in
            guard let text = await Self.readText(of: snap) else { return }
            self?.note(text, for: snap)
        }
    }

    private func note(_ text: String, for snap: ContextSnapshot) {
        onTaskText[snap.cacheKey] = SeenText(snap: snap, text: text, at: Date())
    }

    /// The window's text, or nil if its app's focused window is now a different one (closed, or another tab).
    private nonisolated static func readText(of snap: ContextSnapshot) async -> String? {
        let pid = snap.pid, bundleID = snap.bundleID, title = snap.windowTitle
        return await Task.detached(priority: .utility) {
            guard ContextSnapshot.normalizeTitle(AX.windowTitle(pid)) == ContextSnapshot.normalizeTitle(title) else { return nil }
            let text = AX.visibleText(pid, bundleID: bundleID)
            return text.isEmpty ? nil : text
        }.value
    }

    /// Debug logging: records each model call with the session and window it was made for.
    private func recorder(event: Int64?) -> CallRecorder? {
        guard settings.debugLogging, let store else { return nil }
        let session = sessionID
        return { call in try? store.logModelCall(session: session, event: event, call: call) }
    }

    /// Debug logging: the window's text at every switch, cached and confirmed windows too, so the log shows how a
    /// document changed while you worked in it (a verdict only reads text when the judge is unsure).
    private func logDebugText(for snap: ContextSnapshot) {
        guard let eventID = currentEventID, let store else { return }
        let pid = snap.pid, bundleID = snap.bundleID
        Task.detached(priority: .utility) {
            try? store.logDebugText(event: eventID, text: AX.visibleText(pid, bundleID: bundleID))
        }
    }

    private func evidenceSources(for snap: ContextSnapshot) -> EvidenceSources {
        let pid = snap.pid, title = snap.windowTitle, bundleID = snap.bundleID
        let useAX = settings.useAXText, useShots = settings.useScreenshots
        let reader = screenReader
        let describer = settings.useScreenshots && settings.useDescriber
            ? Describer(model: settings.describerModel, record: recorder(event: currentEventID), apiKey: { Keychain.openRouterKey() }) : nil
        var describe: (@Sendable (Data) async throws -> Description)?
        if let describer {
            describe = { @Sendable jpeg in try await describer.describe(jpeg: jpeg) }
        }
        return EvidenceSources(
            axText: {
                guard useAX else { return nil }
                return await Task.detached(priority: .userInitiated) { AX.visibleText(pid, bundleID: bundleID) }.value
            },
            screenshot: {
                guard useShots else { return nil }
                let page = await Task.detached(priority: .userInitiated) { AX.webAreaFrame(pid, bundleID: bundleID) }.value
                return await reader.read(pid: pid, title: title, crop: page)
            },
            describe: describe)
    }

    private func apply(_ v: Verdict, to snap: ContextSnapshot, log: Bool) {
        evaluating = false
        verdict = v
        if log, let currentEventID {
            try? store?.logVerdict(event: currentEventID, verdict: v, model: nil, cost: nil, latencyMs: 0, stateDigest: nil)
        }
        // Close calls aren't cached: Jev varies by a few points run to run, so one lucky 0.61 against a 0.60 line
        // shouldn't stand for the whole session. They're judged again next time you come back to the window.
        let margin = 0.05, bands = settings.bands
        let closeCall = abs(v.onTask - bands.on) < margin || abs(v.onTask - bands.off) < margin
        if v.judgment != .unsure, !closeCall, v.stage != .cache, v.stage != .exception {
            cache[snap.cacheKey] = v
        }
    }

    // MARK: Actions

    /// "I'm on task!" — this exact window counts as on task for the rest of the session, and the brief is rewritten
    /// with it as an example, so similar windows count too.
    func markCurrentOnTask() {
        guard let snap = current else { return }
        exceptionKeys.insert(snap.cacheKey)
        if !exceptions.contains(snap.descriptor) { exceptions.append(snap.descriptor) }
        if !confirmedNow.contains(where: { $0.cacheKey == snap.cacheKey }) {
            confirmedNow.append(snap)
            writeBrief()
        }
        if let sessionID {
            try? store?.logAction(session: sessionID, event: currentEventID, action: "for_task", cacheKey: snap.cacheKey,
                                  detail: verdict.map { String(format: "%.3f", $0.onTask) })
        }
        evalTask?.cancel()
        apply(Verdict(onTask: 1, category: verdict?.category, stage: .exception, judgment: .on), to: snap, log: true)
    }

    func refreshPermissions() {
        axTrusted = isDemo || AX.isTrusted()
        screenRecording = ScreenReader.hasPermission
        hasAPIKey = Keychain.openRouterKey() != nil
        refreshPomoCount()
        if Date().timeIntervalSince(lastCreditCheck) >= Self.creditRecheck { checkCredit() }
    }

    // MARK: Credit

    private static let creditRecheck: TimeInterval = 30

    /// Asks OpenRouter what's left (free), and sets `outOfCredit` from it. An unanswered check changes nothing.
    func checkCredit() {
        guard !isDemo, hasAPIKey else { return }
        lastCreditCheck = Date()
        Task { [weak self] in
            guard let left = await Credit.remaining(apiKey: Keychain.openRouterKey()) else { return }
            self?.setOutOfCredit(left <= 0)
        }
    }

    /// Out: stops judging and drops the verdict, which no longer says anything. Back: rewrites the brief (it failed
    /// too) and judges the window in front.
    private func setOutOfCredit(_ out: Bool) {
        guard out != outOfCredit else { return }
        outOfCredit = out
        lastCreditCheck = Date()
        if out {
            evalTask?.cancel()
            evaluating = false
            verdict = nil
            lastError = nil
        } else if phase == .working {
            writeBrief()
            if let snap = current, !excluded { judge(snap, useCache: true) }
        }
    }

    func refreshPomoCount() {
        pomosToday = (try? store?.completedBlocks(since: Calendar.current.startOfDay(for: Date()))) ?? 0
    }

    private func observePanelSetting() {
        withObservationTracking {
            floatingPanel.setVisible(settings.showFloatingPanel, model: self)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePanelSetting() }
        }
    }

    /// The menu bar reports the icon shown or hidden. Side Eye never hides it that way itself, so a hide means macOS
    /// did: the app isn't allowed in the menu bar. Keep the floating window up so the app stays reachable, and if you
    /// just asked for the icon, say where to allow it.
    func menuBarIconVisibilityChanged(_ visible: Bool) {
        guard visible != settings.showMenuBarIcon else { return }
        guard !visible else {
            settings.showMenuBarIcon = true
            return
        }
        let justAsked = settings.menuBarIconShownAt.map { Date().timeIntervalSince($0) < 3 } ?? false
        settings.showFloatingPanel = true
        settings.showMenuBarIcon = false
        settings.menuBarIconBlocked = true
        // Not from inside SwiftUI's update of the menu bar item.
        if justAsked { DispatchQueue.main.async { MenuBarAccess.explain() } }
    }

    /// A tiny real Jev call, to check the key and connection from Settings.
    func testConnection() async -> String {
        do {
            let result = try await checkKey(nil)
            setOutOfCredit(false)
            return result
        } catch {
            if case OpenRouterError.http(402, _) = error { setOutOfCredit(true) }
            return error.localizedDescription
        }
    }

    /// One Jev call with `key` (the saved key when nil). Returns a one-line summary; throws OpenRouter's error.
    func checkKey(_ key: String?) async throws -> String {
        let judge = JevJudge(model: settings.jevModel, apiKey: { key ?? Keychain.openRouterKey() })
        let start = Date()
        let r = try await judge.judge(state: "TASK: write the quarterly report\nUSER SAID ON-TASK THIS SESSION: (none)\nNOW: Microsoft Word — Quarterly report.docx")
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return "Connected · \(r.model ?? settings.jevModel) · \(ms) ms"
    }

    func costToday() -> Double {
        (try? store?.costSince(Calendar.current.startOfDay(for: Date()))) ?? 0
    }

    /// Development: one real pass of the screenshot path on whatever window is in front after 4 s —
    /// capture → OCR → black-out → describer → Jev. Writes `sent.jpg` (exactly what the describer received) and `report.txt`.
    private func runScreenshotProbe(into dir: URL) {
        let reader = screenReader
        let describer = Describer(model: settings.describerModel, apiKey: { Keychain.openRouterKey() })
        let judge = JevJudge(model: settings.jevModel, apiKey: { Keychain.openRouterKey() })
        let task = settings.lastTask.isEmpty ? "draft the lease memo" : settings.lastTask
        Task.detached {
            try? await Task.sleep(for: .seconds(4))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var report = ["screen recording permission: \(ScreenReader.hasPermission)"]
            defer {
                try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            }
            guard let snap = await ContextWatcher.capture() else { return report.append("no frontmost window") }
            report.append("window: \(snap.descriptor)")
            let t0 = Date()
            guard let shot = await reader.read(pid: snap.pid, title: snap.windowTitle) else { return report.append("capture failed") }
            report.append("capture + OCR + black-out: \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            try? shot.jpeg.write(to: dir.appendingPathComponent("sent.jpg"))
            report.append("jpeg: \(shot.jpeg.count / 1024) KB")
            report.append("OCR text (as sent to Jev, redacted):\n" + Redactor.redact(shot.ocrText))
            var evidence = Evidence(visibleText: shot.ocrText)
            do {
                let t1 = Date()
                let d = try await describer.describe(jpeg: shot.jpeg)
                report.append("describer: provider=\(d.provider ?? "?") model=\(d.model ?? "?") \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
                report.append("description: \(d.text)")
                evidence.screenDescription = Redactor.redact(d.text)
            } catch {
                report.append("describer error: \(error.localizedDescription)")
            }
            do {
                let state = StateBuilder.build(task: task, exceptions: [], now: snap, evidence: evidence)
                let r = try await judge.judge(state: state)
                report.append("jev (task: \(task)): on_task=\(r.onTask) category=\(r.category ?? "-")")
            } catch {
                report.append("jev error: \(error.localizedDescription)")
            }
        }
    }

    /// Development: what `AX.visibleText` reads from each running app's focused window, without bringing any to the
    /// front, and whether it came from a main landmark. Writes the report to `file` and quits.
    private func runTextProbe(into file: URL) {
        Task.detached {
            var report = ["accessibility trusted: \(AX.isTrusted())"]
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let bundleID = app.bundleIdentifier, let window = AX.focusedWindow(app.processIdentifier) else { continue }
                AX.enableEnhancedTree(pid: app.processIdentifier, bundleID: bundleID)
                try? await Task.sleep(for: .milliseconds(300))
                let text = AX.visibleText(app.processIdentifier, bundleID: bundleID)
                let main = AX.mainLandmark(in: window).map { AX.collectText($0, cap: 3_000).count }
                report.append("=== \(app.localizedName ?? bundleID) — \(AX.windowTitle(app.processIdentifier))")
                report.append("main landmark: \(main.map { "\($0) chars" } ?? "none") · read \(text.count) chars")
                report.append(String(text.prefix(700)).replacingOccurrences(of: "\n", with: " | ") + "\n")
            }
            try? report.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    /// Design preview only (`--demo=idle|on|unsure|off|grace|break|credit|credit-idle|error|cycle`, `-demoTitle "…"` for the window title):
    /// fake state, no watcher, no API calls.
    /// `cycle` steps through the states every 3 s to check the panel's resizing.
    private func showDemo(_ state: String) {
        isDemo = true
        axTrusted = true  // shown as set up, so the setup card doesn't cover the state being previewed
        if state == "cycle" {
            for (i, next) in ["idle", "on", "unsure", "off", "break", "idle"].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3 * i)) { [weak self] in
                    MainActor.assumeIsolated { self?.showDemo(next) }
                }
            }
            return
        }
        task = "Draft the lease memo"
        pomosToday = 3
        graceEndsAt = nil
        outOfCredit = state.hasPrefix("credit")
        lastError = state == "error" ? "The request timed out." : nil
        if state == "idle" || state == "credit-idle" {
            phase = .idle
            return
        }
        if state == "break" {
            phase = .onBreak(until: Date().addingTimeInterval(4 * 60 + 12))
            return
        }
        phase = .working
        blockEndsAt = Date().addingTimeInterval(18 * 60 + 42)
        let off = state == "off" || state == "grace"
        if state == "grace" { graceEndsAt = Date().addingTimeInterval(settings.gracePeriod * 0.6) }
        current = ContextSnapshot(appName: off ? "Helium" : "Obsidian", bundleID: "demo", pid: 0,
                                  windowTitle: UserDefaults.standard.string(forKey: "demoTitle") ?? (off ? "Home / X" : "Lease example"),
                                  url: off ? "https://x.com/home" : nil)
        let unsure = state == "unsure"
        guard !outOfCredit, state != "error" else {
            verdict = nil
            return
        }
        verdict = Verdict(onTask: off ? 0.04 : unsure ? 0.48 : 0.73, category: nil, stage: .metadata,
                          judgment: off ? .off : unsure ? .unsure : .on)
    }

    // MARK: Clock

    private func tick() {
        let t = Date()
        let dt = min(t.timeIntervalSince(lastTick), 5)
        lastTick = t
        // "Today" rolls over at midnight even if the app's left running.
        let newDay = !Calendar.current.isDate(t, inSameDayAs: now)
        now = t
        if newDay { refreshPomoCount() }
        if !axTrusted { axTrusted = AX.isTrusted() }
        if !screenRecording { screenRecording = ScreenReader.hasPermission }
        if outOfCredit, t.timeIntervalSince(lastCreditCheck) >= Self.creditRecheck { checkCredit() }

        switch phase {
        case .idle:
            break
        case let .onBreak(until):
            if t >= until { phase = .idle }
        case .working:
            tickWorking(t, dt)
        }
    }

    private func tickWorking(_ t: Date, _ dt: TimeInterval) {
        let off = showsOffTask
        stats.add(dt, onTask: off ? false : (judgment == .on ? true : nil))
        if off, !wasShowingOffTask {
            stats.drifts += 1
            if let sessionID {
                try? store?.logAction(session: sessionID, event: currentEventID, action: "drift", cacheKey: current?.cacheKey)
            }
        }
        wasShowingOffTask = off
        if onTaskTextEnabled, judgment == .on, !evaluating, let snap = current, t.timeIntervalSince(lastOnTaskRead) >= 10 {
            lastOnTaskRead = t
            readOnTaskText(snap)
        }
        if let blockEndsAt, t >= blockEndsAt {
            endBlock(reason: "completed", next: .onBreak(until: t.addingTimeInterval(TimeInterval(settings.breakMinutes * 60))))
            refreshPomoCount()
        }
    }
}

/// A window's text as last read, for the brief (see `AppModel.onTaskText`).
private struct SeenText {
    var snap: ContextSnapshot
    var text: String
    var at: Date
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
