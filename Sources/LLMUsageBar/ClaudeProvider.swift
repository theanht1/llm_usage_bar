import Foundation

/// Fetches Claude Code usage from Anthropic's OAuth usage endpoint,
/// using the credential Claude Code already stores in the macOS Keychain.
/// Read-only: never writes or refreshes the token.
enum ClaudeProvider {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async -> ToolUsage {
        let credential: Credential
        do {
            credential = try readCredential()
        } catch let err as ProviderError {
            return ToolUsage(error: err.message)
        } catch {
            return ToolUsage(error: error.localizedDescription)
        }

        if let expiresAt = credential.expiresAt, expiresAt < Date() {
            return ToolUsage(
                plan: credential.plan,
                error: "Token expired — open Claude Code to refresh it"
            )
        }

        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Identify as the Claude Code CLI: anonymous clients fall into a far
        // stricter rate-limit bucket and get persistent 429s.
        request.setValue("claude-cli/\(claudeCLIVersion()) (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 429 {
                    return ToolUsage(
                        plan: credential.plan,
                        error: "Rate limited by usage API — will retry later",
                        rateLimited: true
                    )
                }
                let hint = status == 401 ? " — open Claude Code to refresh login" : ""
                return ToolUsage(plan: credential.plan, error: "Usage API returned HTTP \(status)\(hint)")
            }
            var usage = try parse(data)
            usage.plan = credential.plan
            usage.asOf = Date()
            return usage
        } catch {
            return ToolUsage(plan: credential.plan, error: "Network error: \(error.localizedDescription)")
        }
    }

    /// Version of the locally installed Claude Code CLI, read from the
    /// `claude` symlink target (…/versions/<version>); falls back to a
    /// known-good version string.
    private static func claudeCLIVersion() -> String {
        let launcher = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude").path
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: launcher) {
            let version = URL(fileURLWithPath: target).lastPathComponent
            if version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil {
                return version
            }
        }
        return "2.1.199"
    }

    // MARK: - Keychain

    private struct Credential {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
    }

    private struct ProviderError: Error {
        let message: String
    }

    /// Reads the credential via /usr/bin/security so the Keychain ACL check
    /// applies to the already-authorized `security` binary, not this app —
    /// avoids permission prompts on every rebuild of an ad-hoc-signed app.
    private static func readCredential() throws -> Credential {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else {
            throw ProviderError(message: "No Claude Code credential in Keychain — run `claude` and log in")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else {
            throw ProviderError(message: "Unrecognized Keychain credential format")
        }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let plan = oauth["subscriptionType"] as? String
        return Credential(accessToken: token, expiresAt: expiresAt, plan: plan)
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) throws -> ToolUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolUsage(error: "Unrecognized usage API response")
        }

        var usage = ToolUsage()

        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            for (index, limit) in limits.enumerated() {
                guard let percent = limit["percent"] as? Double else { continue }
                let kind = limit["kind"] as? String ?? "limit"
                let resetsAt = (limit["resets_at"] as? String).flatMap(parseISODate)
                let info = LimitInfo(
                    id: "claude-\(kind)-\(index)",
                    label: label(forKind: kind, limit: limit),
                    percent: percent,
                    resetsAt: resetsAt
                )
                if kind == "session", usage.session == nil {
                    usage.session = info
                } else {
                    usage.others.append(info)
                }
            }
        }

        // Fallback for older response shapes without a `limits` array.
        if usage.session == nil, let fiveHour = root["five_hour"] as? [String: Any],
           let utilization = fiveHour["utilization"] as? Double {
            usage.session = LimitInfo(
                id: "claude-session",
                label: "Session (5h)",
                percent: utilization,
                resetsAt: (fiveHour["resets_at"] as? String).flatMap(parseISODate)
            )
            if let sevenDay = root["seven_day"] as? [String: Any],
               let weekly = sevenDay["utilization"] as? Double {
                usage.others.append(LimitInfo(
                    id: "claude-weekly",
                    label: "Weekly",
                    percent: weekly,
                    resetsAt: (sevenDay["resets_at"] as? String).flatMap(parseISODate)
                ))
            }
        }

        if usage.session == nil && usage.others.isEmpty {
            usage.error = "No limits reported by usage API"
        }
        return usage
    }

    private static func label(forKind kind: String, limit: [String: Any]) -> String {
        switch kind {
        case "session":
            return "Session (5h)"
        case "weekly_all":
            return "Weekly (all models)"
        case "weekly_scoped":
            if let scope = limit["scope"] as? [String: Any],
               let model = scope["model"] as? [String: Any],
               let name = model["display_name"] as? String {
                return "Weekly · \(name)"
            }
            return "Weekly (scoped)"
        default:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func parseISODate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}
