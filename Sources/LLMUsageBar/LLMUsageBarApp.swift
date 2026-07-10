import SwiftUI

@main
enum Main {
    static func main() async {
        // Headless verification mode: print what the UI would show, then exit.
        if CommandLine.arguments.contains("--check") {
            let claude = await ClaudeProvider.fetch()
            let codex = CodexProvider.fetch()
            let scan = InstanceCounter.scan()
            for (name, usage, instances) in [
                ("Claude Code", claude, scan?.claude),
                ("Codex", codex, scan?.codex),
            ] {
                print("\(name) (plan: \(usage.plan ?? "?"))")
                if let error = usage.error { print("  error: \(error)") }
                if let instances {
                    print("  Running: \(instances.count)")
                    for instance in instances {
                        let status = instance.isWorking ? "working" : "waiting"
                        print("    \(status)  \(instance.cwd ?? "?")  (pid \(instance.pid), tty \(instance.tty ?? "-"))")
                    }
                }
                for limit in usage.allLimits {
                    print("  \(limit.label): \(Int(limit.percent.rounded()))% \(limit.timeLeftText)")
                }
            }
            return
        }

        // Headless focus verification: --focus <pid> runs the click action.
        if let index = CommandLine.arguments.firstIndex(of: "--focus"),
           let pid = CommandLine.arguments.dropFirst(index + 1).first.flatMap({ Int32($0) }) {
            guard let instance = InstanceCounter.scan()?.all.first(where: { $0.pid == pid }) else {
                print("no running instance with pid \(pid)")
                return
            }
            for step in SessionFocuser.performFocus(pid: instance.pid, tty: instance.tty) {
                print(step)
            }
            return
        }
        LLMUsageBarApp.main()
    }
}

struct LLMUsageBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            DetailsView(store: store)
        } label: {
            store.menuLabel
        }
        .menuBarExtraStyle(.window)
    }
}
