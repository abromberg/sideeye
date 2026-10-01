import Foundation

/// Builds the literal `state` string sent to the judge. The task is passed through verbatim; what it involves goes
/// on its own TASK CONTEXT line (see `BriefWriter`), fixed until the user corrects a verdict.
///
/// No history of recent contexts: tested 2026-09-27, a RECENT line of prior off-task contexts dragged an on-task
/// note from 0.67 to 0.29. Each context is judged on its own.
public enum StateBuilder {
    public static let visibleTextCap = 2_500

    public static func build(task: String, brief: String? = nil, exceptions: [String], now: ContextSnapshot, evidence: Evidence) -> String {
        render(task: task, brief: brief, exceptions: exceptions, now: now, evidence: evidence, digest: false)
    }

    /// What gets persisted: identical to the state, except visible text is replaced by its length.
    /// Raw screen text is never stored.
    public static func digest(task: String, brief: String? = nil, exceptions: [String], now: ContextSnapshot, evidence: Evidence) -> String {
        render(task: task, brief: brief, exceptions: exceptions, now: now, evidence: evidence, digest: true)
    }

    private static func render(task: String, brief: String?, exceptions: [String], now: ContextSnapshot, evidence: Evidence, digest: Bool) -> String {
        var lines: [String] = []
        lines.append("TASK: \(task)")
        if let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
            lines.append("TASK CONTEXT:\n\(brief)")
        }
        lines.append("USER SAID ON-TASK THIS SESSION: \(exceptions.isEmpty ? "(none)" : exceptions.joined(separator: "; "))")
        lines.append("NOW: \(now.descriptor)")
        if let text = evidence.visibleText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let capped = String(text.prefix(visibleTextCap))
            lines.append("VISIBLE TEXT: \(digest ? "<\(capped.count) chars>" : capped)")
        }
        if let desc = evidence.screenDescription, !desc.isEmpty {
            lines.append("SCREEN DESCRIPTION: \(desc)")
        }
        return Redactor.redact(lines.joined(separator: "\n"))
    }
}
