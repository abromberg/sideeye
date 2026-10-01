import Foundation

/// A task the user worked on before, with windows they confirmed for it ("I'm on task!", "Yes, on task").
/// Drifts aren't included: tested 2026-09-28, windows shown as drift under other tasks (often uncontested, sometimes
/// the very doc this task is about) led the brief to rule out whole sites like docs.google.com.
public struct PastTask: Sendable, Equatable {
    public var task: String
    public var confirmed: [String]

    public init(task: String, confirmed: [String] = []) {
        self.task = task
        self.confirmed = confirmed
    }
}

/// What the user wrote or read in a window judged on task this session: the best evidence of what the task is about
/// right now, when its name is a habit or format ("750 words") rather than a subject.
public struct OnTaskText: Sendable, Equatable {
    /// The window as a brief example (see `briefExample`).
    public var window: String
    public var text: String

    public init(window: String, text: String) {
        self.window = window
        self.text = text
    }

    /// Words in `new` that weren't in `old`, counting repeats: how much a window's text has changed since a brief
    /// last saw it. Scrolling and typing add words; reflowed or reordered text doesn't.
    public static func newWords(_ new: String, since old: String?) -> Int {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        var seen: [String: Int] = [:]
        for w in words(old ?? "") { seen[w, default: 0] += 1 }
        var added = 0
        for w in words(new) {
            if let n = seen[w], n > 0 { seen[w] = n - 1 } else { added += 1 }
        }
        return added
    }
}

