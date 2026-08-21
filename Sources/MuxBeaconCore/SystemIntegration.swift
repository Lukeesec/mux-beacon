import AppKit
import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunnerError: LocalizedError {
    case timedOut(String)
    public var errorDescription: String? {
        switch self { case .timedOut(let executable): "\(executable) timed out" }
    }
}

public enum ProcessRunner {
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes while the child runs; reading after exit deadlocks
        // once a child fills the 64 KB pipe buffer.
        var stdoutData = Data()
        var stderrData = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        try process.run()
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                readers.wait()
                throw ProcessRunnerError.timedOut(executable)
            }
        } else {
            process.waitUntilExit()
        }
        readers.wait()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public enum TmuxInspector {
    private static let separator = "\u{1f}"

    public static var executable: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func capture(environment: [String: String]) -> TmuxTarget? {
        guard
            let tmux = environment["TMUX"],
            let paneID = environment["TMUX_PANE"],
            let executable
        else { return nil }

        let tmuxParts = tmux.split(separator: ",", omittingEmptySubsequences: false)
        guard let socket = tmuxParts.first.map(String.init), !socket.isEmpty else { return nil }
        let serverPID = tmuxParts.count > 1 ? Int(tmuxParts[1]) : nil
        let format = [
            "#{session_id}", "#{session_name}", "#{window_id}", "#{window_index}",
            "#{window_name}", "#{pane_id}", "#{pane_index}", "#{pane_title}",
            "#{pane_current_path}",
        ].joined(separator: separator)

        guard
            let result = try? ProcessRunner.run(executable, ["-S", socket, "display-message", "-p", "-t", paneID, format]),
            result.status == 0
        else { return nil }

        let fields = result.stdout.components(separatedBy: separator)
        guard fields.count == 9 else { return nil }

        let client = captureClient(executable: executable, socket: socket, paneID: paneID)
        return TmuxTarget(
            socketPath: socket,
            serverPID: serverPID,
            sessionID: fields[0],
            sessionName: fields[1],
            windowID: fields[2],
            windowIndex: Int(fields[3]) ?? 0,
            windowName: fields[4],
            paneID: fields[5],
            paneIndex: Int(fields[6]) ?? 0,
            paneTitle: fields[7],
            panePath: fields[8],
            clientTTY: client?.tty,
            clientPID: client?.pid,
            confidence: client == nil ? .ambiguous : .exact
        )
    }

    public static func paneAvailability(_ target: TmuxTarget) -> TmuxPaneAvailability {
        guard let executable else { return .unknown }
        guard let result = try? ProcessRunner.run(
                executable,
                ["-S", target.socketPath, "display-message", "-p", "-t", target.paneID, "#{pane_id}"],
                timeout: 1
        ) else { return .unknown }
        return result.status == 0 && result.stdout == target.paneID ? .available : .missing
    }

    private static func captureClient(executable: String, socket: String, paneID: String) -> (tty: String, pid: Int)? {
        let format = ["#{client_tty}", "#{client_pid}", "#{client_activity}", "#{pane_id}"]
            .joined(separator: separator)
        guard
            let result = try? ProcessRunner.run(executable, ["-S", socket, "list-clients", "-F", format]),
            result.status == 0
        else { return nil }

        let candidates: [(tty: String, pid: Int, activity: Int)] = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = String(line).components(separatedBy: separator)
                guard fields.count == 4, fields[3] == paneID, let pid = Int(fields[1]) else { return nil }
                return (fields[0], pid, Int(fields[2]) ?? 0)
            }
        return candidates.max(by: { $0.activity < $1.activity }).map { ($0.tty, $0.pid) }
    }
}

public enum TmuxPaneAvailability: Equatable, Sendable {
    case available
    case missing
    case unknown
}


/// Decides whether the user is already looking at the pane an event belongs to.
///
/// Every uncertain path answers `false`. Suppressing an alert the user needed is
/// far worse than showing one they did not, so a missing tmux target, an
/// unreadable client list, or a query that times out all fall through to
/// notifying.
public struct FocusReport: Equatable, Sendable {
    public var watching: Bool
    /// Why, in the words a `focus-status` reader needs.
    public var detail: String

    public init(watching: Bool, detail: String) {
        self.watching = watching
        self.detail = detail
    }
}

public enum FocusInspector {
    private static let separator = "\u{1f}"

    public static func isWatching(_ event: AgentEvent) -> Bool { report(for: event).watching }

