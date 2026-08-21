import Foundation
import MuxBeaconCore

@main
struct MuxBeaconCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        do {
            switch command {
            case "relay":
                try relay(Array(arguments.dropFirst()))
            case "codex-notify":
                try codexNotify(Array(arguments.dropFirst()))
            case "install":
                try install(Array(arguments.dropFirst()), uninstall: false)
            case "uninstall":
                try install(Array(arguments.dropFirst()), uninstall: true)
            case "doctor":
                try doctor()
            case "status":
                try status()
            case "health":
                try health()
            case "test":
                try test(Array(arguments.dropFirst()))
            case "demo":
                try demo()
            case "clear-demo":
                try EventStore().deleteDemoEvents()
                EventBroadcaster.post(eventID: "")
                print("Removed demo events.")
            case "jump", "jump-last":
                try jump(command == "jump" ? arguments.dropFirst().first : nil)
            case "acknowledge", "ack":
                try mutate(arguments, logged: false)
            case "mark-logged", "log":
                try mutate(arguments, logged: true)
            case "export":
                try export(Array(arguments.dropFirst()))
            case "tmux":
                try tmux(Array(arguments.dropFirst()))
            case "notifications", "notification":
                try notifications(Array(arguments.dropFirst()))
            case "gui", "open":
                try AppLauncher.openGUI()
            case "tui":
                try tui()
            case "help", "--help", "-h":
                printHelp()
            case "version", "--version", "-v":
                print("mux-beacon \(BeaconVersion.current)")
            default:
                throw CLIError.usage("Unknown command: \(command)")
            }
        } catch {
            if command == "relay" || command == "codex-notify" {
                BeaconLog.write("\(command) error: \(error.localizedDescription)")
                exit(0)
            }
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func relay(_ arguments: [String]) throws {
        guard
            let sourceValue = option("--source", in: arguments),
            let source = AgentSource(rawValue: sourceValue)
        else { throw CLIError.usage("relay requires --source claude|codex") }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let incoming = try HookNormalizer.parse(source: source, data: input)
        try deliver(incoming)
        if source == .codex, incoming.hookEventName == "Stop" {
            FileHandle.standardOutput.write(Data("{}\n".utf8))
        }
    }

    private static func codexNotify(_ arguments: [String]) throws {
        guard let payload = arguments.last else { throw CLIError.usage("codex-notify requires Codex's JSON payload") }
        let incoming = try HookNormalizer.parseCodexNotification(data: Data(payload.utf8))
        try deliver(incoming)
        HookReceiptWriter.recordCodexCompletion(at: incoming.timestamp)
    }

    private static func deliver(_ incoming: IncomingAgentEvent) throws {
        let store = EventStore()
        if incoming.hookEventName == "SessionEnd",
           try store.activeEvent(source: incoming.source, sessionID: incoming.sessionID) == nil {
            HookReceiptWriter.record(source: incoming.source, eventName: incoming.hookEventName, at: incoming.timestamp)
            return
        }
        let event = try store.record(incoming, storePreview: BeaconPreferences.shared.storePreviews)
        HookReceiptWriter.record(source: incoming.source, eventName: incoming.hookEventName, at: incoming.timestamp)
        TmuxStateWriter.update(event)
        AppLauncher.launchIfAvailable()
        EventBroadcaster.post(eventID: event.id)
    }

    private static func install(_ arguments: [String], uninstall: Bool) throws {
        let apply = arguments.contains("--apply")
        let installer = ConfigInstaller(binaryPath: executablePath())
        let includePermissionEvents = arguments.contains("--with-permission-events")
        let report = try uninstall
            ? installer.uninstall(apply: apply)
            : installer.install(apply: apply, includePermissionEvents: includePermissionEvents)
        print(report.applied ? "Applied Mux Beacon hook configuration." : "Dry run only; pass --apply to write changes.")
        for change in report.changes {
            let verb = uninstall ? "remove" : "add"
            let events = change.eventsAdded.isEmpty ? "no changes" : "\(verb): \(change.eventsAdded.joined(separator: ", "))"
            print("  \(change.path): \(events)")
        }
        for backup in report.backups { print("  backup: \(backup)") }
        for warning in report.warnings { print("  warning: \(warning)") }
        if !uninstall, apply {
            print("\nCodex: open /hooks once and trust the new Mux Beacon hooks.")
            print("No tmux restart is required.")
        }
    }

    private static func doctor() throws {
        print("Mux Beacon doctor")
        print("  data: \(BeaconPaths.home.path)")
        print("  tmux: \(TmuxInspector.executable ?? "not found")")
        let ghostty = ["/Applications/Ghostty.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ghostty.app").path]
            .first { FileManager.default.fileExists(atPath: $0) }
        print("  Ghostty: \(ghostty ?? "not found")")
        let notificationStatus = (try? String(contentsOf: BeaconPaths.notificationStatus).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown (launch the app once)"
        print("  notifications: \(notificationStatus)")
        let installer = ConfigInstaller(binaryPath: executablePath())
        for (source, installed, path) in installer.status() {
            print("  \(source.displayName) hook: \(installed ? "installed" : "not installed") (\(path))")
            print("    last received: \(hookReceipt(source: source))")
        }
        let notifyStatus: String
        switch installer.codexNotifyStatus() {
        case .installed: notifyStatus = "installed"
        case .chained: notifyStatus = "installed (forwarded by another command)"
        case .available: notifyStatus = "not installed"
        case .occupied: notifyStatus = "another command is configured"
        case .needsRepair: notifyStatus = "needs reinstall"
        }
        print("  Codex completion callback: \(notifyStatus) (\(installer.codexConfig.path))")
        print("    last received: \(completionReceipt())")
        let count = try EventStore().fetchEvents().count
        print("  stored events: \(count)")
    }

    private static func status() throws {
        let events = try EventStore().fetchEvents(limit: 30)
        guard !events.isEmpty else {
            print("No agent events yet. Try: mux-beacon demo")
            return
        }
        for event in events {
            let unread = event.acknowledged ? " " : "•"
            print("\(unread) \(event.source.displayName.padding(toLength: 7, withPad: " ", startingAt: 0)) \(event.state.displayName.padding(toLength: 16, withPad: " ", startingAt: 0)) \(event.durationLabel.padding(toLength: 8, withPad: " ", startingAt: 0)) \(event.projectName) — \(event.routeLabel)")
        }
    }

    private static func hookReceipt(source: AgentSource) -> String {
        guard
            let value = try? String(contentsOf: BeaconPaths.hookReceipt(source: source), encoding: .utf8),
            !value.isEmpty
        else { return "never" }
        let fields = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 1)
        guard fields.count == 2 else { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "\(fields[1]) at \(fields[0])"
    }

    private static func completionReceipt() -> String {
        guard let value = try? String(contentsOf: BeaconPaths.codexCompletionReceipt, encoding: .utf8) else {
            return "never"
        }
        let date = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return date.isEmpty ? "never" : date
    }

    private static func health() throws {
        let report = try EventHealthChecker.run()
        EventBroadcaster.post(eventID: "")
        if report.changed == 0 {
            print("Session health check complete. No stale records found.")
        } else {
            print("Session health check complete. Retired \(report.changed) record\(report.changed == 1 ? "" : "s") (\(report.superseded) superseded, \(report.missingTargets) missing tmux targets).")
        }
    }

    private static func test(_ arguments: [String]) throws {
        let stateName = arguments.first ?? "start"
        let source = AgentSource(rawValue: option("--source", in: arguments) ?? "codex") ?? .codex
        let state: AgentState
        let hook: String
        switch stateName {
        case "start", "working": (state, hook) = (.working, "UserPromptSubmit")
        case "ready", "done": (state, hook) = (.ready, "Stop")
        case "attention": (state, hook) = (.needsAttention, "PermissionRequest")
        case "failed": (state, hook) = (.failed, "StopFailure")
        default: throw CLIError.usage("test state must be start, ready, attention, or failed")
        }
        let testID = UUID().uuidString
        let sessionID = "mux-beacon-test-\(testID)"
        let store = EventStore()
        if state != .working {
            // Untracked completions record quietly, so give the synthetic
            // terminal event a tracked start it can merge into.
            _ = try store.record(IncomingAgentEvent(
                source: source,
                sessionID: sessionID,
                turnID: testID,
                hookEventName: "UserPromptSubmit",
                cwd: FileManager.default.currentDirectoryPath,
                model: "test-model",
                state: .working,
                timestamp: Date().addingTimeInterval(-75),
                preview: "Synthetic Mux Beacon test event"
            ))
        }
        let incoming = IncomingAgentEvent(
            source: source,
            sessionID: sessionID,
            turnID: testID,
            hookEventName: hook,
            cwd: FileManager.default.currentDirectoryPath,
            model: "test-model",
            state: state,
            timestamp: Date(),
            preview: "Synthetic Mux Beacon test event",
            tmux: TmuxInspector.capture(environment: ProcessInfo.processInfo.environment),
            ghostty: hook == "UserPromptSubmit" ? GhosttyInspector.captureFocusedTerminal(environment: ProcessInfo.processInfo.environment) : nil
        )
        let event = try store.record(incoming)
        TmuxStateWriter.update(event)
        AppLauncher.launchIfAvailable()
        EventBroadcaster.post(eventID: event.id)
        print("Created \(event.source.displayName) \(event.state.displayName.lowercased()) event: \(event.id)")
    }

    private static func demo() throws {
        let events = try DemoSeeder.seed(store: EventStore())
        AppLauncher.launchIfAvailable()
        for event in events { EventBroadcaster.post(eventID: event.id) }
        print("Seeded \(events.count) anonymized demo events.")
    }

    private static func jump(_ id: String?) throws {
        let store = EventStore()
        let event = try id.flatMap { try store.fetch(id: $0) } ?? store.latestActionable()
        guard let event else { throw CLIError.usage("No matching actionable event.") }
        try TargetRouter.jump(to: event)
        try store.acknowledge(id: event.id)
        EventBroadcaster.post(eventID: event.id)
    }

    private static func mutate(_ arguments: [String], logged: Bool) throws {
        guard arguments.count > 1 else { throw CLIError.usage("This command requires an event ID.") }
        let id = arguments[1]
        let store = EventStore()
        if logged { try store.markLogged(id: id) }
        else { try store.acknowledge(id: id) }
        EventBroadcaster.post(eventID: id)
    }

    private static func export(_ arguments: [String]) throws {
        let format = option("--format", in: arguments) ?? "json"
        let entries = try EventStore().timeEntries(includeLogged: true)
        let data: Data
        switch format {
        case "json": data = try TimeEntryExporter.json(entries)
        case "csv": data = TimeEntryExporter.csv(entries)
        default: throw CLIError.usage("export --format must be json or csv")
        }
        if let path = option("--output", in: arguments) {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("Exported \(entries.count) records to \(path)")
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func tmux(_ arguments: [String]) throws {
        switch arguments.first ?? "popup" {
        case "popup": try TmuxStateWriter.openPopup(binaryPath: executablePath())
        case "enable-badges":
            try TmuxStateWriter.enableBadges()
            let status = try TmuxStateWriter.badgeStatus()
            print("Enabled pane-border badges for this tmux server (\(status.panesWithState) pane\(status.panesWithState == 1 ? "" : "s") currently tracked).")
        case "disable-badges":
            try TmuxStateWriter.disableBadges()
            print("Restored the saved pane-border settings.")
        case "badge-status", "badges-status":
            let status = try TmuxStateWriter.badgeStatus()
            print("Pane-border badges: \(status.enabled ? "enabled" : "disabled") (\(status.panesWithState) pane\(status.panesWithState == 1 ? "" : "s") currently tracked).")
        default: throw CLIError.usage("tmux expects popup, enable-badges, disable-badges, or badge-status")
        }
    }

    private static func notifications(_ arguments: [String]) throws {
        let preferences = BeaconPreferences.shared
        guard let target = arguments.first, target != "status" else {
            print("Mux Beacon notifications")
            print("  start:      \(preferences.notifyOnStart ? "on" : "off")")
            print("  completion: \(preferences.notifyOnReady ? "on" : "off")")
            print("  permission: \(preferences.notifyOnAttention ? "on" : "off")")
            print("  failure:    \(preferences.notifyOnFailure ? "on" : "off")")
            print("  background: \(preferences.notifyOnBackground ? "on" : "off")")
            print("  sound:      \(preferences.notificationSound ? "on" : "off")")
            return
        }
        guard arguments.count > 1, let enabled = parseToggle(arguments[1]) else {
            throw CLIError.usage("notifications expects <start|completion|permission|failure|background|sound|all> <on|off>")
        }
        switch target {
        case "start": preferences.notifyOnStart = enabled
        case "completion", "ready": preferences.notifyOnReady = enabled
        case "permission", "attention": preferences.notifyOnAttention = enabled
        case "failure", "failed": preferences.notifyOnFailure = enabled
        case "background", "paused": preferences.notifyOnBackground = enabled
        case "sound": preferences.notificationSound = enabled
        case "all":
            preferences.notifyOnStart = enabled
            preferences.notifyOnReady = enabled
            preferences.notifyOnAttention = enabled
            preferences.notifyOnFailure = enabled
            preferences.notifyOnBackground = enabled
        default:
            throw CLIError.usage("unknown notification target: \(target)")
        }
        print("Set \(target) notifications \(enabled ? "on" : "off").")
    }

    private static func parseToggle(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on", "true", "yes", "1": true
        case "off", "false", "no", "0": false
        default: nil
        }
    }

    private static func tui() throws {
        let events = try EventStore().fetchEvents(limit: 20)
        print("\n  MUX BEACON\n  Agent activity across tmux\n")
        for (index, event) in events.enumerated() {
            let marker = event.acknowledged ? " " : "●"
            print("  \(String(format: "%2d", index + 1))  \(marker) \(event.source.displayName.padding(toLength: 7, withPad: " ", startingAt: 0)) \(event.state.displayName.padding(toLength: 16, withPad: " ", startingAt: 0)) \(event.projectName)")
            print("      \(event.routeLabel) · \(event.durationLabel)")
        }
        print("\n  Enter a number to open, or press Return to close: ", terminator: "")
        guard let input = readLine(), let choice = Int(input), events.indices.contains(choice - 1) else { return }
        let event = events[choice - 1]
        try TargetRouter.jump(to: event)
        try EventStore().acknowledge(id: event.id)
        EventBroadcaster.post(eventID: event.id)
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func executablePath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    private static func printHelp() {
        print("""
        Mux Beacon — know when terminal agents need you

        Usage:
          mux-beacon install [--apply] [--with-permission-events]
                                              Preview or install Claude/Codex hooks
          mux-beacon uninstall [--apply]     Preview or remove only owned hooks
          mux-beacon doctor                  Check integrations and local state
          mux-beacon status                  List recent agent activity
          mux-beacon health                  Retire superseded or missing tmux targets
          mux-beacon gui                     Open the native inbox window
          mux-beacon notifications status    Show notification preferences
          mux-beacon notifications <type> on|off
                                              Change start/completion/permission/failure/background/all
          mux-beacon test <state>            Send start/ready/attention/failed test event
          mux-beacon demo                    Seed anonymized UI demo data
          mux-beacon jump-last               Open the newest unread agent
          mux-beacon export --format json|csv [--output PATH]
          mux-beacon tmux popup|enable-badges|disable-badges|badge-status

        Completion and failure notifications are enabled by default. Start,
        PermissionRequest, and background-pause notifications are off by default.
        A background pause means the agent is still working, not finished.
        """)
    }
}

private enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? {
        switch self { case .usage(let message): message }
    }
}

private enum AppLauncher {
    static func openGUI() throws {
        guard let app = applicationPath() else { throw AppLauncherError.notInstalled }
        try BeaconPaths.ensureDirectories()
        try Data("open\n".utf8).write(to: BeaconPaths.inboxRequest, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: BeaconPaths.inboxRequest.path)
        do {
            for _ in 0..<3 {
                let result = try ProcessRunner.run("/usr/bin/open", ["-g", app, "--args", "--background"])
                guard result.status == 0 else { throw AppLauncherError.openFailed(result.stderr) }
                for _ in 0..<10 {
                    if !FileManager.default.fileExists(atPath: BeaconPaths.inboxRequest.path) { return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            throw AppLauncherError.openFailed("the app did not acknowledge the open request")
        } catch {
            try? FileManager.default.removeItem(at: BeaconPaths.inboxRequest)
            throw error
        }
    }

    static func launchIfAvailable() {
        guard !isRunning else { return }
        guard let app = applicationPath() else { return }
        _ = try? ProcessRunner.run("/usr/bin/open", ["-gj", app, "--args", "--background"])
    }

    private static var isRunning: Bool {
        guard let result = try? ProcessRunner.run("/usr/bin/pgrep", ["-x", "MuxBeaconApp"], timeout: 1) else {
            return false
        }
        return result.status == 0 && !result.stdout.isEmpty
    }

    private static func applicationPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["MUX_BEACON_APP_PATH"] { candidates.append(override) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if executable.path.contains(".app/Contents/Helpers/") {
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
        }
        candidates += [
            "/Applications/Mux Beacon.app",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Mux Beacon.app").path,
            FileManager.default.currentDirectoryPath + "/dist/Mux Beacon.app",
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }
}

private enum AppLauncherError: LocalizedError {
    case notInstalled
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Mux Beacon.app was not found. Run scripts/install-local.sh first."
        case .openFailed(let detail): "Could not open Mux Beacon: \(detail)"
        }
    }
}
