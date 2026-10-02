import Foundation
import Testing
@testable import FocusCore

@Suite struct SnapshotTests {
    @Test func domainAndKey() {
        let s = ContextSnapshot(appName: "Google Chrome", bundleID: "com.google.Chrome", pid: 1,
                                windowTitle: "(3) Home / X", url: "https://www.x.com/home")
        #expect(s.domain == "x.com")
        #expect(s.cacheKey == "com.google.Chrome|x.com|home / x")
        #expect(s.descriptor == "Google Chrome — https://www.x.com/home — (3) Home / X")
    }

    @Test func unreadCountsShareKey() {
        #expect(ContextSnapshot.normalizeTitle("Inbox (3) - Gmail") == ContextSnapshot.normalizeTitle("Inbox (12) - Gmail"))
        #expect(ContextSnapshot.normalizeTitle("● main.swift") == "main.swift")
        #expect(ContextSnapshot.normalizeTitle("✳ Focus app plan") == ContextSnapshot.normalizeTitle("◑ Focus app plan"))
        #expect(ContextSnapshot.normalizeTitle("⠋ Focus app plan") == "focus app plan")
    }

    @Test func statusLabelShowsCleanTitle() {
        func label(_ app: String, _ title: String, _ url: String? = nil) -> String {
            ContextSnapshot(appName: app, bundleID: "x", pid: 1, windowTitle: title, url: url).statusLabel
        }
        #expect(label("Ghostty", "✳ Claude Code") == "Ghostty · Claude Code")
        #expect(label("Helium", "Northwind setup - Google Docs - High memory usage - 817 MB - Helium",
                      "https://docs.google.com/document/d/1") == "docs.google.com · Northwind setup - Google Docs")
        #expect(label("Helium", "Side Eye — blink preview - Helium") == "Helium · Side Eye — blink preview")
        #expect(label("Finder", "") == "Finder")
    }
}

@Suite struct RedactorTests {
    @Test func redactsEmailCardKey() {
        let s = Redactor.redact("mail jane@example.com card 4111 1111 1111 1111 key sk-or-v1-abcdefghijklmnop1234")
        #expect(s == "mail [email] card [card] key [key]")
    }

    @Test func leavesNonLuhnNumbers() {
        #expect(Redactor.redact("order 1234567890123") == "order 1234567890123")
    }

    @Test func redactsSSN() {
        #expect(Redactor.redact("SSN 123-45-6789 on file") == "SSN [ssn] on file")
        #expect(Redactor.redact("ssn 123 45 6789") == "ssn [ssn]")
    }

    @Test func redactsPhones() {
        #expect(Redactor.redact("call (415) 555-1234 today") == "call [phone] today")
        #expect(Redactor.redact("call 415-555-1234") == "call [phone]")
        #expect(Redactor.redact("call 415.555.1234.") == "call [phone].")
        #expect(Redactor.redact("call 1-415-555-1234") == "call [phone]")
        #expect(Redactor.redact("call +1 415 555 1234") == "call [phone]")
        #expect(Redactor.redact("UK +44 20 7946 0958") == "UK [phone]")
    }

    @Test func leavesNonPhoneNumbers() {
        // Dates, times, versions, bare IDs, prices.
        for s in ["2026-09-27", "15:08:37", "v1.13.7", "order 4155551234", "$1,234.56", "Obsidian 1.13.7", "(3) Home"] {
            #expect(Redactor.redact(s) == s)
        }
    }

    @Test func cardWinsOverPhone() {
        #expect(Redactor.redact("4111-1111-1111-1111") == "[card]")
    }

    @Test func findsRanges() {
        let text = "a@b.co and 415-555-1234"
        let found = Redactor.find(in: text)
        #expect(found.map(\.kind) == [.email, .phone])
        #expect(String(text[found[1].range]) == "415-555-1234")
    }
}

@Suite struct StateTests {
    let snap = ContextSnapshot(appName: "Safari", bundleID: "com.apple.Safari", pid: 1, windowTitle: "X", url: "https://x.com")

