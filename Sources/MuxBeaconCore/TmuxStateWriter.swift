import Foundation

public enum TmuxStateWriter {
    public static let badgeFormat = "#{?#{==:#{@mux_beacon_state},ready},#[fg=green]#[bold]● READY ,#{?#{==:#{@mux_beacon_state},working},#[fg=blue]#[bold]● WORKING ,#{?#{==:#{@mux_beacon_state},needsAttention},#[fg=yellow]#[bold]● ATTENTION ,#{?#{==:#{@mux_beacon_state},failed},#[fg=red]#[bold]● FAILED ,}}}}#[default]#{pane_title} #[dim]#{pane_index}"

    public struct BadgeStatus: Sendable {
        public var enabled: Bool
        public var socket: String
        public var panesWithState: Int
    }
    private struct BorderBackup: Codable {
        var socket: String
        var status: String
        var format: String
    }

    private static var backupURL: URL { BeaconPaths.home.appendingPathComponent("tmux-border-backup.json") }

    public static func update(_ event: AgentEvent) {
        guard let target = event.tmux, let executable = TmuxInspector.executable else { return }
        let values = [
            ("@mux_beacon_state", event.acknowledged ? "" : event.state.rawValue),
            ("@mux_beacon_source", event.source.displayName),
            ("@mux_beacon_event_id", event.id),
            ("@mux_beacon_project", event.projectName),
        ]
        for (name, value) in values {
            _ = try? ProcessRunner.run(
                executable,
                ["-S", target.socketPath, "set-option", "-p", "-t", target.paneID, name, value]
            )
        }
        _ = try? ProcessRunner.run(executable, ["-S", target.socketPath, "refresh-client", "-S"])
    }

    public static func openPopup(binaryPath: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["TMUX"], let socket = raw.split(separator: ",").first.map(String.init) else {
            throw RoutingError.notInTmux
        }
        guard let executable = TmuxInspector.executable else { throw RoutingError.tmux("tmux is not installed") }
        let command = shellQuote(binaryPath) + " tui"
        let result = try ProcessRunner.run(
            executable,
            ["-S", socket, "display-popup", "-E", "-w", "86%", "-h", "72%", command]
        )
        guard result.status == 0 else { throw RoutingError.tmux(result.stderr) }
    }

    public static func enableBadges() throws {
        let socket = try currentSocket()
        guard let executable = TmuxInspector.executable else { throw RoutingError.tmux("tmux is not installed") }
        let oldStatus = try option(executable, socket, "pane-border-status")
        let oldFormat = try option(executable, socket, "pane-border-format")
        try BeaconPaths.ensureDirectories()
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let existing = try JSONDecoder().decode(BorderBackup.self, from: Data(contentsOf: backupURL))
            guard existing.socket == socket else {
                throw RoutingError.tmux("pane-border settings are already saved for another tmux server; restore those first")
            }
        } else {
            let backup = BorderBackup(socket: socket, status: oldStatus, format: oldFormat)
            let data = try JSONEncoder().encode(backup)
            try data.write(to: backupURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }

        try require(ProcessRunner.run(executable, ["-S", socket, "set-option", "-g", "pane-border-status", "top"]))
        try require(ProcessRunner.run(executable, ["-S", socket, "set-option", "-g", "pane-border-format", badgeFormat]))
        _ = try? ProcessRunner.run(executable, ["-S", socket, "refresh-client", "-S"])
    }

    public static func badgeStatus() throws -> BadgeStatus {
        let socket = try currentSocket()
        guard let executable = TmuxInspector.executable else { throw RoutingError.tmux("tmux is not installed") }
        let status = try option(executable, socket, "pane-border-status")
        let format = try option(executable, socket, "pane-border-format")
        let panes = try ProcessRunner.run(
            executable,
            ["-S", socket, "list-panes", "-a", "-F", "#{@mux_beacon_state}"]
        )
        try require(panes)
        let panesWithState = panes.stdout.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
        return BadgeStatus(
            enabled: status != "off" && format.contains("@mux_beacon_state"),
            socket: socket,
            panesWithState: panesWithState
        )
    }

    public static func disableBadges() throws {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw RoutingError.tmux("no saved pane-border settings were found")
        }
        let backup = try JSONDecoder().decode(BorderBackup.self, from: Data(contentsOf: backupURL))
        guard let executable = TmuxInspector.executable else { throw RoutingError.tmux("tmux is not installed") }
        try require(ProcessRunner.run(executable, ["-S", backup.socket, "set-option", "-g", "pane-border-status", backup.status]))
        try require(ProcessRunner.run(executable, ["-S", backup.socket, "set-option", "-g", "pane-border-format", backup.format]))
        _ = try? ProcessRunner.run(executable, ["-S", backup.socket, "refresh-client", "-S"])
        try FileManager.default.removeItem(at: backupURL)
    }

    private static func currentSocket() throws -> String {
        guard let raw = ProcessInfo.processInfo.environment["TMUX"], let socket = raw.split(separator: ",").first else {
            throw RoutingError.notInTmux
        }
        return String(socket)
    }

    private static func option(_ executable: String, _ socket: String, _ name: String) throws -> String {
        let result = try ProcessRunner.run(executable, ["-S", socket, "show-options", "-gv", name])
        try require(result)
        return result.stdout
    }

    private static func require(_ result: CommandResult) throws {
        guard result.status == 0 else { throw RoutingError.tmux(result.stderr) }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
