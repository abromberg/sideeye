import Foundation
import GRDB

/// Local SQLite log: sessions, context events, verdicts, and user actions (the actions are labels for replay evals).
/// Stores metadata and state digests only — never raw screen text, unless debug logging is on (`debugText`, `modelCall`).
public final class Store: Sendable {
    public let db: DatabaseQueue

    public static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Side Eye", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("focus.sqlite")
    }

    public init(url: URL = Store.defaultURL) throws {
        db = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(db)
    }

    public init(inMemory: Void) throws {
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("task", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("pomodoroMinutes", .integer)
                t.column("endReason", .text)
                t.column("summary", .text)
            }
            try db.create(table: "contextEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade)
                t.column("at", .datetime).notNull()
                t.column("trigger", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("bundleID", .text).notNull()
                t.column("domain", .text)
                t.column("windowTitle", .text).notNull()
                t.column("cacheKey", .text).notNull()
            }
            try db.create(table: "verdict") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("contextEvent", onDelete: .cascade)
                t.column("at", .datetime).notNull()
                t.column("stage", .text).notNull()
                t.column("onTask", .double).notNull()
                t.column("judgment", .text).notNull()
                t.column("category", .text)
                t.column("model", .text)
                t.column("cost", .double)
                t.column("latencyMs", .integer)
                t.column("stateDigest", .text)
            }
            try db.create(table: "userAction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade)
                t.belongsTo("contextEvent", onDelete: .setNull)
                t.column("at", .datetime).notNull()
                t.column("action", .text).notNull()
                t.column("cacheKey", .text)
                t.column("detail", .text)
            }
        }
        m.registerMigration("v2-labels") { db in
            // Hand labels from `focuseval review`: was this context really on task for that task?
            try db.create(table: "label") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .datetime).notNull()
                t.column("task", .text).notNull()
                t.column("cacheKey", .text).notNull()
                t.column("descriptor", .text).notNull()
                t.column("onTask", .double).notNull()
                t.column("label", .text).notNull()
                t.uniqueKey(["task", "cacheKey"], onConflict: .replace)
            }
        }
        m.registerMigration("v3-debug") { db in
            // Filled only while Settings → Debug logging is on: the window's text at each switch, and every model call
            // as sent and received.
            try db.alter(table: "contextEvent") { t in t.add(column: "debugText", .text) }
            try db.create(table: "modelCall") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade)
                t.belongsTo("contextEvent", onDelete: .setNull)
                t.column("at", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("requestedModel", .text).notNull()
                t.column("model", .text)
                t.column("provider", .text)
                t.column("status", .integer)
                t.column("latencyMs", .integer).notNull()
                t.column("cost", .double)
                t.column("request", .text).notNull()
                t.column("response", .text)
                t.column("error", .text)
                t.column("image", .blob)
            }
        }
        return m
    }

    @discardableResult
    public func startSession(task: String, pomodoroMinutes: Int?, at: Date = Date()) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO session (task, startedAt, pomodoroMinutes) VALUES (?, ?, ?)",
                arguments: [task, at, pomodoroMinutes])
            return db.lastInsertedRowID
        }
    }

    public func endSession(_ id: Int64, reason: String, summary: String?, at: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE session SET endedAt = ?, endReason = ?, summary = ? WHERE id = ?",
                arguments: [at, reason, summary, id])
        }
    }

    @discardableResult
    public func logContext(session: Int64, snapshot s: ContextSnapshot, trigger: String) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO contextEvent (sessionId, at, trigger, appName, bundleID, domain, windowTitle, cacheKey)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [session, s.at, trigger, s.appName, s.bundleID, s.domain,
                            Redactor.redact(s.windowTitle), s.cacheKey])
            return db.lastInsertedRowID
        }
    }

    public func logVerdict(event: Int64, verdict v: Verdict, model: String?, cost: Double?,
                           latencyMs: Int?, stateDigest: String?, at: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO verdict (contextEventId, at, stage, onTask, judgment, category, model, cost, latencyMs, stateDigest)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [event, at, v.stage.rawValue, v.onTask, v.judgment.rawValue, v.category,
                            model, cost, latencyMs, stateDigest])
        }
    }

    /// Debug logging only: a model call as sent and received, stamped with when it came back.
    public func logModelCall(session: Int64?, event: Int64?, call c: ModelCall, at: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO modelCall (sessionId, contextEventId, at, kind, requestedModel, model, provider, status, latencyMs,
                                       cost, request, response, error, image)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [session, event, at, c.kind, c.requestedModel, c.model, c.provider, c.status, c.latencyMs,
                            c.cost, c.request, c.response, c.error, c.image])
        }
    }

    /// Debug logging only: the window's text (redacted) as it was when the event was logged.
    public func logDebugText(event: Int64, text: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE contextEvent SET debugText = ? WHERE id = ?", arguments: [Redactor.redact(text), event])
        }
    }

    public func logAction(session: Int64, event: Int64?, action: String, cacheKey: String?,
                          detail: String? = nil, at: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO userAction (sessionId, contextEventId, at, action, cacheKey, detail) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [session, event, at, action, cacheKey, detail])
        }
    }

    /// A distinct (task, window) the judge scored, for hand labeling.
    public struct ReviewItem: Sendable {
        public var task: String
        public var cacheKey: String
        public var descriptor: String
        public var onTask: Double
        public var seconds: Int
        public var label: String?
    }

    /// Everything judged since `date`, one row per task + window (its last real verdict, not a cache hit),
    /// with how long you spent there and any existing label. Grouped by task, longest-viewed first.
    public func reviewItems(since date: Date) throws -> [ReviewItem] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                WITH ev AS (
                    SELECT e.*, s.task,
                           COALESCE(LEAD(e.at) OVER (PARTITION BY e.sessionId ORDER BY e.id), s.endedAt, e.at) AS nextAt
                    FROM contextEvent e JOIN session s ON s.id = e.sessionId
                    WHERE e.at >= ?
                ),
                judged AS (
                    SELECT ev.task, ev.cacheKey, MAX(v.id) AS vid
                    FROM ev JOIN verdict v ON v.contextEventId = ev.id
                    WHERE v.stage NOT IN ('cache', 'exception')
                    GROUP BY ev.task, ev.cacheKey
                )
                SELECT j.task, j.cacheKey, v.onTask,
                       (SELECT appName || COALESCE(' — ' || domain, '') || CASE WHEN windowTitle = '' THEN '' ELSE ' — ' || windowTitle END
                        FROM ev WHERE ev.cacheKey = j.cacheKey ORDER BY ev.id DESC LIMIT 1) AS descriptor,
                       (SELECT CAST(ROUND(SUM(MAX(0, MIN(600, (julianday(nextAt) - julianday(at)) * 86400)))) AS INTEGER)
                        FROM ev WHERE ev.cacheKey = j.cacheKey AND ev.task = j.task) AS seconds,
                       l.label
                FROM judged j
                JOIN verdict v ON v.id = j.vid
                LEFT JOIN label l ON l.task = j.task AND l.cacheKey = j.cacheKey
                ORDER BY j.task, seconds DESC
                """, arguments: [date])
            return rows.map {
                ReviewItem(task: $0["task"], cacheKey: $0["cacheKey"], descriptor: $0["descriptor"] ?? $0["cacheKey"],
                           onTask: $0["onTask"], seconds: $0["seconds"] ?? 0, label: $0["label"])
            }
        }
    }

    public func saveLabel(_ item: ReviewItem, label: String, at: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO label (at, task, cacheKey, descriptor, onTask, label) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [at, item.task, item.cacheKey, item.descriptor, item.onTask, label])
        }
    }

    /// All hand labels, for scoring the strictness presets.
    public func labels() throws -> [(onTask: Double, label: String, descriptor: String, task: String)] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT onTask, label, descriptor, task FROM label ORDER BY onTask").map {
                ($0["onTask"], $0["label"], $0["descriptor"], $0["task"])
            }
        }
    }

    /// Recent tasks other than the one in `excludingSession`, most recent first, each with the windows the user
    /// confirmed under it ("for_task"), cleaned of app chrome. Feeds `BriefWriter`.
    public func pastTasks(limit: Int = 12, windowsPerTask: Int = 6, excludingSession: Int64? = nil) throws -> [PastTask] {
        let chrome = try titleChrome()
        return try db.read { db in
            let tasks = try String.fetchAll(db, sql: """
                SELECT task FROM session WHERE id IS NOT ? GROUP BY LOWER(TRIM(task)) ORDER BY MAX(startedAt) DESC LIMIT ?
                """, arguments: [excludingSession, limit])
            return try tasks.map { task in
                let confirmed = try Row.fetchAll(db, sql: """
                    SELECT e.appName, e.bundleID, e.domain, e.windowTitle
                    FROM userAction a
                    JOIN session s ON s.id = a.sessionId
                    JOIN contextEvent e ON e.id = a.contextEventId
                    WHERE LOWER(TRIM(s.task)) = LOWER(TRIM(?)) AND a.action = 'for_task' AND s.id IS NOT ?
                    GROUP BY a.cacheKey ORDER BY MAX(a.id) DESC LIMIT ?
                    """, arguments: [task, excludingSession, windowsPerTask]).compactMap { row -> String? in
                    let domain: String? = row["domain"]
                    return ContextSnapshot(appName: row["appName"], bundleID: row["bundleID"], pid: 0, windowTitle: row["windowTitle"],
                                           url: domain.map { "https://\($0)" }).briefExample(chrome: chrome)
                }
                return PastTask(task: task, confirmed: confirmed)
            }
        }
    }

    /// The distinct briefs a task was judged with since `date`, in order, read back from the verdicts' state digests.
    public func briefs(task: String, since date: Date) throws -> [String] {
        let digests = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT v.stateDigest FROM verdict v
                JOIN contextEvent e ON e.id = v.contextEventId JOIN session s ON s.id = e.sessionId
                WHERE s.task = ? AND v.at >= ? AND v.stateDigest LIKE '%TASK CONTEXT:%' ORDER BY v.id
                """, arguments: [task, date])
        }
        var seen: [String] = []
        for d in digests {
            guard let start = d.range(of: "TASK CONTEXT:\n")?.upperBound else { continue }
            let rest = d[start...]
            let brief = String(rest[..<(rest.range(of: "\nUSER SAID ON-TASK")?.lowerBound ?? rest.endIndex)])
            if seen.last != brief, !seen.contains(brief) { seen.append(brief) }
        }
        return seen
    }

    /// What each app repeats in every window title, learned from every distinct window logged.
    public func titleChrome() throws -> TitleChrome {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT appName, bundleID, domain, windowTitle FROM contextEvent GROUP BY cacheKey")
            return TitleChrome(windows: rows.map { row in
                let snap = ContextSnapshot(appName: row["appName"], bundleID: row["bundleID"], pid: 0, windowTitle: row["windowTitle"], url: nil)
                return (row["bundleID"], row["domain"], snap.displayTitle)
            })
        }
    }

    /// Pomodoros that ran to the end of their timer.
    public func completedBlocks(since date: Date) throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session WHERE endReason = 'completed' AND startedAt >= ?",
                             arguments: [date]) ?? 0
        }
    }

    /// Spend today across all logged calls, for the settings screen.
    public func costSince(_ date: Date) throws -> Double {
        try db.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost), 0) FROM verdict WHERE at >= ?", arguments: [date]) ?? 0
        }
    }
}
