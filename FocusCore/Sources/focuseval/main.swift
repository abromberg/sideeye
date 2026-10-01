import FocusCore
import Foundation
import GRDB

// Offline tuning tool.
//   focuseval judge "<task>" "<app — url — title>" [visible text] [--brief-file path]
//   focuseval review [--day YYYY-MM-DD] [--relabel] [--db path]   # label a day's windows, score the presets
//   focuseval replay [--on 0.6] [--off 0.35] [--db path]
//   focuseval brief "<task>" [--confirmed "a; b"] [--text-window w --text-file f] [--model m] [--db path]   # the brief Start would write
//   focuseval chrome [--db path]                   # title segments each app repeats, stripped from brief examples
//   focuseval context <labels.tsv> [--past fixture.tsv] [--db path]   # does a task brief help? (see ContextEval.swift)
//   focuseval debugeval [--since YYYY-MM-DD] [--db path]   # replay debug-mode windows under variants (DebugEval.swift)
//   focuseval debug [--session N] [--db path]      # a session's windows, text and model calls kept by debug logging
// Needs OPENROUTER_API_KEY for judge.

let args = Array(CommandLine.arguments.dropFirst())
let judge = JevJudge(model: ProcessInfo.processInfo.environment["JEV_MODEL"] ?? "jev-latest") {
    ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Builds the same state the app sends for a metadata-only call, from a "app — url — title" descriptor.
func state(task: String, descriptor: String, text: String? = nil, brief: String? = nil) -> String {
    StateBuilder.build(task: task, brief: brief, exceptions: [], now: snapshot(descriptor), evidence: Evidence(visibleText: text))
}

/// "App — https://… — title" or "App — title"; titles may contain " — " themselves.
func snapshot(_ descriptor: String) -> ContextSnapshot {
    var parts = descriptor.components(separatedBy: " — ")
    let app = parts.removeFirst()
    let url = parts.first.flatMap { $0.hasPrefix("http") ? parts.removeFirst() : nil }
    return ContextSnapshot(appName: app, bundleID: app, pid: 0, windowTitle: parts.joined(separator: " — "), url: url)
}

switch args.first {
case "judge":
    guard args.count >= 3 else { fail("usage: focuseval judge <task> <app — url — title> [visible text]") }
    let brief = try option("--brief-file").map { try String(contentsOfFile: $0, encoding: .utf8) }
    let rest = args.dropFirst(3).filter { $0 != "--brief-file" && $0 != option("--brief-file") }
    let s = state(task: args[1], descriptor: args[2], text: rest.first, brief: brief)
    print(s, "\n")
    let r = try await judge.judge(state: s)
    print(String(format: "on_task=%.3f  category=%@  model=%@  cost=$%.6f",
                 r.onTask, r.category ?? "-", r.model ?? "-", r.cost ?? 0))

case "review":
    // Walk through today's contexts (longest-viewed first), label each on/off, then score the strictness presets.
    let store = try Store(url: URL(fileURLWithPath: option("--db") ?? Store.defaultURL.path))
    var since = Calendar.current.startOfDay(for: Date())
    if let day = option("--day") {
        guard let d = ISO8601DateFormatter.dateOnly.date(from: day) else { fail("--day wants YYYY-MM-DD") }
        since = d
    }
    let pending = try store.reviewItems(since: since).filter { $0.label == nil || args.contains("--relabel") }
    if pending.isEmpty {
        print("Nothing new to label since \(ISO8601DateFormatter.dateOnly.string(from: since)).")
    } else {
        print("\(pending.count) windows to label, longest-viewed first. For each: o = on task, f = off task, s = skip, q = stop.")
        var lastTask: String?
        loop: for (n, item) in pending.enumerated() {
            if item.task != lastTask {
                print("\nTask: \(item.task)")
                for brief in try store.briefs(task: item.task, since: since) {
                    print("  Brief:\n    " + brief.replacingOccurrences(of: "\n", with: "\n    "))
                }
                lastTask = item.task
            }
            let minutes = item.seconds >= 60 ? "\(item.seconds / 60) min" : "\(item.seconds) s"
            print(String(format: "\n[%d/%d] %@\n        %@ there · Jev %.2f (%@ at Balanced)",
                         n + 1, pending.count, item.descriptor, minutes, item.onTask, Bands.balanced.judge(item.onTask).rawValue))
            while true {
                print("        on or off? [o/f/s/q] ", terminator: "")
                switch readLine()?.lowercased().trimmingCharacters(in: .whitespaces) {
                case "o": try store.saveLabel(item, label: "on")
                case "f": try store.saveLabel(item, label: "off")
                case "s", "": break
                case "q", nil: break loop
                default: continue
                }
                break
            }
        }
    }
    scoreLabels(try store.labels())

case "replay":
    let path = option("--db") ?? Store.defaultURL.path
    let bands = Bands(on: Double(option("--on") ?? "") ?? Bands().on, off: Double(option("--off") ?? "") ?? Bands().off)
    let db = try DatabaseQueue(path: path)
    // Final model verdict per context event, and whether the user said "it's for the task" on it.
    let rows = try db.read { db in
        try Row.fetchAll(db, sql: """
            SELECT e.id, e.appName, e.domain, e.windowTitle, v.onTask, v.stage,
                   EXISTS(SELECT 1 FROM userAction a WHERE a.contextEventId = e.id AND a.action = 'for_task') AS forTask
            FROM contextEvent e
            JOIN verdict v ON v.id = (SELECT MAX(id) FROM verdict WHERE contextEventId = e.id AND stage NOT IN ('cache', 'exception'))
            ORDER BY e.id
            """)
    }
    var counts: [Judgment: Int] = [:]
    var falseAlarms: [String] = []
    for row in rows {
        let p: Double = row["onTask"]
        let j = bands.judge(p)
        counts[j, default: 0] += 1
        if j == .off, (row["forTask"] as Int64?) == 1 {
            falseAlarms.append(String(format: "%.3f  %@ — %@", p, (row["domain"] as String?) ?? (row["appName"] as String), row["windowTitle"] as String))
        }
    }
    print("\(rows.count) judged contexts at bands \(bands.on)/\(bands.off): on \(counts[.on] ?? 0), off \(counts[.off] ?? 0), unsure \(counts[.unsure] ?? 0)")
    print("Off-task verdicts you corrected with \"It's for the task\": \(falseAlarms.count)")
    falseAlarms.forEach { print("  " + $0) }

case "brief":
    guard args.count >= 2 else { fail("usage: focuseval brief <task> [--confirmed \"a; b\"] [--model m] [--db path]") }
    let store = try Store(url: URL(fileURLWithPath: option("--db") ?? Store.defaultURL.path))
    let past = try store.pastTasks()
    let confirmed = option("--confirmed")?.components(separatedBy: "; ") ?? []
    var onTask: [OnTaskText] = []
    if let window = option("--text-window"), let file = option("--text-file") {
        onTask = [OnTaskText(window: window, text: try String(contentsOfFile: file, encoding: .utf8))]
    }
    print(BriefWriter.input(task: args[1], past: past, confirmedNow: confirmed, onTaskText: onTask), "\n")
    let writer = BriefWriter(model: option("--model") ?? BriefWriter.defaultModel) {
        ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
    }
    print(try await writer.write(task: args[1], past: past, confirmedNow: confirmed, onTaskText: onTask))

case "chrome":
    // What each app repeats in every title, as stripped from brief examples.
    let store = try Store(url: URL(fileURLWithPath: option("--db") ?? Store.defaultURL.path))
    for (app, segs) in try store.titleChrome().chrome.sorted(by: { $0.key < $1.key }) {
        print(app.padding(toLength: 45, withPad: " ", startingAt: 0), segs.sorted().joined(separator: " · "))
    }

case "debug":
    // A session (the latest by default) as it happened: each window switch with the text read there and its verdicts,
    // and every model call — brief rewrites included — with what was sent and what came back.
    let store = try Store(url: URL(fileURLWithPath: option("--db") ?? Store.defaultURL.path))
    try store.db.read { db in
        guard let session = try Int64.fetchOne(db, sql: "SELECT id FROM session WHERE id = COALESCE(?, (SELECT MAX(id) FROM session))",
                                               arguments: [option("--session").flatMap { Int64($0) }]),
              let task = try String.fetchOne(db, sql: "SELECT task FROM session WHERE id = ?", arguments: [session])
        else { fail("no such session") }
        print("Session \(session): \(task)")
        let events = try Row.fetchAll(db, sql: "SELECT * FROM contextEvent WHERE sessionId = ? ORDER BY id", arguments: [session])
        let calls = try Row.fetchAll(db, sql: "SELECT * FROM modelCall WHERE sessionId = ? ORDER BY id", arguments: [session])
        let timeline = (events.map { ($0["at"] as Date, $0) } + calls.filter { ($0["contextEventId"] as Int64?) == nil }.map { ($0["at"] as Date, $0) })
            .sorted { $0.0 < $1.0 }
        for (at, row) in timeline {
            let time = at.formatted(date: .omitted, time: .standard)
            guard row.hasColumn("trigger") else {
                printCall(row, time: time, indent: "")
                continue
            }
            let id: Int64 = row["id"]
            print("\n#\(id)  \(time)  \(row["trigger"] as String)  "
                  + [row["appName"], row["domain"], row["windowTitle"]].compactMap { $0 as String? }.joined(separator: " — "))
            if let text: String = row["debugText"] { print(indented("TEXT AT SWITCH (\(text.count) chars): " + text, "  ")) }
            for v in try Row.fetchAll(db, sql: "SELECT stage, onTask, judgment FROM verdict WHERE contextEventId = ? ORDER BY id", arguments: [id]) {
                print(String(format: "  verdict  %@ %.2f %@", v["stage"] as String, v["onTask"] as Double, v["judgment"] as String))
            }
            for call in calls where (call["contextEventId"] as Int64?) == id { printCall(call, time: nil, indent: "  ") }
        }
    }

case "debugeval":
    let store = try Store(url: URL(fileURLWithPath: option("--db") ?? Store.defaultURL.path))
    guard let since = ISO8601DateFormatter.dateOnly.date(from: option("--since") ?? "2026-09-30") else { fail("--since wants YYYY-MM-DD") }
    var writer = BriefWriter(model: ProcessInfo.processInfo.environment["BRIEF_MODEL"] ?? BriefWriter.defaultModel) {
        ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
    }
    if let file = ProcessInfo.processInfo.environment["BRIEF_PROMPT_FILE"] { writer.prompt = try String(contentsOfFile: file, encoding: .utf8) }
    try await debugEval(store: store, since: since, judge: judge, writer: writer)

case "context":
    guard args.count >= 2 else { fail("usage: focuseval context <labels.tsv> [--db path]") }
    try await compareContexts(labelsPath: args[1])

default:
    fail("usage: focuseval judge|review|replay|context …  (see Sources/focuseval/main.swift)")
}

/// How each strictness preset would have done on every hand label so far.
/// One logged model call: who served it, how long it took, the part of the request that varies, and the answer.
func printCall(_ c: Row, time: String?, indent: String) {
    let head = [time, (c["kind"] as String).uppercased(), c["provider"] as String?, (c["model"] as String?) ?? (c["requestedModel"] as String),
                "\(c["latencyMs"] as Int) ms", (c["cost"] as Double?).map { String(format: "$%.6f", $0) },
                (c["status"] as Int?).map { "HTTP \($0)" }, c["error"] as String?]
    print("\n" + indent + head.compactMap { $0 }.joined(separator: "  "))
    let request = (try? JSONSerialization.jsonObject(with: Data((c["request"] as String).utf8))) as? [String: Any]
    let sent = (request?["state"] as? String)
        ?? ((request?["messages"] as? [[String: Any]])?.last?["content"] as? String)
    if let sent { print(indented("SENT: " + sent, indent + "  ")) }
    if let image: Data = c["image"] { print(indent + "  SENT: screenshot, \(image.count / 1024) KB") }
    guard let response: String = c["response"] else { return }
    let r = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any]
    if let answers = r?["answers"], let json = try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]) {
        print(indented("GOT: " + String(decoding: json, as: UTF8.self), indent + "  "))
    } else if let text = ((r?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String {
        print(indented("GOT: " + text, indent + "  "))
    } else {
        print(indented("GOT: " + response, indent + "  "))
    }
}

func indented(_ text: String, _ indent: String) -> String {
    indent + text.replacingOccurrences(of: "\n", with: "\n" + indent + "  ")
}

func scoreLabels(_ labels: [(onTask: Double, label: String, descriptor: String, task: String)]) {
    guard !labels.isEmpty else { return }
    print("\n\(labels.count) labeled windows so far. How each strictness setting would have done:")
    print("  Setting    right  wrong  unclear (looked closer)")
    for preset in Bands.presets {
        let js = labels.map { (preset.bands.judge($0.onTask), $0.label) }
        let right = js.filter { $0.0 != .unsure && $0.0.rawValue == $0.1 }.count
        let wrong = js.filter { $0.0 != .unsure && $0.0.rawValue != $0.1 }.count
        let unclear = js.filter { $0.0 == .unsure }.count
        print("  " + preset.name.padding(toLength: 9, withPad: " ", startingAt: 0)
              + String(format: "  %5d  %5d  %7d", right, wrong, unclear))
    }
    let on = labels.filter { $0.label == "on" }.map(\.onTask)
    let off = labels.filter { $0.label == "off" }.map(\.onTask)
    if let minOn = on.min(), let maxOff = off.max() {
        print(String(format: "\n  Lowest score you called on task: %.2f · highest you called off task: %.2f", minOn, maxOff))
        print(minOn > maxOff ? "  They don't overlap: a cutoff between them gets every label right."
                             : "  They overlap, so no single cutoff gets everything right; the mistakes are below.")
    }
    let wrong = labels.filter { let j = Bands.balanced.judge($0.onTask); return j != .unsure && j.rawValue != $0.label }
    if !wrong.isEmpty {
        print("\n  Wrong at Balanced:")
        for w in wrong { print(String(format: "    %.2f  you said %@  %@", w.onTask, w.label, w.descriptor)) }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f
    }()
}
