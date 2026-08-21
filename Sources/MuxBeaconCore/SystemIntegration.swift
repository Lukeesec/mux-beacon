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
        liveClients(executable: executable, socket: socket)
            .filter { $0.paneID == paneID }
            .max(by: { $0.activity < $1.activity })
            .map { ($0.tty, $0.pid) }
    }

    public struct LiveClient: Equatable, Sendable {
        public var tty: String
        public var pid: Int
        public var activity: Int
        public var sessionName: String
        public var paneID: String
    }

    /// Clients that are actually displaying something. A suspended client still
    /// reports as attached and keeps its last activity timestamp, so it can win
    /// a most-recently-active comparison while showing the user nothing.
    public static func liveClients(executable: String, socket: String) -> [LiveClient] {
        let format = [
            "#{client_tty}", "#{client_pid}", "#{client_activity}",
            "#{client_session}", "#{pane_id}", "#{client_flags}",
        ].joined(separator: separator)
        guard
            let result = try? ProcessRunner.run(executable, ["-S", socket, "list-clients", "-F", format], timeout: 2),
            result.status == 0
        else { return [] }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = String(line).components(separatedBy: separator)
                guard fields.count == 6, let pid = Int(fields[1]) else { return nil }
                guard !fields[5].contains("suspended") else { return nil }
                return LiveClient(
                    tty: fields[0], pid: pid, activity: Int(fields[2]) ?? 0,
                    sessionName: fields[3], paneID: fields[4]
                )
            }
    }

    /// Confirms a client is now showing the pane. `switch-client` reports success
    /// for a client that is not displaying anything, so the jump has to look.
    public static func isPaneOnScreen(_ target: TmuxTarget, executable: String) -> Bool {
        liveClients(executable: executable, socket: target.socketPath).contains { $0.paneID == target.paneID }
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

    private static func terminalShowing(
        _ target: TmuxTarget,
        executable: String,
        isFrontmost frontmost: NSRunningApplication
    ) -> Bool {
        let pids = TmuxInspector.liveClients(executable: executable, socket: target.socketPath)
            .filter { $0.sessionName == target.sessionName }
            .map { Int32($0.pid) }
        return TerminalOwnership.anyProcess(pids, belongsTo: frontmost)
    }
}

/// Which application a terminal session is running inside.
///
/// Walking the tmux client's process chain answers this for any emulator and
/// needs no automation permission, and unlike `TERM_PROGRAM` it survives tmux —
/// tmux overwrites `TERM_PROGRAM` with its own name inside every pane, so an
/// environment check can never see the real terminal from within a session.
public enum TerminalOwnership {
    public static func anyProcess(
        _ pids: [Int32],
        belongsTo ownerPID: Int32,
        tree: ProcessTree? = ProcessTree.snapshot()
    ) -> Bool {
        guard !pids.isEmpty, let tree else { return false }
        return pids.contains { tree.ancestors(of: $0).contains(ownerPID) }
    }

    public static func anyProcess(
        _ pids: [Int32],
        belongsTo application: NSRunningApplication,
        tree: ProcessTree? = ProcessTree.snapshot()
    ) -> Bool {
        anyProcess(pids, belongsTo: application.processIdentifier, tree: tree)
    }

    /// The application hosting a live client for this target, if one is running.
    public static func owningApplication(of target: TmuxTarget, executable: String) -> NSRunningApplication? {
        let clients = TmuxInspector.liveClients(executable: executable, socket: target.socketPath)
        guard !clients.isEmpty, let tree = ProcessTree.snapshot() else { return nil }
        let running = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        // Prefer a client already on the target's session, then any live client.
        let ordered = clients.sorted { lhs, rhs in
            (lhs.sessionName == target.sessionName ? 0 : 1) < (rhs.sessionName == target.sessionName ? 0 : 1)
        }
        for client in ordered {
            for ancestor in tree.ancestors(of: Int32(client.pid)) {
                if let application = byPID[ancestor] { return application }
            }
        }
        return nil
    }
}