    public static func report(for event: AgentEvent) -> FocusReport {
        guard !event.isDemo else { return FocusReport(watching: false, detail: "demo record") }
        guard let target = event.tmux else {
            return FocusReport(watching: false, detail: "captured outside tmux")
        }
        guard let executable = TmuxInspector.executable else {
            return FocusReport(watching: false, detail: "tmux not found")
        }
        guard paneIsOnScreen(target, executable: executable) else {
            return FocusReport(watching: false, detail: "pane is not the active pane of an attached session")
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return FocusReport(watching: false, detail: "no frontmost application")
        }
        guard terminalShowing(target, executable: executable, isFrontmost: frontmost) else {
            let name = frontmost.localizedName ?? "another app"
            return FocusReport(watching: false, detail: "pane is on screen but \(name) is frontmost")
        }

        // One terminal app can own several windows, each showing a different
        // tmux session, so the process chain alone cannot tell them apart. The
        // captured Ghostty terminal disambiguates them when Ghostty answers, and
        // is only ever allowed to veto.
        if let ghostty = event.ghostty,
           frontmost.bundleIdentifier?.lowercased().contains("ghostty") == true,
           let focused = GhosttyInspector.focusedTerminalID(),
           focused != ghostty.terminalID {
            return FocusReport(watching: false, detail: "a different Ghostty terminal is in front")
        }
        return FocusReport(watching: true, detail: "pane is on screen in \(frontmost.localizedName ?? "the frontmost app")")
    }

    /// The pane is the active pane, of the active window, of a session some
    /// client is currently attached to.
    private static func paneIsOnScreen(_ target: TmuxTarget, executable: String) -> Bool {
        let format = ["#{pane_active}", "#{window_active}", "#{session_attached}"]
            .joined(separator: separator)
        guard
            let result = try? ProcessRunner.run(
                executable,
                ["-S", target.socketPath, "display-message", "-p", "-t", target.paneID, format],
                timeout: 1
            ),
            result.status == 0
        else { return false }
        let fields = result.stdout.components(separatedBy: separator)
        guard fields.count == 3 else { return false }
        return fields[0] == "1" && fields[1] == "1" && (Int(fields[2]) ?? 0) > 0
    }

    /// A tmux client attached to the pane's session runs inside the frontmost
    /// application. Walking the client's process chain keeps this working for
    /// any terminal emulator and needs no automation permission.
    private static func terminalShowing(
        _ target: TmuxTarget,
        executable: String,
        isFrontmost frontmost: NSRunningApplication
    ) -> Bool {
        guard
            let result = try? ProcessRunner.run(
                executable,
                [
                    "-S", target.socketPath, "list-clients", "-t", target.sessionID,
                    "-F", ["#{client_pid}", "#{client_flags}"].joined(separator: separator),
                ],
                timeout: 1
            ),
            result.status == 0
        else { return false }

        let clientPIDs = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Int32? in
                let fields = String(line).components(separatedBy: separator)
                guard fields.count == 2 else { return nil }
                // A suspended client still reports as attached but is showing
                // nothing; tmux excludes it from session_attached too.
                guard !fields[1].contains("suspended") else { return nil }
                return Int32(fields[0])
            }
        guard !clientPIDs.isEmpty, let parents = parentProcessMap() else { return false }
        let frontmostPID = frontmost.processIdentifier
        return clientPIDs.contains { descends($0, from: frontmostPID, parents: parents) }
    }

    private static func descends(_ pid: Int32, from ancestor: Int32, parents: [Int32: Int32]) -> Bool {
        var current = pid
        // launchd is pid 1, so the chain is short; the bound only guards cycles.
        for _ in 0..<64 {
            if current == ancestor { return true }
            guard let parent = parents[current], parent > 1 else { return false }
            current = parent
        }
        return false
    }

    private static func parentProcessMap() -> [Int32: Int32]? {
        ProcessTree.snapshot()?.parents
    }
}

/// One `ps` sweep, shared by the callers that need to walk process ancestry.
public struct ProcessTree: Sendable {
    public var parents: [Int32: Int32]
    public var commands: [Int32: String]

    public init(parents: [Int32: Int32], commands: [Int32: String]) {
        self.parents = parents
        self.commands = commands
    }

    public static func snapshot() -> ProcessTree? {
        guard
            let result = try? ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,comm="], timeout: 1),
            result.status == 0
        else { return nil }
        var parents: [Int32: Int32] = [:]
        var commands: [Int32: String] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let fields = String(line).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            parents[pid] = parent
            commands[pid] = String(fields[2])
        }
        return parents.isEmpty ? nil : ProcessTree(parents: parents, commands: commands)
    }

    /// Executable name, with the login shell's leading dash removed.
    public func executableName(of pid: Int32) -> String? {
        guard let command = commands[pid] else { return nil }
        let name = (command as NSString).lastPathComponent
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    public func ancestors(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        // The chain ends at launchd; the bound only guards against cycles.
        for _ in 0..<64 {
            chain.append(current)
            guard let parent = parents[current], parent > 1 else { break }
            current = parent
        }
        return chain
    }
}

/// Agents shell out to other agents. A `claude -p` or `codex exec` started by
/// another agent is that agent's business, not a turn its user is waiting on —
/// and it must never evict the turn that spawned it from its tmux pane.
public enum AgentAncestry {
    /// The hook firing this process already has an agent CLI above it in the
    /// process tree, beyond the one that fired the hook.
    ///
    /// A top-level agent's chain is `hook → shell → claude → shell → tmux`, one
    /// agent. A nested one adds the agent that spawned it, so two or more means
    /// this run belongs to another agent. Any failure answers `false`, leaving
    /// the run to notify as it did before.
    public static func isNestedRun(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        tree: ProcessTree? = ProcessTree.snapshot()
    ) -> Bool {
        guard let tree else { return false }
        let agentNames = Set(AgentSource.allCases.map(\.rawValue))
        let agents = tree.ancestors(of: pid).filter { agentNames.contains(tree.executableName(of: $0) ?? "") }
        return agents.count >= 2
    }
}

