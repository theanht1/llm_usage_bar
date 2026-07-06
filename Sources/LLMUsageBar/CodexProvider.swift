import Foundation

/// Reads Codex usage from the `rate_limits` snapshots the Codex CLI writes
/// into its session logs (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl).
/// Entirely local — no network, no credentials.
enum CodexProvider {
    private static let sessionsDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    /// Newest-first session files to inspect (a just-started session may not
    /// have a rate_limits event yet, so we look at a few).
    private static let filesToCheck = 5
    private static let tailBytes = 256 * 1024

    static func fetch() -> ToolUsage {
        let files = recentSessionFiles()
        guard !files.isEmpty else {
            return ToolUsage(error: "No Codex sessions found in ~/.codex/sessions")
        }
        for file in files.prefix(filesToCheck) {
            if let usage = lastRateLimits(in: file) {
                return usage
            }
        }
        return ToolUsage(error: "No rate-limit data in recent Codex sessions")
    }

    private static func recentSessionFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, mtime))
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func lastRateLimits(in file: URL) -> ToolUsage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard
                let lineData = line.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let payload = event["payload"] as? [String: Any],
                let rateLimits = payload["rate_limits"] as? [String: Any]
            else { continue }

            let timestamp = (event["timestamp"] as? String).flatMap(parseISODate)
            return usage(from: rateLimits, asOf: timestamp)
        }
        return nil
    }

    private static func usage(from rateLimits: [String: Any], asOf: Date?) -> ToolUsage {
        var result = ToolUsage()
        result.asOf = asOf
        result.plan = rateLimits["plan_type"] as? String

        if let info = limitInfo(rateLimits["primary"], id: "codex-session") {
            result.session = info
        }
        if let info = limitInfo(rateLimits["secondary"], id: "codex-weekly") {
            result.others.append(info)
        }
        if result.session == nil && result.others.isEmpty {
            result.error = "Unrecognized rate-limit data"
        }
        return result
    }

    private static func limitInfo(_ raw: Any?, id: String) -> LimitInfo? {
        guard
            let dict = raw as? [String: Any],
            let usedPercent = dict["used_percent"] as? Double
        else { return nil }

        let resetsAt = (dict["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let windowMinutes = dict["window_minutes"] as? Int

        // The snapshot is only as fresh as the last Codex request; if the
        // window has already reset since then, the real usage is back to 0.
        let expired = resetsAt.map { $0 < Date() } ?? false

        return LimitInfo(
            id: id,
            label: label(forWindowMinutes: windowMinutes),
            percent: expired ? 0 : usedPercent,
            resetsAt: expired ? nil : resetsAt
        )
    }

    private static func label(forWindowMinutes minutes: Int?) -> String {
        guard let minutes else { return "Limit" }
        let hours = minutes / 60
        if hours >= 24 * 6 { return "Weekly" }
        return "Session (\(hours)h)"
    }

    private static func parseISODate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}