/// Brings a terminal to the front and keeps it there.
///
/// Clicking a notification makes macOS activate Mux Beacon, which owns no
/// window, and that activation can land *after* ours — leaving the user staring
/// at the app they came from while the tmux switch has already happened
/// invisibly. Asserting the terminal repeatedly until it actually holds the
/// front settles the race in the terminal's favour.
public enum TerminalActivator {
    @discardableResult
    public static func bringToFront(_ application: NSRunningApplication, attempts: Int = 4) -> Bool {
        for attempt in 0..<max(1, attempts) {
            application.activate(options: [.activateAllWindows])
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.08 : 0.15)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return true
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
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
    public static func isGhostty(_ application: NSRunningApplication?) -> Bool {
        application?.bundleIdentifier?.lowercased().contains("ghostty") == true
            || application?.localizedName?.lowercased() == "ghostty"
    }

    public static func captureFocusedTerminal(
        environment: [String: String],
        tmux: TmuxTarget? = nil
    ) -> GhosttyTarget? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard isGhostty(frontmost), let frontmost else { return nil }

        // Inside tmux, TERM_PROGRAM reads "tmux" no matter which emulator is
        // hosting the session, so the pane's own client has to vouch for it.
        if let tmux, let executable = TmuxInspector.executable {
            let pids = TmuxInspector.liveClients(executable: executable, socket: tmux.socketPath)
                .filter { $0.paneID == tmux.paneID }
                .map { Int32($0.pid) }
            guard TerminalOwnership.anyProcess(pids, belongsTo: frontmost) else { return nil }
        } else {
            guard environment["TERM_PROGRAM"]?.lowercased() == "ghostty" else { return nil }
        }

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
    case switchNotVisible
    case tmux(String)
    case ghostty(String)

    public var errorDescription: String? {
        switch self {
        case .demo: "Demo records do not point to a live tmux target. Clear them with mux-beacon clear-demo."
        case .notInTmux: "This event was not captured inside tmux."
        case .ambiguousClient: "Mux Beacon could not identify the originating tmux client."
        case .stalePane: "The captured tmux pane no longer exists."
        case .switchNotVisible: "tmux accepted the switch but no attached client is showing the pane."
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

        let check = try ProcessRunner.run(
            executable,
            ["-S", target.socketPath, "display-message", "-p", "-t", target.paneID, "#{pane_id}"]
        )
        guard check.status == 0, check.stdout == target.paneID else { throw RoutingError.stalePane }

        // The stored client can be gone, suspended, or sharing its tty name with
        // clients that are; what matters is a client that is displaying now.
        let clients = TmuxInspector.liveClients(executable: executable, socket: target.socketPath)
        guard !clients.isEmpty else { throw RoutingError.ambiguousClient }
        let preferred = clients.first { $0.tty == target.clientTTY }
            ?? clients.first { $0.sessionName == target.sessionName }
            ?? clients[0]

        let switched = try ProcessRunner.run(
            executable,
            ["-S", target.socketPath, "switch-client", "-c", preferred.tty, "-t", target.paneID]
        )
        guard switched.status == 0 else { throw RoutingError.tmux(switched.stderr) }
        // switch-client reports success even when it moved a client that shows
        // the user nothing, so confirm the pane really is on screen now.
        guard TmuxInspector.isPaneOnScreen(target, executable: executable) else {
            throw RoutingError.switchNotVisible
        }

        try focusTerminal(for: event, target: target, executable: executable)

        _ = try? ProcessRunner.run(
            executable,
            ["-S", target.socketPath, "display-message", "-c", preferred.tty, "-d", "900", "Mux Beacon → \(target.displayPath)"]
        )
    }

    /// Puts the terminal in front, whatever the user was looking at.
    private static func focusTerminal(for event: AgentEvent, target: TmuxTarget, executable: String) throws {
        let owner = TerminalOwnership.owningApplication(of: target, executable: executable)

        // Ghostty can raise one specific window and tab; every other emulator
        // gets app-level activation, which is all tmux needs anyway.
        if let ghostty = event.ghostty, GhosttyInspector.isGhostty(owner) || owner == nil {
            do {
                try GhosttyInspector.focus(terminalID: ghostty.terminalID)
            } catch {
                BeaconLog.write("ghostty focus fell back to app activation: \(error.localizedDescription)")
            }
        }

        if let owner {
            if !TerminalActivator.bringToFront(owner) {
                BeaconLog.write("terminal did not take focus: \(owner.localizedName ?? "unknown")")
            }
            return
        }
        let opened = try? ProcessRunner.run("/usr/bin/open", ["-a", "Ghostty"], timeout: 3)
        if opened?.status != 0 {
            BeaconLog.write("could not activate a terminal for \(target.displayPath)")
        }
    }
}
