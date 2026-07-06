import Foundation

enum LimitSeverity: String, Sendable {
    case normal, warning, critical

    static func from(percent: Double) -> LimitSeverity {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }
}

struct LimitInfo: Identifiable, Sendable {
    let id: String
    /// e.g. "Session (5h)", "Weekly", "Weekly · Fable"
    let label: String
    let percent: Double
    let resetsAt: Date?

    var severity: LimitSeverity { .from(percent: percent) }

    var timeLeftText: String {
        guard let resetsAt else { return "" }
        let seconds = resetsAt.timeIntervalSinceNow
        if seconds <= 0 { return "resetting…" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h >= 24 {
            let d = h / 24
            return "\(d)d \(h % 24)h left"
        }
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }
}

struct ToolUsage: Sendable {
    /// Session-window limit (the one shown in the menu bar).
    var session: LimitInfo?
    /// Weekly and any scoped limits.
    var others: [LimitInfo] = []
    var plan: String?
    /// When this data was produced (for Codex: timestamp of the snapshot in the session log).
    var asOf: Date?
    var error: String?
    /// True when the fetch failed with HTTP 429 — the caller should back off.
    var rateLimited = false

    var allLimits: [LimitInfo] {
        (session.map { [$0] } ?? []) + others
    }
}
