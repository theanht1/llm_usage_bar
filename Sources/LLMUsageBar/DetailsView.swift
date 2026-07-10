import SwiftUI

struct DetailsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolCard(title: "Claude Code", usage: store.claude, instances: store.claudeInstances)
            ToolCard(title: "Codex", usage: store.codex, instances: store.codexInstances)
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
    let instances: [InstanceCounter.Instance]?
    @State private var showInstances = false

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
                if let instances {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showInstances.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(instances.filter(\.isWorking).count)/\(instances.count) sessions")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .rotationEffect(.degrees(showInstances ? 90 : 0))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(instances.isEmpty)
                    .help(instances.isEmpty ? "No running sessions"
                                            : "Show running sessions (working/total)")
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

            if showInstances, let instances, !instances.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(instances) { instance in
                        InstanceRow(instance: instance)
                    }
                }
            }

            ForEach(usage.allLimits) { limit in
                LimitRow(limit: limit)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct InstanceRow: View {
    let instance: InstanceCounter.Instance
    @State private var hovering = false

    var body: some View {
        Button {
            SessionFocuser.focus(instance)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(instance.isWorking ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(shortPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if hovering {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(instance.isWorking ? "working" : "waiting")
                        .font(.caption2)
                        .foregroundStyle(instance.isWorking ? .green : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .help("\(tildePath) — click to focus its terminal")
    }

    private var tildePath: String {
        guard let cwd = instance.cwd else { return "unknown directory" }
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    private var shortPath: String {
        guard let cwd = instance.cwd else { return "pid \(instance.pid)" }
        return cwd.split(separator: "/").suffix(2).joined(separator: "/")
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
