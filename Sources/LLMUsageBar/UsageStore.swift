import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var claude = ToolUsage()
    @Published var codex = ToolUsage()
    @Published var claudeInstances: [InstanceCounter.Instance]?
    @Published var codexInstances: [InstanceCounter.Instance]?
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
            let scan = await Task.detached { InstanceCounter.scan() }.value
            self.claudeInstances = scan?.claude
            self.codexInstances = scan?.codex
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

    /// Menu bar label, typographically layered to stay narrow:
    /// small tool tag, prominent percent, and a petite working-sessions
    /// count (omitted while nothing is working).
    var menuLabel: Text {
        toolLabel("CC", claude, claudeInstances)
            + Text("\u{2009}·\u{2009}").font(.system(size: 11)).foregroundStyle(.secondary)
            + toolLabel("CX", codex, codexInstances)
    }

    private func toolLabel(_ name: String, _ usage: ToolUsage,
                           _ instances: [InstanceCounter.Instance]?) -> Text {
        let tag = Text("\(name)\u{2009}").font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
        let percent = Text(usage.session.map { "\(Int($0.percent.rounded()))%" } ?? "--")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
        let working = instances?.lazy.filter(\.isWorking).count ?? 0
        guard working > 0 else { return tag + percent }
        let badge = Text("\u{2009}▸\(working)")
            .font(.system(size: 8, weight: .bold).monospacedDigit())
        return tag + percent + badge
    }
}
