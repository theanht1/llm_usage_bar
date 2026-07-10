import AppKit

/// Brings the terminal hosting a session to the front.
///
/// Three tiers, best-effort at every step:
/// 1. tmux panes — exact pane via `select-window`/`select-pane`/`switch-client`,
///    then the hosting app of the tmux *client* is focused instead.
/// 2. iTerm2 / Terminal.app — exact tab selected via AppleScript by tty
///    (triggers the one-time macOS Automation consent prompt).
/// 3. Any other GUI app (Ghostty, Cursor, …) — app activation only.
enum SessionFocuser {
    static func focus(_ instance: InstanceCounter.Instance) {
        Task.detached { _ = performFocus(pid: instance.pid, tty: instance.tty) }
    }

    /// Returns a step-by-step description for `--focus` verification.
    static func performFocus(pid: Int32, tty: String?) -> [String] {
        var steps: [String] = []
        // The tty a terminal emulator actually displays: the session's own,
        // or — once tmux is in between — the attached tmux client's.
        var terminalTTY = tty.map { "/dev/\($0)" }
        var ancestryStart = pid

        if let sessionTTY = terminalTTY, let pane = tmuxPane(forTTY: sessionTTY) {
            steps.append("tmux pane \(pane.paneID) (window \(pane.windowID), session \(pane.sessionName))")
            _ = tmux(["select-window", "-t", pane.windowID])
            _ = tmux(["select-pane", "-t", pane.paneID])
            if let client = mostRecentTmuxClient() {
                _ = tmux(["switch-client", "-c", client, "-t", pane.sessionID])
                steps.append("switched tmux client \(client)")
                terminalTTY = client
                if let clientPid = processID(withTTY: client) { ancestryStart = clientPid }
            }
        }

        guard let app = ancestorApplication(of: ancestryStart) else {
            steps.append("no hosting app found")
            return steps
        }
        if let script = tabSelectionScript(bundleID: app.bundleIdentifier, tty: terminalTTY) {
            let selected = InstanceCounter.run("/usr/bin/osascript", ["-e", script]) != nil
            steps.append(selected ? "selected \(app.localizedName ?? "?") tab \(terminalTTY ?? "?")"
                                  : "tab selection failed (Automation permission?)")
        }
        app.activate()
        steps.append("activated \(app.localizedName ?? app.bundleIdentifier ?? "app")")
        return steps
    }

    // MARK: - tmux

    private static var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func tmux(_ arguments: [String]) -> String? {
        guard let path = tmuxPath else { return nil }
        return InstanceCounter.run(path, arguments)
    }

    private struct TmuxPane {
        let sessionID: String
        let sessionName: String
        let windowID: String
        let paneID: String
    }

    private static func tmuxPane(forTTY tty: String) -> TmuxPane? {
        guard let output = tmux(["list-panes", "-a", "-F",
                                 "#{pane_tty}\t#{session_id}\t#{session_name}\t#{window_id}\t#{pane_id}"])
        else { return nil }
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 5, fields[0] == tty else { continue }
            return TmuxPane(sessionID: fields[1], sessionName: fields[2],
                            windowID: fields[3], paneID: fields[4])
        }
        return nil
    }

    /// The tty of the most recently active attached tmux client.
    private static func mostRecentTmuxClient() -> String? {
        guard let output = tmux(["list-clients", "-F", "#{client_activity}\t#{client_tty}"]) else { return nil }
        return output.split(separator: "\n")
            .compactMap { line -> (activity: Int, tty: String)? in
                let fields = line.split(separator: "\t").map(String.init)
                guard fields.count == 2, let activity = Int(fields[0]) else { return nil }
                return (activity, fields[1])
            }
            .max { $0.activity < $1.activity }?.tty
    }

    // MARK: - Hosting app

    /// The pid attached to a tty (preferring the tmux client process itself).
    private static func processID(withTTY tty: String) -> Int32? {
        guard let output = InstanceCounter.run("/bin/ps", ["axwwo", "pid=,tty=,args="]) else { return nil }
        let shortTTY = tty.replacingOccurrences(of: "/dev/", with: "")
        var fallback: Int32?
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, fields[1] == shortTTY, let pid = Int32(fields[0]) else { continue }
            if (String(fields[2]) as NSString).lastPathComponent == "tmux" { return pid }
            fallback = fallback ?? pid
        }
        return fallback
    }

    /// Walks the parent chain until a regular GUI application is found.
    private static func ancestorApplication(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<20 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return app
            }
            guard let ppid = InstanceCounter.run("/bin/ps", ["-o", "ppid=", "-p", String(current)])
                .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                ppid > 1
            else { return nil }
            current = ppid
        }
        return nil
    }

    // MARK: - AppleScript tab selection

    private static func tabSelectionScript(bundleID: String?, tty: String?) -> String? {
        guard let tty else { return nil }
        switch bundleID {
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            return nil
        }
    }
}
