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
        return GhosttyTarget(terminalID: result.stdout)
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
