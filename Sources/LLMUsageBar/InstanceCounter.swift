import Foundation

/// Finds running Claude Code and Codex sessions by scanning the process table.
enum InstanceCounter {
    struct Instance: Identifiable, Sendable {
        let pid: Int32
        /// Controlling terminal, e.g. "ttys049". Nil for daemonized processes.
        let tty: String?
        let cwd: String?
        /// True when the session's process subtree is burning CPU (streaming,
        /// running a tool); false ≈ waiting for user input.
        let isWorking: Bool

        var id: Int32 { pid }
    }

    struct Scan: Sendable {
        var claude: [Instance] = []
        var codex: [Instance] = []

        var all: [Instance] { claude + codex }
    }

    private struct ProcEntry {
        let pid: Int32
        let ppid: Int32
        let cpu: Double
        let tty: String?
        let args: [String]
    }

    /// Helper invocations of the `claude` binary that aren't user sessions.
    private static let claudeHelperSubcommands: Set<String> = ["daemon", "bg-pty-host", "bg-spare"]
    /// Summed subtree %cpu (a decaying average from `ps`) above this means
    /// the session is actively working rather than waiting for input.
    private static let workingCPUThreshold = 2.0

    static func scan() -> Scan? {
        guard let table = processTable() else { return nil }

        var children: [Int32: [Int32]] = [:]
        for entry in table.values {
            children[entry.ppid, default: []].append(entry.pid)
        }

        var claudePids: [Int32] = []
        var codexPids: [Int32] = []
        for entry in table.values {
            guard let executable = entry.args.first else { continue }
            switch (executable as NSString).lastPathComponent {
            case "claude" where isClaudeSession(entry.args):
                claudePids.append(entry.pid)
            case "codex":
                codexPids.append(entry.pid)
            default:
                break
            }
        }

        let cwds = workingDirectories(pids: claudePids + codexPids)
        func instance(_ pid: Int32) -> Instance {
            Instance(
                pid: pid,
                tty: table[pid]?.tty,
                cwd: cwds[pid],
                isWorking: subtreeCPU(of: pid, table: table, children: children) >= workingCPUThreshold
            )
        }
        func ordered(_ pids: [Int32]) -> [Instance] {
            pids.map(instance).sorted {
                if $0.isWorking != $1.isWorking { return $0.isWorking }
                if $0.cwd != $1.cwd { return ($0.cwd ?? "~") < ($1.cwd ?? "~") }
                return $0.pid < $1.pid
            }
        }
        return Scan(claude: ordered(claudePids), codex: ordered(codexPids))
    }

    private static func isClaudeSession(_ tokens: [String]) -> Bool {
        if tokens.count > 1, claudeHelperSubcommands.contains(tokens[1]) { return false }
        if tokens.contains("--bg-pty-host") || tokens.contains("--bg-spare") { return false }
        return true
    }

    private static func subtreeCPU(of pid: Int32, table: [Int32: ProcEntry], children: [Int32: [Int32]]) -> Double {
        var total = 0.0
        var stack = [pid]
        while let current = stack.popLast() {
            total += table[current]?.cpu ?? 0
            stack.append(contentsOf: children[current] ?? [])
        }
        return total
    }

    private static func processTable() -> [Int32: ProcEntry]? {
        guard let output = run("/bin/ps", ["axwwo", "pid=,ppid=,pcpu=,tty=,args="]) else { return nil }
        var table: [Int32: ProcEntry] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let cpu = Double(fields[2])
            else { continue }
            let tty = fields[3] == "??" ? nil : String(fields[3])
            table[pid] = ProcEntry(pid: pid, ppid: ppid, cpu: cpu, tty: tty,
                                   args: fields[4...].map(String.init))
        }
        return table
    }

    private static func workingDirectories(pids: [Int32]) -> [Int32: String] {
        // lsof exits non-zero when any listed pid has already exited but
        // still prints the rest, so don't require success here.
        guard !pids.isEmpty,
              let output = run("/usr/sbin/lsof", [
                  "-a", "-d", "cwd", "-Fn",
                  "-p", pids.map(String.init).joined(separator: ","),
              ], requireSuccess: false)
        else { return [:] }
        var cwds: [Int32: String] = [:]
        var currentPid: Int32?
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": currentPid = Int32(line.dropFirst())
            case "n":
                if let pid = currentPid { cwds[pid] = String(line.dropFirst()) }
            default: break
            }
        }
        return cwds
    }

    static func run(_ path: String, _ arguments: [String], requireSuccess: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if requireSuccess, process.terminationStatus != 0 { return nil }
        return String(data: data, encoding: .utf8)
    }
}
