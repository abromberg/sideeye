import Foundation

/// Title segments an app repeats in (nearly) every window: a vault, workspace or account name, a version, an unread
/// count. They say nothing about what's in the window, and in a brief they make unrelated windows look alike: with
/// "Lease example - Personal - Obsidian 1.13.7" as a confirmed example, the vault name "Personal" pulled every other
/// note toward on task ("Garden plan" 0.45 → 0.81). Learned per app (and per site in a browser) from the log.
public struct TitleChrome: Sendable, Equatable {
    public static let separators = [" - ", " — ", " – ", " | ", " · "]
    /// A segment is chrome when it's in at least this share of an app's distinct titles, once there are enough to tell.
    public static let share = 0.9
    public static let minTitles = 4

    public private(set) var chrome: [String: Set<String>]

    public init() { chrome = [:] }

    /// - Parameter windows: every distinct window seen. Chrome is learned per app and per app + site, so a browser
    /// learns Gmail's chrome without treating it as the browser's, and an app with and without a URL is still one app.
    public init(windows: [(bundleID: String, domain: String?, title: String)]) {
        var titles: [String: Set<String>] = [:]
        for w in windows {
            titles[Self.key(w.bundleID, nil), default: []].insert(w.title)
            if w.domain != nil { titles[Self.key(w.bundleID, w.domain), default: []].insert(w.title) }
        }
        chrome = titles.compactMapValues { ts in
            guard ts.count >= Self.minTitles else { return nil }
            var counts: [String: Int] = [:]
            for t in ts { for seg in Set(Self.segments(t).map(Self.normalize)) { counts[seg, default: 0] += 1 } }
            let found = Set(counts.filter { Double($0.value) >= Self.share * Double(ts.count) }.keys)
            return found.isEmpty ? nil : found
        }
    }

    static func key(_ bundleID: String, _ domain: String?) -> String {
        [bundleID, domain ?? ""].joined(separator: "|")
    }

    /// The title without its chrome segments. Returns the title unchanged when every segment is chrome.
    public func strip(_ title: String, bundleID: String, domain: String?) -> String {
        let chrome = (self.chrome[Self.key(bundleID, nil)] ?? []).union(domain.flatMap { self.chrome[Self.key(bundleID, $0)] } ?? [])
        guard !chrome.isEmpty else { return title }
        let kept = Self.segments(title).filter { !chrome.contains(Self.normalize($0)) }
        return kept.isEmpty ? title : kept.joined(separator: " - ")
    }

    static func segments(_ title: String) -> [String] {
        var t = title
        for sep in separators { t = t.replacingOccurrences(of: sep, with: "\u{1F}") }
        return t.split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Case and numbers don't matter: "3 new items" and "1 new item" are the same chrome.
    static func normalize(_ segment: String) -> String {
        segment.lowercased()
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"(\w)s\b"#, with: "$1", options: .regularExpression)
    }
}