    @Test func literalTaskAndSections() {
        let s = StateBuilder.build(
            task: "write the lease memo", exceptions: ["Slack #deal"], now: snap,
            evidence: Evidence(visibleText: "hello bob@x.io\nsecond line"))
        #expect(s == """
        TASK: write the lease memo
        USER SAID ON-TASK THIS SESSION: Slack #deal
        NOW: Safari — https://x.com — X
        VISIBLE TEXT: hello [email]
        second line
        """)
        let digest = StateBuilder.digest(task: "write the lease memo", exceptions: [], now: snap,
                                         evidence: Evidence(visibleText: "hello bob@x.io\nsecond line"))
        #expect(digest.hasSuffix("VISIBLE TEXT: <26 chars>"))
        #expect(!digest.contains("second line"))
    }

    @Test func noExceptions() {
        let s = StateBuilder.build(task: "t", exceptions: [], now: snap, evidence: Evidence())
        #expect(s.contains("USER SAID ON-TASK THIS SESSION: (none)"))
        #expect(!s.contains("VISIBLE TEXT"))
    }
}

@Suite struct JevTests {
    @Test func requestShape() throws {
        let data = try JevJudge.requestBody(model: "jev-latest", state: "S")
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["model"] as? String == "jev-latest")
        #expect((obj["provider"] as? [String: Any])?["zdr"] as? Bool == true)
        let q = try #require(obj["questions"] as? [String: [String: Any]])
        #expect(q["on_task"]?["type"] as? String == "noul")
        #expect(q["category"]?["type"] as? String == "choice")
        #expect((q["category"]?["criteria"] as? [String: String])?["social media"] != nil)
    }

    @Test func parseResponse() throws {
        let json = """
        {"id":"gen-dec-1","model":"typesafe/jev-1.13-20260917","provider":"TypeSafe",
         "answers":{"on_task":{"type":"noul","noul":0.12},"category":{"type":"choice","choice":"social media"}},
         "usage":{"input_tokens":275,"output_tokens":20,"cost":0.00003}}
        """
        let r = try JevJudge.parse(Data(json.utf8))
        #expect(r.onTask == 0.12)
        #expect(r.category == "social media")
        #expect(r.cost == 0.00003)
    }

    @Test func parseMissing() {
        #expect(throws: OpenRouterError.self) { try JevJudge.parse(Data(#"{"answers":{}}"#.utf8)) }
    }
}

@Suite struct DescriberTests {
    @Test func zdrForced() throws {
        let obj = try #require(JSONSerialization.jsonObject(with: Describer.requestBody(model: "~deepseek/deepseek-flash-latest", jpeg: Data([1, 2]))) as? [String: Any])
        let provider = try #require(obj["provider"] as? [String: Any])
        #expect(provider["zdr"] as? Bool == true)
        #expect(provider["sort"] as? String == "price")
        #expect((obj["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        #expect(!(obj["model"] as! String).contains(":floor"))
    }

    @Test func parse() throws {
        let d = try Describer.parse(Data(#"{"provider":"Wafer","model":"deepseek/deepseek-v4.1-flash","choices":[{"message":{"content":" Watching a YouTube video. "}}]}"#.utf8))
        #expect(d.text == "Watching a YouTube video.")
        #expect(d.provider == "Wafer")
    }
}

@Suite struct CreditTests {
    @Test func keyLimit() {
        #expect(Credit.keyRemaining(Data(#"{"data":{"limit":50,"limit_remaining":48.34,"usage":1.66}}"#.utf8)) == 48.34)
        #expect(Credit.keyRemaining(Data(#"{"data":{"limit":null,"limit_remaining":null,"usage":1.66}}"#.utf8)) == nil)
    }

    @Test func accountBalance() {
        #expect(Credit.accountRemaining(Data(#"{"data":{"total_credits":10,"total_usage":10.25}}"#.utf8)) == -0.25)
        #expect(Credit.accountRemaining(Data(#"{"error":{"code":403,"message":"Only management keys"}}"#.utf8)) == nil)
    }
}

@Suite struct StatsTests {
    @Test func summaryFormat() {
        var s = BlockStats()
        s.add(20 * 60, onTask: true)
        s.add(4 * 60, onTask: false)
        s.add(90, onTask: nil)
        s.drifts = 9
        #expect(s.summary == "On task: 20 min. Off task: 4 min. 9 drifts.")
    }

    @Test func singularDrift() {
        var s = BlockStats()
        s.drifts = 1
        #expect(s.summary == "On task: 0 min. Off task: 0 min. 1 drift.")
    }
}

@Suite struct PipelineTests {
    struct ScriptedJudge: Judge {
        let answers: [Double]
        let calls = Counter()
        func judge(state: String) async throws -> JudgeResult {
            let i = await calls.next()
            return JudgeResult(onTask: answers[min(i, answers.count - 1)], category: nil)
        }
    }

    actor Counter {
        var n = 0
        func next() -> Int { defer { n += 1 }; return n }
    }

    let snap = ContextSnapshot(appName: "Figma", bundleID: "com.figma.Desktop", pid: 1, windowTitle: "Untitled", url: nil)

    func sources(ax: String?, ocr: String?, describe: Bool) -> EvidenceSources {
        EvidenceSources(
            axText: { ax },
            screenshot: { ocr.map { ($0, Data([0xFF])) } },
            describe: describe ? { @Sendable _ in Description(text: "Designing a login screen", provider: "Wafer", model: nil) } : nil)
    }

    @Test func stopsAtConfidentMetadata() async throws {
        let judge = ScriptedJudge(answers: [0.9])
        let v = try await Pipeline(judge: judge, bands: Bands()).run(
            task: "t", exceptions: [], snapshot: snap, sources: sources(ax: "x", ocr: "y", describe: true), onStep: { _ in })
        #expect(v.stage == .metadata)
        #expect(await judge.calls.n == 1)
    }

    @Test func escalatesThroughAllStages() async throws {
        let judge = ScriptedJudge(answers: [0.5, 0.5, 0.5, 0.1])
        let v = try await Pipeline(judge: judge, bands: Bands()).run(
            task: "t", exceptions: [], snapshot: snap,
            sources: sources(ax: "short", ocr: "much longer OCR text here", describe: true), onStep: { _ in })
        #expect(v.stage == .describer)
        #expect(v.judgment == .off)
        #expect(await judge.calls.n == 4)
    }

    @Test func confidentOffIsOverturnedOnlyByConfidentOnText() async throws {
        let rescued = ScriptedJudge(answers: [0.2, 0.8])
        let v = try await Pipeline(judge: rescued, bands: Bands()).run(
            task: "t", exceptions: [], snapshot: snap, sources: sources(ax: "x", ocr: "y", describe: true), onStep: { _ in })
        #expect(v.stage == .text && v.judgment == .on)

        // Text that only makes it unsure leaves the off standing, and nothing past the text is tried.
        let softened = ScriptedJudge(answers: [0.2, 0.5])
        let w = try await Pipeline(judge: softened, bands: Bands()).run(
            task: "t", exceptions: [], snapshot: snap, sources: sources(ax: "x", ocr: "y", describe: true), onStep: { _ in })
        #expect(w.stage == .metadata && w.judgment == .off)
        #expect(await softened.calls.n == 2)

        // No text: the off stands without a second call.
        let bare = ScriptedJudge(answers: [0.2])
        _ = try await Pipeline(judge: bare, bands: Bands()).run(
            task: "t", exceptions: [], snapshot: snap, sources: sources(ax: nil, ocr: "y", describe: true), onStep: { _ in })
        #expect(await bare.calls.n == 1)
    }

    @Test func skipsOCRWhenAXTextIsRich() async throws {
        let judge = ScriptedJudge(answers: [0.5, 0.5, 0.8])
        let rich = String(repeating: "a", count: 400)
        let v = try await Pipeline(judge: judge, bands: Bands()).run(
            task: "t", exceptions: [], snapshot: snap,
            sources: sources(ax: rich, ocr: "ocr", describe: true), onStep: { _ in })
        #expect(v.stage == .describer)
        #expect(await judge.calls.n == 3)
    }
}

@Suite struct ReviewTests {
    @Test func oneRowPerWindowWithLastRealVerdict() throws {
        let store = try Store(inMemory: ())
        let t0 = Date()
        let session = try store.startSession(task: "lease memo", pomodoroMinutes: 25, at: t0)
        let x = ContextSnapshot(appName: "Safari", bundleID: "s", pid: 1, windowTitle: "Home / X", url: "https://x.com/home", at: t0)
        let docs = ContextSnapshot(appName: "Word", bundleID: "w", pid: 2, windowTitle: "Lease.docx", url: nil,
                                   at: t0.addingTimeInterval(30))
        let e1 = try store.logContext(session: session, snapshot: x, trigger: "start")
        try store.logVerdict(event: e1, verdict: Verdict(onTask: 0.04, category: nil, stage: .metadata, judgment: .off),
                             model: nil, cost: nil, latencyMs: 1, stateDigest: nil)
        let e2 = try store.logContext(session: session, snapshot: docs, trigger: "activation")
        try store.logVerdict(event: e2, verdict: Verdict(onTask: 0.5, category: nil, stage: .metadata, judgment: .unsure),
                             model: nil, cost: nil, latencyMs: 1, stateDigest: nil)
        try store.logVerdict(event: e2, verdict: Verdict(onTask: 0.9, category: nil, stage: .text, judgment: .on),
                             model: nil, cost: nil, latencyMs: 1, stateDigest: nil)
        var x2 = x
        x2.at = t0.addingTimeInterval(200)
        let e3 = try store.logContext(session: session, snapshot: x2, trigger: "activation")  // back to X: cache hit
        try store.logVerdict(event: e3, verdict: Verdict(onTask: 0.04, category: nil, stage: .cache, judgment: .off),
                             model: nil, cost: nil, latencyMs: 0, stateDigest: nil)
        try store.endSession(session, reason: "completed", summary: nil, at: t0.addingTimeInterval(260))

        let items = try store.reviewItems(since: t0.addingTimeInterval(-1))
        #expect(items.count == 2)
        let word = try #require(items.first { $0.cacheKey == docs.cacheKey })
        #expect(word.onTask == 0.9)  // the final escalated verdict, not the unsure first pass
        #expect(word.seconds == 170)
        let xItem = try #require(items.first { $0.cacheKey == x.cacheKey })
        #expect(xItem.seconds == 90)  // 30 s first visit + 60 s second
        #expect(items.first?.cacheKey == docs.cacheKey)  // longest first

        try store.saveLabel(word, label: "on")
        try store.saveLabel(word, label: "on")  // relabel replaces, doesn't duplicate
        #expect(try store.labels().count == 1)
        #expect(try store.reviewItems(since: t0.addingTimeInterval(-1)).first { $0.cacheKey == docs.cacheKey }?.label == "on")
    }
}

@Suite struct BriefTests {
    let snap = ContextSnapshot(appName: "Safari", bundleID: "com.apple.Safari", pid: 1, windowTitle: "X", url: "https://x.com")

    @Test func briefGoesOnItsOwnLineAfterTheTask() {
        let s = StateBuilder.build(task: "Contoso", brief: "Involves: Contoso\nNot this: lease", exceptions: [], now: snap, evidence: Evidence())
        #expect(s.hasPrefix("TASK: Contoso\nTASK CONTEXT:\nInvolves: Contoso\nNot this: lease\nUSER SAID ON-TASK"))
        #expect(!StateBuilder.build(task: "t", brief: " ", exceptions: [], now: snap, evidence: Evidence()).contains("TASK CONTEXT"))
    }

    @Test func examplesLeaveOutTheApp() {
        let obsidian = ContextSnapshot(appName: "Obsidian", bundleID: "md.obsidian", pid: 1, windowTitle: "Lease example - Obsidian 1.13.7", url: nil)
        #expect(obsidian.briefExample() == "Lease example")
        let web = ContextSnapshot(appName: "Helium", bundleID: "h", pid: 1, windowTitle: "Northwind setup - Google Docs - Helium",
                                  url: "https://docs.google.com/d/1")
        #expect(web.briefExample() == "docs.google.com — Northwind setup - Google Docs")
    }

    @Test func examplesLeaveOutWhatTheAppRepeatsInEveryTitle() {
        func note(_ t: String) -> ContextSnapshot {
            ContextSnapshot(appName: "Obsidian", bundleID: "md.obsidian", pid: 1, windowTitle: "\(t) - Personal - Obsidian 1.13.7", url: nil)
        }
        func slack(_ t: String) -> ContextSnapshot {
            ContextSnapshot(appName: "Slack", bundleID: "slack", pid: 1, windowTitle: "\(t) - Slack", url: nil)
        }
        let notes = ["Lease example", "Garden plan", "Someday Maybe", "Untitled 35"].map(note)
        let chats = ["core (Channel) - Acme - 3 new items", "Sam (DM) - Acme - 1 new item", "general (Channel) - Globex - 2 new items",
                     "research (Channel) - Acme - 3 new items"].map(slack)
        let chrome = TitleChrome(windows: (notes + chats).map { ($0.bundleID, $0.domain, $0.displayTitle) })
        #expect(notes[0].briefExample(chrome: chrome) == "Lease example")
        // Segments in most but not ~all titles (the Acme workspace, 3 of 4) are kept: they still tell windows apart.
        #expect(chats[0].briefExample(chrome: chrome) == "core (Channel) - Acme")
        // Too few titles to tell what's chrome: nothing is stripped.
        let few = TitleChrome(windows: notes.prefix(3).map { ($0.bundleID, $0.domain, $0.displayTitle) })
        #expect(notes[0].briefExample(chrome: few) == "Lease example - Personal")
    }

    @Test func inputListsOtherTasksAndConfirmations() {
        let input = BriefWriter.input(task: "Northwind", past: [PastTask(task: "Contoso", confirmed: ["Contoso doc"]), PastTask(task: "lease")],
                                      confirmedNow: ["bob@x.io thread"])
        #expect(input == """
        TASK: Northwind
        CONFIRMED: [email] thread

        PAST TASKS (most recent first):
        - Contoso
            CONFIRMED: Contoso doc
        - lease
        """)
    }

    @Test func inputCarriesOnTaskTextMostRecentFirst() {
        let text = (1...4).map { OnTaskText(window: "w\($0)", text: "line one\n\nline \($0)") }
        let input = BriefWriter.input(task: "750 words", past: [], confirmedNow: [], onTaskText: text)
        #expect(input == """
        TASK: 750 words
        CONFIRMED: (none)

        ON-TASK TEXT (most recent first):
        [w1]
        line one / line 1
        [w2]
        line one / line 2
        [w3]
        line one / line 3

        PAST TASKS (most recent first):
        (none)
        """)
    }

    @Test func newWordsCountsWhatWasAdded() {
        #expect(OnTaskText.newWords("Thinking about Northwind", since: nil) == 3)
        #expect(OnTaskText.newWords("the the cat", since: "the cat") == 1)
        // Reflowed or reordered text adds nothing; removed text doesn't count.
        #expect(OnTaskText.newWords("cat the\nmat", since: "the cat mat dog") == 0)
    }

    @Test func pastTasksCarryConfirmationsNotDrifts() throws {
        let store = try Store(inMemory: ())
        let old = try store.startSession(task: "Contoso project", pomodoroMinutes: nil, at: Date(timeIntervalSince1970: 0))
        let doc = ContextSnapshot(appName: "Helium", bundleID: "h", pid: 1, windowTitle: "Contoso architecture - Helium", url: "https://docs.google.com/x")
        let feed = ContextSnapshot(appName: "Helium", bundleID: "h", pid: 1, windowTitle: "Feed | LinkedIn - Helium", url: "https://linkedin.com/feed")
        let e1 = try store.logContext(session: old, snapshot: doc, trigger: "t")
        try store.logAction(session: old, event: e1, action: "for_task", cacheKey: doc.cacheKey)
        let e2 = try store.logContext(session: old, snapshot: feed, trigger: "t")
        try store.logAction(session: old, event: e2, action: "drift", cacheKey: feed.cacheKey)
        let now = try store.startSession(task: "Northwind", pomodoroMinutes: nil, at: Date(timeIntervalSince1970: 100))

        let past = try store.pastTasks(excludingSession: now)
        #expect(past == [PastTask(task: "Contoso project", confirmed: ["docs.google.com — Contoso architecture"])])
    }

    /// Switching task mid-block ends one session row and opens another: the finished task is a past task for the
    /// next one, and the pomodoro counts once.
    @Test func taskSwitchSplitsTheBlock() throws {
        let store = try Store(inMemory: ())
        let first = try store.startSession(task: "Contoso", pomodoroMinutes: 25, at: Date(timeIntervalSince1970: 0))
        let doc = ContextSnapshot(appName: "Helium", bundleID: "h", pid: 1, windowTitle: "Contoso spec - Helium", url: "https://docs.google.com/x")
        let e = try store.logContext(session: first, snapshot: doc, trigger: "t")
        try store.logAction(session: first, event: e, action: "for_task", cacheKey: doc.cacheKey)
        try store.endSession(first, reason: "switched", summary: nil, at: Date(timeIntervalSince1970: 600))
        let second = try store.startSession(task: "Northwind", pomodoroMinutes: 25, at: Date(timeIntervalSince1970: 600))
        try store.endSession(second, reason: "completed", summary: nil, at: Date(timeIntervalSince1970: 1500))

        #expect(try store.pastTasks(excludingSession: second) == [PastTask(task: "Contoso", confirmed: ["docs.google.com — Contoso spec"])])
        #expect(try store.completedBlocks(since: .distantPast) == 1)
    }
}

@Suite struct BriefLogTests {
    @Test func briefsReadBackFromDigests() throws {
        let store = try Store(inMemory: ())
        let s = try store.startSession(task: "Contoso", pomodoroMinutes: nil)
        let snap = ContextSnapshot(appName: "Safari", bundleID: "s", pid: 1, windowTitle: "X", url: nil)
        let e = try store.logContext(session: s, snapshot: snap, trigger: "t")
        for brief in ["Involves: Contoso", "Involves: Contoso", "Involves: Contoso docs\nNot this: lease"] {
            let digest = StateBuilder.digest(task: "Contoso", brief: brief, exceptions: [], now: snap, evidence: Evidence())
            try store.logVerdict(event: e, verdict: Verdict(onTask: 0.9, category: nil, stage: .metadata, judgment: .on),
                                 model: nil, cost: nil, latencyMs: nil, stateDigest: digest)
        }
        #expect(try store.briefs(task: "Contoso", since: .distantPast) == ["Involves: Contoso", "Involves: Contoso docs\nNot this: lease"])
    }
}

@Suite struct ModelCallTests {
    @Test func recordsEveryCallWithTheScreenshotOutOfTheRequest() async throws {
        let store = try Store(inMemory: ())
        let session = try store.startSession(task: "t", pomodoroMinutes: nil)
        let body = try Describer.requestBody(model: "m", jpeg: Data(repeating: 7, count: 300))
        let recorded = Recorded()
        // No key: nothing is sent, and nothing recorded.
        await #expect(throws: OpenRouterError.missingKey) {
            _ = try await OpenRouter.post(URL(string: "https://invalid.invalid")!, body: body, timeout: 1, apiKey: nil,
                                          session: .shared, kind: "describe", model: "m", record: { recorded.calls.append($0) })
        }
        #expect(recorded.calls.isEmpty)
        // A failed call is recorded with its error, the image kept apart from the request.
        await #expect(throws: (any Error).self) {
            _ = try await OpenRouter.post(URL(string: "https://invalid.invalid")!, body: body, timeout: 1, apiKey: "k",
                                          session: .shared, kind: "describe", model: "m", image: Data([1]),
                                          record: { recorded.calls.append($0) })
        }
        let call = try #require(recorded.calls.first)
        #expect(call.error != nil && call.image == Data([1]))
        #expect(call.request.contains("<jpeg in image>") && !call.request.contains("base64"))
        try store.logModelCall(session: session, event: nil, call: call)
        let count = try await store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM modelCall WHERE kind = 'describe'") }
        #expect(count == 1)
    }
}

private final class Recorded: @unchecked Sendable {
    var calls: [ModelCall] = []
}
