import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var claude = ToolUsage()
    @Published var codex = ToolUsage()
    @Published var lastRefreshed: Date?
    @Published var isRefreshing = false

    private var timer: Timer?
    /// Codex is local file reading — cheap to poll often.
    private static let tickInterval: TimeInterval = 60
    /// The OAuth usage endpoint rate-limits aggressively; poll it sparingly.
    private static let claudeInterval: TimeInterval = 300
    /// First 429 backoff; doubles on consecutive 429s up to the max
    /// (the endpoint's quota window can be long).
    private static let claudeBackoffAfter429: TimeInterval = 600
    private static let claudeBackoffMax: TimeInterval = 3600

    private var lastClaudeAttempt: Date?
    private var claudeBackoffUntil: Date?
    private var claudeBackoff: TimeInterval = UsageStore.claudeBackoffAfter429

    init() {
        refresh(force: true)
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let fetchClaude = shouldFetchClaude(force: force)
        if fetchClaude { lastClaudeAttempt = Date() }

        Task {
            self.codex = CodexProvider.fetch()
            if fetchClaude {
                self.applyClaude(await ClaudeProvider.fetch())
            }
            self.lastRefreshed = Date()
            self.isRefreshing = false
        }
    }

    private func shouldFetchClaude(force: Bool) -> Bool {
        let now = Date()
        if let backoffUntil = claudeBackoffUntil, now < backoffUntil { return false }
        if force { return true }
        guard let last = lastClaudeAttempt else { return true }
        return now.timeIntervalSince(last) >= Self.claudeInterval
    }

    /// On failure, keep the last good limits (with their original `asOf`)
    /// and surface the problem alongside them instead of blanking the card.
    private func applyClaude(_ new: ToolUsage) {
        if new.rateLimited {
            claudeBackoffUntil = Date().addingTimeInterval(claudeBackoff)
            claudeBackoff = min(claudeBackoff * 2, Self.claudeBackoffMax)
        } else if new.error == nil {
            claudeBackoffUntil = nil
            claudeBackoff = Self.claudeBackoffAfter429
        }

        if new.error != nil, new.allLimits.isEmpty, !claude.allLimits.isEmpty {
            claude.error = new.rateLimited
                ? "Rate limited by usage API — showing earlier data"
                : new.error
        } else {
            claude = new
        }
    }

    var menuTitle: String {
        "\(shortStatus("CC", claude)) · \(shortStatus("CX", codex))"
    }

    private func shortStatus(_ prefix: String, _ usage: ToolUsage) -> String {
        guard let session = usage.session else { return "\(prefix) --" }
        return "\(prefix) \(Int(session.percent.rounded()))%"
    }
}
