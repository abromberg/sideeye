import FocusCore
import Foundation
import GRDB

/// Scores hand-labeled windows with and without a task brief, to see whether it separates on from off. Labels file: task<TAB>descriptor<TAB>on|off|? ("?" rows are shown, not scored).
func compareContexts(labelsPath: String) async throws {
    struct Item { var task, descriptor, label: String }
    let items = try String(contentsOfFile: labelsPath, encoding: .utf8)
        .split(separator: "\n").map(String.init)
        .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { line -> Item in
            let f = line.components(separatedBy: "\t")
            guard f.count == 3 else { fail("bad line: \(line)") }
            return Item(task: f[0], descriptor: f[1], label: f[2])
        }
    let store = try Store(url: URL(fileURLWithPath: option("--db") ?? Store.defaultURL.path))
    let key: @Sendable () -> String? = { ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] }
    let writer = BriefWriter(model: ProcessInfo.processInfo.environment["BRIEF_MODEL"] ?? BriefWriter.defaultModel, apiKey: key)
    func norm(_ t: String) -> String { t.lowercased().trimmingCharacters(in: .whitespaces) }

    // History: a fixture (task<TAB>confirmed example) or the log, leaving out each task's own sessions.
    var fixture: [PastTask]?
    if let path = option("--past") {
        var byTask: [(String, [String])] = []
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.components(separatedBy: "\t")
            guard f.count == 2 else { continue }
            if let i = byTask.firstIndex(where: { $0.0 == f[0] }) { if f[1] != "-" { byTask[i].1.append(f[1]) } }
            else { byTask.append((f[0], f[1] == "-" ? [] : [f[1]])) }
        }
        fixture = byTask.map { PastTask(task: $0.0, confirmed: $0.1) }
    }
    let logPast = try store.pastTasks(limit: 20)
    func past(for task: String) -> [PastTask] { fixture ?? logPast.filter { norm($0.task) != norm(task) } }

    // Chrome keyed by app name, since labels carry app names, not bundle IDs.
    let chrome = try await store.db.read { db in
        TitleChrome(windows: try Row.fetchAll(db, sql: "SELECT appName, domain, windowTitle FROM contextEvent GROUP BY cacheKey").map {
            let snap = ContextSnapshot(appName: $0["appName"], bundleID: "", pid: 0, windowTitle: $0["windowTitle"], url: nil)
            return ($0["appName"], $0["domain"], snap.displayTitle)
        })
    }

    //   v1:     the previous prompt: every other task goes under "Not this"
    //   v2:     past tasks sorted into same / related / unrelated; only unrelated are ruled out
    //   v2+fix: v2 plus one "I'm on task" on the task's first labeled-on window, as a mid-session rewrite would
    let v1 = { var w = writer; w.prompt = v1Prompt; return w }()
    let tasks = Array(Set(items.map(\.task))).sorted()
    var briefs: [String: [String: String]] = [:]
    var fixed: [String: String] = [:]
    try await withThrowingTaskGroup(of: (String, String, String).self) { group in
        for task in tasks {
            let p = past(for: task)
            group.addTask { (task, "v1", try await v1.write(task: task, past: p)) }
            group.addTask { (task, "v2", try await writer.write(task: task, past: p)) }
            if let fix = items.first(where: { $0.task == task && $0.label == "on" }).flatMap({ snapshot($0.descriptor).briefExample(chrome: chrome) }) {
                fixed[task] = fix
                group.addTask { (task, "fix", try await writer.write(task: task, past: p, confirmedNow: [fix])) }
            }
        }
        for try await (task, kind, brief) in group { briefs[task, default: [:]][kind] = brief }
    }
    for task in tasks {
        print("── \(task)")
        for kind in ["v1", "v2", "fix"] {
            print("  [\(kind)]" + (kind == "fix" ? " after confirming: \(fixed[task] ?? "-")" : ""))
            print("    " + (briefs[task]?[kind] ?? "").replacingOccurrences(of: "\n", with: "\n    "))
        }
    }

    let variants: [(name: String, brief: (String) -> String?)] = [
        ("base", { _ in nil }),
        ("v1", { briefs[$0]?["v1"] }),
        ("v2", { briefs[$0]?["v2"] }),
        ("v2+fix", { briefs[$0]?["fix"] }),
    ]

    // Every (item, variant) judged concurrently, a few at a time.
    var scores = Array(repeating: Array(repeating: Double.nan, count: variants.count), count: items.count)
    var costs = Array(repeating: 0.0, count: variants.count)
    let jobs = items.indices.flatMap { i in variants.indices.map { (i, $0) } }
    try await withThrowingTaskGroup(of: (Int, Int, JudgeResult).self) { group in
        var next = 0
        func add() {
            guard next < jobs.count else { return }
            let (i, v) = jobs[next]; next += 1
            let s = state(task: items[i].task, descriptor: items[i].descriptor, brief: variants[v].brief(items[i].task))
            group.addTask { (i, v, try await judge.judge(state: s)) }
        }
        for _ in 0..<8 { add() }
        for try await (i, v, r) in group { scores[i][v] = r.onTask; costs[v] += r.cost ?? 0; add() }
    }

    let header = variants.map { $0.name.padding(toLength: 11, withPad: " ", startingAt: 0) }.joined(separator: " ")
    print("\nlabel  \(header)  window")
    var lastTask = ""
    for (i, item) in items.enumerated() {
        if item.task != lastTask { print("── \(item.task)"); lastTask = item.task }
        let cells = scores[i].map { p -> String in
            let j = Bands.balanced.judge(p)
            let mark = item.label == "?" || j == .unsure ? " " : (j.rawValue == item.label ? " " : "✗")
            return String(format: "%.2f%@", p, mark).padding(toLength: 11, withPad: " ", startingAt: 0)
        }.joined(separator: " ")
        print("\(item.label.padding(toLength: 5, withPad: " ", startingAt: 0))  \(cells)  \(item.descriptor.prefix(90))")
    }

    print("\nAt Balanced (on ≥ \(Bands.balanced.on), off ≤ \(Bands.balanced.off)), labeled rows only:")
    print("  variant       right  wrong  unsure   mean on  mean off  lowest on  highest off  $/1k calls")
    for (v, variant) in variants.enumerated() {
        let rows = items.indices.filter { items[$0].label != "?" }
        let js = rows.map { (Bands.balanced.judge(scores[$0][v]), items[$0].label) }
        let on = rows.filter { items[$0].label == "on" }.map { scores[$0][v] }
        let off = rows.filter { items[$0].label == "off" }.map { scores[$0][v] }
        print(String(format: "  %@  %5d  %5d  %6d   %7.2f  %8.2f  %9.2f  %11.2f  %10.3f",
                     variant.name.padding(toLength: 12, withPad: " ", startingAt: 0),
                     js.filter { $0.0 != .unsure && $0.0.rawValue == $0.1 }.count,
                     js.filter { $0.0 != .unsure && $0.0.rawValue != $0.1 }.count,
                     js.filter { $0.0 == .unsure }.count,
                     on.reduce(0, +) / Double(max(on.count, 1)), off.reduce(0, +) / Double(max(off.count, 1)),
                     on.min() ?? .nan, off.max() ?? .nan, costs[v] / Double(items.count) * 1000))
    }
}

/// The first prompt that shipped, kept to compare against: it put every other past task under "Not this".
let v1Prompt = """
A focus app checks whether each window the user looks at serves the TASK they typed. The task is often terse: \
a person, a project name, an abbreviation. Write a brief so a judge who sees one window at a time can tell this \
task apart from the user's other work.

PAST TASKS are what the user has worked on before. Any that are this same task in other words describe it; the \
rest are the user's other work. CONFIRMED windows are ones the user said belong to a task: treat them as \
examples that widen what the task covers, never as the whole of it.

Only use names from the input; don't guess what a name means. Keep "Involves" at least as broad as the task's \
own words. Under "Not this", name only the user's other tasks and projects, never apps, sites, email or \
calendar in general: the user does all their work in the same apps.

Reply with exactly these three lines, each under 200 characters, no preamble:
Involves: <what this task covers: its subjects, people, projects, and examples from confirmed windows>
Counts: <kinds of work that serve it>
Not this: <the user's other tasks and projects>
"""
