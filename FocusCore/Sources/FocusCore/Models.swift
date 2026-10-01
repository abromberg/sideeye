import Foundation

/// What's in front of the user right now, from Accessibility metadata only.
public struct ContextSnapshot: Sendable, Equatable {
    public var appName: String
    public var bundleID: String
    public var pid: Int32
    public var windowTitle: String
    public var url: String?
    public var at: Date

    public init(appName: String, bundleID: String, pid: Int32, windowTitle: String, url: String?, at: Date = Date()) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowTitle = windowTitle
        self.url = url
        self.at = at
    }

    /// Host without a leading "www.", e.g. "x.com".
    public var domain: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// One-line human description: "Google Chrome — https://x.com/home — Home / X".
    public var descriptor: String {
        [appName, url, windowTitle.isEmpty ? nil : windowTitle].compactMap { $0 }.joined(separator: " — ")
    }

    /// Short label for the floating window and menu: the domain if there is one, else the app.
    public var shortLabel: String { domain ?? appName }

    /// The window title as shown in the floating window and menu: without the trailing " - Helium" browsers add
    /// (or " - Obsidian 1.13.7"),
    /// Chromium's "High memory usage - 817 MB" note, or the spinner glyph terminals put in front.
    public var displayTitle: String {
        var t = windowTitle
        for sep in [" - ", " — ", " – "] where t.hasSuffix(sep + appName) {
            t = String(t.dropLast(sep.count + appName.count))
        }
        if !appName.isEmpty {
            // Some apps put their version after their name: "Lease example - Personal - Obsidian 1.13.7".
            let version = #"\s+[-—–]\s+"# + NSRegularExpression.escapedPattern(for: appName) + #"\s+v?[\d.]+$"#
            t = t.replacingOccurrences(of: version, with: "", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: #"\s*[-—–]\s*High memory usage\s*-\s*[\d.]+\s*[KMG]B$"#, with: "",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[^\p{L}\p{N}(\[]+"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "Ghostty · Claude Code": where you are, without the verdict (the icon and colour already say that).
    public var statusLabel: String {
        let title = displayTitle
        return title.isEmpty || title == shortLabel ? shortLabel : "\(shortLabel) · \(title)"
    }

    /// Session cache key: bundle ID + domain + normalized title.
    public var cacheKey: String {
        [bundleID, domain ?? "", Self.normalizeTitle(windowTitle)].joined(separator: "|")
    }

    /// Strips unread counters and leading status glyphs so "Inbox (3)" and "Inbox (4)" share a key, as do
    /// "✳ Focus app plan" and "◑ Focus app plan" (terminal apps animate a spinner in the title).
    public static func normalizeTitle(_ title: String) -> String {
        var t = title.lowercased()
        t = t.replacingOccurrences(of: #"[\(\[]\d+[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[^\p{L}\p{N}(]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// Extra evidence gathered when metadata alone leaves the judge unsure.
public struct Evidence: Sendable, Equatable {
    public var visibleText: String?
    public var screenDescription: String?

    public init(visibleText: String? = nil, screenDescription: String? = nil) {
        self.visibleText = visibleText
        self.screenDescription = screenDescription
    }
}

/// Which step of the pipeline produced a verdict.
public enum Stage: String, Sendable, Codable {
    case metadata, text, ocr, describer, cache, exception
}

public enum Judgment: String, Sendable, Codable {
    case on, off, unsure
}

/// Probability bands mapping Jev's on_task probability to a judgment.
public struct Bands: Sendable, Equatable, Codable {
    public var on: Double
    public var off: Double

    public init(on: Double = 0.6, off: Double = 0.35) {
        self.on = on
        self.off = off
    }

    /// The Relaxed / Balanced / Strict choices in Settings.
    public static let relaxed = Bands(on: 0.5, off: 0.2)
    public static let balanced = Bands(on: 0.6, off: 0.35)
    public static let strict = Bands(on: 0.7, off: 0.45)
    public static let presets: [(name: String, bands: Bands)] = [
        ("Relaxed", .relaxed), ("Balanced", .balanced), ("Strict", .strict),
    ]

    public func judge(_ p: Double) -> Judgment {
        if p >= on { return .on }
        if p <= off { return .off }
        return .unsure
    }
}

public struct Verdict: Sendable, Equatable {
    public var onTask: Double
    public var category: String?
    public var stage: Stage
    public var judgment: Judgment

    public init(onTask: Double, category: String?, stage: Stage, judgment: Judgment) {
        self.onTask = onTask
        self.category = category
        self.stage = stage
        self.judgment = judgment
    }
}
