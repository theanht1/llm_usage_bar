import SwiftUI

@main
enum Main {
    static func main() async {
        // Headless verification mode: print what the UI would show, then exit.
        if CommandLine.arguments.contains("--check") {
            let claude = await ClaudeProvider.fetch()
            let codex = CodexProvider.fetch()
            for (name, usage) in [("Claude Code", claude), ("Codex", codex)] {
                print("\(name) (plan: \(usage.plan ?? "?"))")
                if let error = usage.error { print("  error: \(error)") }
                for limit in usage.allLimits {
                    print("  \(limit.label): \(Int(limit.percent.rounded()))% \(limit.timeLeftText)")
                }
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
            Text(store.menuTitle)
                .font(.system(size: 12).monospacedDigit())
        }
        .menuBarExtraStyle(.window)
    }
}