public struct EventHealthReport: Equatable, Sendable {
    public var superseded: Int
    public var missingTargets: Int

    public init(superseded: Int, missingTargets: Int) {
        self.superseded = superseded
        self.missingTargets = missingTargets
    }

    public var changed: Int { superseded + missingTargets }
}

public enum EventHealthChecker {
    @discardableResult
    public static func run(store: EventStore = EventStore()) throws -> EventHealthReport {
        let superseded = try store.reconcileSupersededEvents()
        let candidates = try store.fetchEvents(limit: 1_000).filter {
            !$0.isDemo && $0.state != .stale && $0.tmux != nil
        }
        var availability: [String: TmuxPaneAvailability] = [:]
        var missingTargets = 0

        for event in candidates {
            guard let target = event.tmux else { continue }
            let key = "\(target.socketPath)\u{1f}\(target.paneID)"
            let targetAvailability = availability[key] ?? TmuxInspector.paneAvailability(target)
            availability[key] = targetAvailability
            guard targetAvailability == .missing else { continue }
            try store.markStale(id: event.id)
            missingTargets += 1
        }

        return EventHealthReport(superseded: superseded, missingTargets: missingTargets)
    }
}

public enum GhosttyInspector {
    public static func captureFocusedTerminal(environment: [String: String]) -> GhosttyTarget? {
        let terminalProgram = environment["TERM_PROGRAM"]?.lowercased()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIsGhostty = frontmost?.bundleIdentifier?.lowercased().contains("ghostty") == true
            || frontmost?.localizedName?.lowercased() == "ghostty"
        guard terminalProgram == "ghostty", frontmostIsGhostty else { return nil }

        guard let terminalID = focusedTerminalID() else { return nil }
        return GhosttyTarget(terminalID: terminalID)
    }

    /// The terminal Ghostty is showing right now, independent of which app is
    /// frontmost. Returns nil whenever Ghostty cannot be asked.
    public static func focusedTerminalID() -> String? {
        let script = """
        tell application "Ghostty"
            set targetTerminal to focused terminal of selected tab of front window
            return (id of targetTerminal as text)
        end tell
        """
        guard
            let result = try? ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 0.75),
            result.status == 0,
            !result.stdout.isEmpty
        else { return nil }
        return result.stdout
    }

    public static func focus(terminalID: String) throws {
        let escaped = terminalID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
            repeat with targetTerminal in terminals
                if (id of targetTerminal as text) is "\(escaped)" then
                    focus targetTerminal
                    return "focused"
                end if
            end repeat
            error "Mux Beacon could not find the captured Ghostty terminal."
        end tell
        """
        let result = try ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 2)
        guard result.status == 0 else { throw RoutingError.ghostty(result.stderr) }
    }
}

public enum RoutingError: LocalizedError {
    case demo
    case notInTmux
    case ambiguousClient
    case stalePane
    case tmux(String)
    case ghostty(String)

    public var errorDescription: String? {
        switch self {
        case .demo: "Demo records do not point to a live tmux target. Clear them with mux-beacon clear-demo."
        case .notInTmux: "This event was not captured inside tmux."
        case .ambiguousClient: "Mux Beacon could not identify the originating tmux client."
        case .stalePane: "The captured tmux pane no longer exists."
        case .tmux(let detail): "tmux could not open this target: \(detail)"
        case .ghostty(let detail): "Ghostty could not focus this terminal: \(detail)"
        }
    }
}

public enum TargetRouter {
    public static func jump(to event: AgentEvent) throws {
        guard !event.isDemo else { throw RoutingError.demo }
        guard let target = event.tmux else { throw RoutingError.notInTmux }
        guard let executable = TmuxInspector.executable else { throw RoutingError.tmux("tmux is not installed") }
        guard let clientTTY = target.clientTTY, !clientTTY.isEmpty else { throw RoutingError.ambiguousClient }

        let check = try ProcessRunner.run(
            executable,
            ["-S", target.socketPath, "display-message", "-p", "-t", target.paneID, "#{pane_id}"]
        )
        guard check.status == 0, check.stdout == target.paneID else { throw RoutingError.stalePane }

        if let ghostty = event.ghostty {
            try GhosttyInspector.focus(terminalID: ghostty.terminalID)
        }

        let switched = try ProcessRunner.run(
            executable,
            ["-S", target.socketPath, "switch-client", "-c", clientTTY, "-t", target.paneID]
        )
        guard switched.status == 0 else { throw RoutingError.tmux(switched.stderr) }

        if event.ghostty == nil {
            _ = try? ProcessRunner.run("/usr/bin/open", ["-a", "Ghostty"])
        }

        _ = try? ProcessRunner.run(
            executable,
            ["-S", target.socketPath, "display-message", "-c", clientTTY, "-d", "900", "Mux Beacon → \(target.displayPath)"]
        )
    }
}
