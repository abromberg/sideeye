import Foundation

/// Scrubs obvious secrets before any text leaves the Mac. The same matching is used to black out regions of
/// screenshots before they're sent to the describer (see `ScreenReader`).
public enum Redactor {
    public enum Kind: String, Sendable {
        case email, card, key, ssn, phone

        var placeholder: String { "[\(rawValue)]" }
    }

    private static let email = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let apiKey = try! NSRegularExpression(
        pattern: #"\b(?:sk|pk|rk|ghp|gho|xox[abp])[-_][A-Za-z0-9_-]{16,}\b"#)
    // 13–19 digits, optionally grouped by spaces or dashes. Only redacted if the Luhn checksum passes.
    private static let cardCandidate = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){12,18}\d\b"#)
    // US SSN written with separators (123-45-6789 / 123 45 6789). Bare 9-digit runs are too often other IDs.
    private static let ssn = try! NSRegularExpression(pattern: #"\b\d{3}[- ]\d{2}[- ]\d{4}\b"#)
    // Phones need visible phone formatting: +country code, (area) code, or separators between groups.
    // Bare 10-digit runs are left alone (order numbers, IDs).
    private static let phone = try! NSRegularExpression(pattern:
        #"(?:\+\d{1,3}[\s.-]?(?:\(\d{1,4}\)[\s.-]?)?\d{1,4}(?:[\s.-]\d{2,4}){2,4}|(?:\b1[\s.-])?(?:\(\d{3}\)\s?|\b\d{3}[\s.-])\d{3}[\s.-]\d{4})\b"#)

    public static func redact(_ text: String) -> String {
        let matches = find(in: text)
        guard !matches.isEmpty else { return text }
        var result = text
        // Replace from the end so earlier ranges stay valid.
        for m in matches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(m.range, with: m.kind.placeholder)
        }
        return result
    }

    /// Sensitive spans in `text`, non-overlapping, in order. Earlier kinds win overlaps (a card number isn't also a phone).
    public static func find(in text: String) -> [(kind: Kind, range: Range<String.Index>)] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [(kind: Kind, range: NSRange)] = []

        func add(_ kind: Kind, _ r: NSRange) {
            guard !found.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) else { return }
            found.append((kind, r))
        }

        for m in email.matches(in: text, range: whole) { add(.email, m.range) }
        for m in apiKey.matches(in: text, range: whole) { add(.key, m.range) }
        for m in cardCandidate.matches(in: text, range: whole) {
            let digits = ns.substring(with: m.range).filter(\.isNumber)
            if (13...19).contains(digits.count), luhn(digits) { add(.card, m.range) }
        }
        for m in ssn.matches(in: text, range: whole) { add(.ssn, m.range) }
        for m in phone.matches(in: text, range: whole) { add(.phone, m.range) }

        return found
            .sorted { $0.range.location < $1.range.location }
            .compactMap { f in Range(f.range, in: text).map { (f.kind, $0) } }
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0
    }
}
