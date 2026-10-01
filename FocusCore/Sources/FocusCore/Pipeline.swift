import Foundation

/// On-device evidence sources the app provides. Each returns nil when unavailable or disabled.
public struct EvidenceSources: Sendable {
    /// Accessibility text of the focused window.
    public var axText: @Sendable () async -> String?
    /// Screenshot of the focused window: OCR text plus a JPEG for the describer.
    public var screenshot: @Sendable () async -> (ocrText: String, jpeg: Data)?
    /// Vision describer for a JPEG.
    public var describe: (@Sendable (Data) async throws -> Description)?

    public init(
        axText: @escaping @Sendable () async -> String?,
        screenshot: @escaping @Sendable () async -> (ocrText: String, jpeg: Data)?,
        describe: (@Sendable (Data) async throws -> Description)?
    ) {
        self.axText = axText
        self.screenshot = screenshot
        self.describe = describe
    }
}

/// One judge call made during escalation.
public struct PipelineStep: Sendable {
    public var verdict: Verdict
    public var result: JudgeResult
    public var stateDigest: String
    public var latencyMs: Int
    public var describerProvider: String?
}

/// Tiered escalation: metadata → AX text → OCR → describer. Jev is the only decider; stop at the first confident verdict,
/// except that an off from metadata alone is checked against the window's text first.
public struct Pipeline: Sendable {
    public var judge: any Judge
    public var bands: Bands
    /// Below this many characters, AX text is "thin" and OCR is tried.
    public var thinTextThreshold = 300

    public init(judge: any Judge, bands: Bands) {
        self.judge = judge
        self.bands = bands
    }

    public func run(
        task: String,
        brief: String? = nil,
        exceptions: [String],
        snapshot: ContextSnapshot,
        sources: EvidenceSources,
        onStep: @Sendable (PipelineStep) async -> Void
    ) async throws -> Verdict {
        var evidence = Evidence()
        var jpeg: Data?

        func ask(_ stage: Stage, provider: String? = nil) async throws -> Verdict {
            let state = StateBuilder.build(task: task, brief: brief, exceptions: exceptions, now: snapshot, evidence: evidence)
            let start = Date()
            let r = try await judge.judge(state: state)
            try Task.checkCancellation()
            let v = Verdict(onTask: r.onTask, category: r.category, stage: stage, judgment: bands.judge(r.onTask))
            await onStep(PipelineStep(
                verdict: v, result: r, stateDigest: StateBuilder.digest(task: task, brief: brief, exceptions: exceptions, now: snapshot, evidence: evidence),
                latencyMs: Int(Date().timeIntervalSince(start) * 1000), describerProvider: provider))
            return v
        }

        var v = try await ask(.metadata)
        if v.judgment == .on { return v }

        let text = await sources.axText()
        if v.judgment == .off {
            // A title often doesn't say what's in the window (an email, a DM, a chat with an agent), so a confident off
            // is checked once against its text, which can overturn it only with a confident on. Tested 2026-10-01 on
            // 210 windows from debug-mode sessions: a DM the user confirmed went 0.30 → 0.78; letting the text soften an
            // off to unsure also moved new-tab pages (their shortcut tiles) and a LinkedIn feed off red.
            guard let text, !text.isEmpty else { return v }
            evidence.visibleText = text
            let checked = try await ask(.text)
            return checked.judgment == .on ? checked : v
        }

        if let text, !text.isEmpty {
            evidence.visibleText = text
            v = try await ask(.text)
            if v.judgment != .unsure { return v }
        }

        let axTextCount = evidence.visibleText?.count ?? 0
        if let shot = await sources.screenshot() {
            jpeg = shot.jpeg
            if axTextCount < thinTextThreshold, shot.ocrText.count > axTextCount {
                evidence.visibleText = shot.ocrText
                v = try await ask(.ocr)
                if v.judgment != .unsure { return v }
            }
        }

        if let jpeg, let describe = sources.describe {
            let d = try await describe(jpeg)
            try Task.checkCancellation()
            evidence.screenDescription = Redactor.redact(d.text)
            v = try await ask(.describer, provider: d.provider)
        }
        return v
    }
}
