import SwiftUI

struct DetailsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolCard(title: "Claude Code", usage: store.claude)
            ToolCard(title: "Codex", usage: store.codex)
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var footer: some View {
        HStack {
            Button {
                store.refresh(force: true)
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshing)

            Spacer()

            if let refreshed = store.lastRefreshed {
                Text("Updated \(refreshed, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

private struct ToolCard: View {
    let title: String
    let usage: ToolUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                if let plan = usage.plan {
                    Text(plan.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let asOf = usage.asOf, Date().timeIntervalSince(asOf) > 120 {
                    Text("as of \(asOf, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = usage.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(usage.allLimits) { limit in
                LimitRow(limit: limit)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LimitRow: View {
    let limit: LimitInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(limit.label).font(.caption)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(color)
            }
            ProgressView(value: min(limit.percent, 100), total: 100)
                .tint(color)
                .controlSize(.small)
            HStack {
                Text(limit.timeLeftText)
                Spacer()
                if let resetsAt = limit.resetsAt {
                    Text("resets \(resetText(resetsAt))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch limit.severity {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    private func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        let isToday = Calendar.current.isDateInToday(date)
        formatter.dateFormat = isToday ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