extension ContextSnapshot {
    /// A confirmed window as the brief writer sees it: site and title, without the app or the app's chrome. With the
    /// app, confirming "Obsidian — Lease example" made every Obsidian note look on task.
    public func briefExample(chrome: TitleChrome = TitleChrome()) -> String? {
        let title = chrome.strip(displayTitle, bundleID: bundleID, domain: domain)
        let parts = [domain, title.isEmpty ? nil : title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

/// Turns a terse task into a short brief for the judge: what it involves and, above all, what it doesn't.
///
/// Tested 2026-09-28 on 35 hand-labeled windows (`focuseval context`): the "Not this" line did most of the work,
/// naming the user's other projects pushed their windows from ~0.5 to under 0.15. But the user names tasks loosely
/// and one window can serve several tasks, so past tasks are sorted by meaning (same / related / unrelated) and only
/// unrelated ones are ruled out. A user-written glossary sent to Jev
/// directly made it more lenient (another project's doc went 0.52 → 0.79), so nothing but the brief reaches Jev.
/// Confirmed windows widen the brief; an early prompt that took them as the definition narrowed "Northwind / monitor
/// work" to the one confirmed doc. The brief is rewritten from stored evidence each time, never edited in place, so a bad guess doesn't compound.
///
/// Model, tested 2026-10-01 on the last brief input of 9 real sessions, 3 runs each, scored on whether "Related" named
/// only past tasks that really are related and "Not this" wasn't "none": deepseek-flash without reasoning got 17/27
/// (it linked a calendar app to an unrelated project, and dropped "Not this" at random, which let a Slack channel pass
/// for a newsletter task), with low reasoning 10/27, deepseek-v4-pro 18/27, claude-haiku 23/27, gemini-3.8-flash
/// 27/27 at a median 2.2 s and about $0.0015 a brief. Cutting on-task text down to its prose (no menus or channel
/// lists) didn't help with gemini: replayed on 213 windows (`focuseval debugeval`), it let more of other projects'
/// Slack channels through. Retested 2026-10-01 with cheaper models, 4 runs each: gpt-6-luna without reasoning 36/36 at
/// $0.00012 a brief, mimo-v2.6-flash 35/36 but 5 s, glm-5.3-flash 30/36. Replayed, luna's thinner briefs let a new tab
/// and an inbox pass while gemini's counted the task's own bank and Slack windows. Asking for names in "Involves" (a
/// judge that sees one window can only match names) took luna from 4.2 to 7.5 names from the input per brief, still
/// 30/30 right. Replayed twice each (213 windows; 8 confirmed, 67 plainly another project's or a feed): luna then
/// counted 5–6 of 8 confirmed and passed 7–8 of 67, gemini 6 and 10, luna before the change 4–6 and 11–14 with one
/// run calling 91 windows on task. So luna is the default, at a twelfth of gemini's price. Telling it to leave out
/// the user's own name and interface labels didn't help either model.
public struct BriefWriter: Sendable {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    public static let defaultModel = "openai/gpt-6-luna"
    public static let briefCap = 900
    /// On-task text sent per window, and how many windows (most recent first).
    public static let onTaskTextCap = 1_000
    public static let onTaskWindows = 3
    /// New words in an on-task window before the brief is rewritten with them.
    public static let rewriteAfterNewWords = 25

    public static let prompt = """
    A focus app checks whether each window the user looks at serves the TASK they typed. The task is often terse: \
    a person, a project name, an abbreviation. Write a brief so a judge who sees one window at a time can tell this \
    task apart from the user's unrelated work.

    PAST TASKS are what the user worked on before, with windows they confirmed for each. The user names things \
    loosely, so sort each past task by meaning, not wording:
    - same: this task in other words (a nickname, an abbreviation, a person instead of their project)
    - related: shares a subject with this task: the same company, product, person or project
    - unrelated: nothing in common that the input shows
    Windows confirmed under same or related tasks show what this task can involve; a window can belong to several \
    tasks. CONFIRMED windows at the top belong to this task. Treat every confirmed window as an example that widens \
    the task, never as the whole of it.

    ON-TASK TEXT is what the user has been writing or reading this session in windows already judged on task. It \
    shows what the task is about right now, which matters most when the task names a habit or format ("750 words", \
    "journal", "inbox") rather than a subject. Put its main subjects in "Involves": the people, companies, projects \
    and questions the user is working through, not things only mentioned in passing.

    The judge sees one window at a time, often only its title and site, so it can only match names. In "Involves", \
    name the specifics rather than categories: the people, companies, products, sites, repositories, documents and \
    threads from CONFIRMED windows and ON-TASK TEXT (the bank or vendor a project uses, a colleague in a DM, a \
    document's title). A name the judge can match beats a description of the work.

    Only use names from the input; don't guess what a name means. Keep "Involves" at least as broad as the task's \
    own words. "Not this" lists only unrelated past tasks: nothing from a same or related task, and never apps, \
    sites, email or calendar in general, since the user does all their work in the same apps. When unsure whether \
    a past task is related, leave it out of "Not this".

    Reply with exactly these four lines, each under 200 characters ("Involves" under 350), no preamble:
    Related: <past tasks that are the same as or related to this one, or "none">
    Involves: <the names this task covers: subjects, people, companies, sites, documents, from confirmed windows and on-task text>
    Counts: <kinds of work that serve it>
    Not this: <unrelated past tasks, or "none">
    """

    public var prompt: String = Self.prompt
    public var model: String
    public var apiKey: @Sendable () -> String?
    public var session: URLSession
    public var record: CallRecorder?

    public init(model: String = Self.defaultModel, session: URLSession = .shared, record: CallRecorder? = nil,
                apiKey: @escaping @Sendable () -> String?) {
        self.model = model
        self.session = session
        self.record = record
        self.apiKey = apiKey
    }

    public func write(task: String, past: [PastTask], confirmedNow: [String] = [], onTaskText: [OnTaskText] = []) async throws -> String {
        try await write(input: Self.input(task: task, past: past, confirmedNow: confirmedNow, onTaskText: onTaskText))
    }

    /// Writes a brief from an input already built by `input(task:past:confirmedNow:onTaskText:)`.
    public func write(input: String) async throws -> String {
        let data = try await OpenRouter.post(Self.endpoint, body: Self.requestBody(model: model, prompt: prompt, input: input), timeout: 25,
                                             apiKey: apiKey(), session: session, kind: "brief", model: model, record: record)
        return String(try Describer.parse(data).text.prefix(Self.briefCap))
    }

    /// `onTaskText` most recent first; only the first `onTaskWindows` are sent.
    public static func input(task: String, past: [PastTask], confirmedNow: [String], onTaskText: [OnTaskText] = []) -> String {
        var lines = ["TASK: \(task)", "CONFIRMED: " + (confirmedNow.isEmpty ? "(none)" : confirmedNow.joined(separator: "; "))]
        let text = onTaskText.prefix(onTaskWindows).filter { !$0.text.isEmpty }
        if !text.isEmpty {
            lines += ["", "ON-TASK TEXT (most recent first):"]
            for t in text {
                lines.append("[\(t.window)]")
                lines.append(String(t.text.prefix(onTaskTextCap)).replacingOccurrences(of: #"\s*\n\s*"#, with: " / ", options: .regularExpression))
            }
        }
        lines += ["", "PAST TASKS (most recent first):"]
        if past.isEmpty { lines.append("(none)") }
        for p in past {
            lines.append("- \(p.task)")
            if !p.confirmed.isEmpty { lines.append("    CONFIRMED: " + p.confirmed.joined(separator: "; ")) }
        }
        return Redactor.redact(lines.joined(separator: "\n"))
    }

    /// None, except for models that reject it: Gemini 3.x Flash answers every request without reasoning with an error.
    public static func reasoningEffort(_ model: String) -> String {
        model.hasPrefix("google/gemini") ? "low" : "none"
    }

    public static func requestBody(model: String, prompt: String = Self.prompt, input: String) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            // Room for reasoning tokens where a model insists on them; the brief itself is four short lines.
            "max_tokens": 3_000,
            "reasoning": ["effort": reasoningEffort(model)],
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": input],
            ],
            "provider": ["zdr": true],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
