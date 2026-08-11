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
            case "install":
                try install(Array(arguments.dropFirst()), uninstall: false)
            case "uninstall":
                try install(Array(arguments.dropFirst()), uninstall: true)
            case "doctor":
                try doctor()
            case "status":
                try status()
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
            case "tui":
                try tui()
            case "help", "--help", "-h":
                printHelp()
            case "version", "--version", "-v":
                print("mux-beacon 0.1.0")
            default:
                throw CLIError.usage("Unknown command: \(command)")
            }
        } catch {
            if command == "relay" {
                BeaconLog.write("relay error: \(error.localizedDescription)")
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
        let event = try EventStore().record(incoming, storePreview: BeaconPreferences.shared.storePreviews)
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
        for (source, installed, path) in ConfigInstaller(binaryPath: executablePath()).status() {
            print("  \(source.displayName) hook: \(installed ? "installed" : "not installed") (\(path))")
        }
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
        let sessionID = "mux-beacon-test"
        let incoming = IncomingAgentEvent(
            source: source,
            sessionID: sessionID,
            turnID: "manual-test",
            hookEventName: hook,
            cwd: FileManager.default.currentDirectoryPath,
            model: "test-model",
            state: state,
            timestamp: Date(),
            preview: "Synthetic Mux Beacon test event",
            tmux: TmuxInspector.capture(environment: ProcessInfo.processInfo.environment),
            ghostty: hook == "UserPromptSubmit" ? GhosttyInspector.captureFocusedTerminal(environment: ProcessInfo.processInfo.environment) : nil
        )
        let event = try EventStore().record(incoming)
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
        case "enable-badges": try TmuxStateWriter.enableBadges()
        case "disable-badges": try TmuxStateWriter.disableBadges()
        default: throw CLIError.usage("tmux expects popup, enable-badges, or disable-badges")
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
          mux-beacon test <state>            Send start/ready/attention/failed test event
          mux-beacon demo                    Seed anonymized UI demo data
          mux-beacon jump-last               Open the newest unread agent
          mux-beacon export --format json|csv [--output PATH]
          mux-beacon tmux popup|enable-badges|disable-badges

        UserPromptSubmit notifications are enabled by default. PermissionRequest
        notifications are supported but off by default in Mux Beacon settings.
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
    static func launchIfAvailable() {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["MUX_BEACON_APP_PATH"] { candidates.append(override) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if executable.path.contains(".app/Contents/Helpers/") {
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
        }
        candidates += [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Mux Beacon.app").path,
            "/Applications/Mux Beacon.app",
            FileManager.default.currentDirectoryPath + "/dist/Mux Beacon.app",
        ]
        guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        _ = try? ProcessRunner.run("/usr/bin/open", ["-gj", app])
    }
}
