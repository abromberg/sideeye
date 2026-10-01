import FocusCore
import Foundation
import GRDB

// Replays every window judged in debug-mode sessions (one per task + window) under pipeline and brief variants,
// from the exact state Jev was sent and the text read at the switch. Windows you confirmed ("I'm on task!") are the
// only known labels, so the report lists every verdict a variant changes, for review by eye.
//
//   focuseval debugeval [--since YYYY-MM-DD] [--db path]

struct DebugWindow: Sendable {
    var session: Int64
    var task: String
    var descriptor: String
    /// The metadata-stage state as sent, brief included.
    var state: String
    var text: String
    var loggedOnTask: Double
    var confirmed: Bool
}

/// One way of judging a window: a state transform, and whether a confident off is checked again with the text (as the
/// pipeline does: the text can overturn it only with a confident on).
struct Variant: Sendable {
    var name: String
    var checkOffWithText: Bool
    var transform: @Sendable (DebugWindow) -> String
}

func debugEval(store: Store, since: Date, judge: JevJudge, writer: BriefWriter, bands: Bands = .balanced) async throws {
    let windows = try loadDebugWindows(store: store, since: since)
    print("\(windows.count) windows from debug-mode sessions since \(ISO8601DateFormatter.dateOnly.string(from: since)), "
          + "\(windows.filter(\.confirmed).count) of them confirmed on task.\n")

    // Briefs rewritten from each session's last brief input (the fullest picture of it), for trying a brief model or
    // prompt against what the logged briefs did.
    let inputs = try lastBriefInputs(store: store, since: since)
    let rewritten = try await withThrowingTaskGroup(of: (Int64, String).self) { group in
        for (session, input) in inputs {
            group.addTask { (session, try await writer.write(input: input)) }
        }
        var rewritten: [Int64: String] = [:]
        for try await (session, brief) in group { rewritten[session] = brief }
        return rewritten
    }

    let variants: [Variant] = [
        Variant(name: "rerun as sent", checkOffWithText: false) { $0.state },
        Variant(name: "check off with text", checkOffWithText: true) { $0.state },
        Variant(name: "  + session brief, rewritten", checkOffWithText: true) {
            replacingBrief($0.state, with: rewritten[$0.session])
        },
    ]

    var results: [[Double]] = []
    for v in variants {
        let ps = try await mapConcurrently(windows, limit: 8) { w -> Double in
            let state = v.transform(w)
            let p = try await judge.judge(state: state).onTask
            guard v.checkOffWithText, bands.judge(p) == .off, !w.text.isEmpty else { return p }
            let checked = try await judge.judge(state: withText(state, w.text)).onTask
            return bands.judge(checked) == .on ? checked : p
        }
        results.append(ps)
    }

    // Every verdict, for scoring outside (DEBUGEVAL_TSV=path): variant, session, task, window, probability, confirmed.
    if let path = ProcessInfo.processInfo.environment["DEBUGEVAL_TSV"] {
        var rows: [String] = []
        for (v, ps) in zip(variants, results) {
            for (w, p) in zip(windows, ps) {
                rows.append([v.name.trimmingCharacters(in: .whitespaces), "\(w.session)", w.task, w.descriptor,
                             String(format: "%.3f", p), w.confirmed ? "1" : "0"].joined(separator: "\t"))
            }
        }
        try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    let logged = windows.map(\.loggedOnTask)
    print("Variant                                  on  unsure  off   confirmed: on/unsure/off   flips vs rerun")
    for (v, ps) in [("logged", logged)] + zip(variants.map(\.name), results).map({ ($0, $1) }) {
        let js = ps.map(bands.judge)
        let confirmed = zip(windows, js).filter { $0.0.confirmed }.map(\.1)
        let flips = zip(js, results[0].map(bands.judge)).filter { $0 != $1 }.count
        print(v.padding(toLength: 38, withPad: " ", startingAt: 0)
              + String(format: "  %4d  %4d  %4d   %8d/%d/%d   %12d",
                       js.filter { $0 == .on }.count, js.filter { $0 == .unsure }.count, js.filter { $0 == .off }.count,
                       confirmed.filter { $0 == .on }.count, confirmed.filter { $0 == .unsure }.count,
                       confirmed.filter { $0 == .off }.count, flips))
    }

    for (i, v) in variants.enumerated().dropFirst() {
        print("\n== \(v.name.trimmingCharacters(in: .whitespaces)): changed from rerun")
        for (w, (before, after)) in zip(windows, zip(results[0], results[i])) where bands.judge(before) != bands.judge(after) {
            print(String(format: "  %.2f → %.2f  %@%@  [%@]  %@", before, after, w.confirmed ? "✓ " : "",
                         String(w.descriptor.prefix(90)), w.task, String(w.text.prefix(140)).replacingOccurrences(of: "\n", with: " / ")))
        }
    }
    for (session, brief) in rewritten.sorted(by: { $0.key < $1.key }) {
        print("\n-- session \(session) brief, rewritten:\n\(brief)")
    }
}

func loadDebugWindows(store: Store, since: Date) throws -> [DebugWindow] {
    try store.db.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.id, e.sessionId, s.task, e.appName, e.domain, e.windowTitle, e.debugText, e.cacheKey, m.request,
                   (SELECT onTask FROM verdict WHERE contextEventId = e.id ORDER BY id LIMIT 1) AS p,
                   EXISTS(SELECT 1 FROM userAction a WHERE a.sessionId = e.sessionId AND a.cacheKey = e.cacheKey
                          AND a.action = 'for_task') AS confirmed
            FROM contextEvent e JOIN session s ON s.id = e.sessionId
            JOIN modelCall m ON m.id = (SELECT MIN(id) FROM modelCall WHERE contextEventId = e.id AND kind = 'judge' AND status = 200)
            WHERE s.startedAt >= ? AND e.debugText IS NOT NULL
            ORDER BY e.id
            """, arguments: [since])
        var latest: [String: DebugWindow] = [:]
        for row in rows {
            guard let request = (try? JSONSerialization.jsonObject(with: Data((row["request"] as String).utf8))) as? [String: Any],
                  let state = request["state"] as? String else { continue }
            let key = "\(row["sessionId"] as Int64)|\(row["cacheKey"] as String)"
            latest[key] = DebugWindow(
                session: row["sessionId"], task: row["task"],
                descriptor: [row["appName"], row["domain"], row["windowTitle"]].compactMap { $0 as String? }.joined(separator: " — "),
                state: state.components(separatedBy: "\nVISIBLE TEXT:").first ?? state, text: row["debugText"] ?? "",
                loggedOnTask: row["p"] ?? 0, confirmed: row["confirmed"])
        }
        return latest.values.sorted { ($0.session, $0.descriptor) < ($1.session, $1.descriptor) }
    }
}

/// Each session's last brief input, the fullest picture of what it was about.
func lastBriefInputs(store: Store, since: Date) throws -> [(Int64, String)] {
    try store.db.read { db in
        try Row.fetchAll(db, sql: """
            SELECT m.sessionId, m.request FROM modelCall m JOIN session s ON s.id = m.sessionId
            WHERE s.startedAt >= ? AND m.id IN (SELECT MAX(id) FROM modelCall WHERE kind = 'brief' AND status = 200 GROUP BY sessionId)
            """, arguments: [since]).compactMap { row in
            guard let request = (try? JSONSerialization.jsonObject(with: Data((row["request"] as String).utf8))) as? [String: Any],
                  let input = ((request["messages"] as? [[String: Any]])?.last?["content"] as? String) else { return nil }
            return (row["sessionId"], input)
        }
    }
}

func replacingBrief(_ state: String, with brief: String?) -> String {
    guard let brief, let start = state.range(of: "TASK CONTEXT:\n"),
          let end = state.range(of: "\nUSER SAID ON-TASK", range: start.upperBound..<state.endIndex) else { return state }
    return String(state[..<start.upperBound]) + brief + String(state[end.lowerBound...])
}

/// The state with the window's text added, as the pipeline's text stage sends it.
func withText(_ state: String, _ text: String) -> String {
    state + "\nVISIBLE TEXT: " + String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(StateBuilder.visibleTextCap))
}

func mapConcurrently<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ f: @escaping @Sendable (T) async throws -> R) async throws -> [R] {
    try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(limit, items.count) {
            let i = next
            group.addTask { (i, try await f(items[i])) }
            next += 1
        }
        for try await (i, r) in group {
            results[i] = r
            if next < items.count {
                let j = next
                group.addTask { (j, try await f(items[j])) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
