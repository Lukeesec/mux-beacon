import Foundation
import MuxBeaconCore

@main
struct MuxBeaconSelfTest {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("Codex UserPromptSubmit fixture", testCodexStart),
            ("Codex turn-complete callback fixture", testCodexCompletion),
            ("Claude background Stop fixture", testClaudeBackground),
            ("Claude prompt origin distinguishes injected turns", testPromptOrigin),
            ("Start, permission, and background notifications default off", testNotificationDefaults),
            ("Routes emphasize session and window", testRouteLabel),
            ("Badge format avoids conditional separator collisions", testBadgeFormat),
            ("Notification glyphs match the badge palette", testNotificationGlyphs),
            ("Superseded pane sessions retire", testSessionReconciliation),
            ("History expires after seven days", testHistoryRetention),
            ("Turn persistence and duration", testStoreFlow),
            ("Terminal sessions expose no active turn", testActiveEvent),
            ("Mismatched completion IDs merge into the active turn", testSessionFallbackMerge),
            ("Untracked completions stay quiet in history", testUntrackedCompletionQuiet),
            ("Injected prompts continue the turn in flight", testInjectedPromptContinuesTurn),
            ("Injected prompts without a turn stay quiet", testInjectedPromptWithoutTurnQuiet),
            ("Completed turns ignore late terminal hooks", testCompletedTurnIsImmutable),
            ("Chained Codex notify is recognized", testCodexNotifyChained),
            ("Additive idempotent installer", testInstaller),
            ("Malformed hook config rejected", testMalformedHookConfig),
            ("CSV escaping", testCSV),
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("✓ \(name)")
            } catch {
                failures += 1
                print("✗ \(name): \(error.localizedDescription)")
            }
        }
        print("\n\(tests.count - failures)/\(tests.count) checks passed")
        if failures > 0 { exit(1) }
    }

    private static func testCodexStart() throws {
        let payload = Data("""
        {"session_id":"thr_123","turn_id":"turn_1","cwd":"/tmp/mux-beacon","hook_event_name":"UserPromptSubmit","model":"gpt-5.6","prompt":"Fix the tests"}
        """.utf8)
        let event = try HookNormalizer.parse(source: .codex, data: payload, environment: [:])
        try expect(event.state == .working && event.turnID == "turn_1" && event.preview == "Fix the tests")
    }

    private static func testCodexCompletion() throws {
        let payload = Data("""
        {"type":"agent-turn-complete","thread-id":"thr_123","turn-id":"turn_1","cwd":"/tmp/mux-beacon","last-assistant-message":"Finished the work.\\nDetails follow."}
        """.utf8)
        let event = try HookNormalizer.parseCodexNotification(data: payload, environment: [:])
        try expect(event.state == .ready && event.sessionID == "thr_123")
        try expect(event.turnID == "turn_1" && event.preview == "Finished the work.")
    }

    private static func testClaudeBackground() throws {
        let payload = Data("""
        {"session_id":"claude_123","prompt_id":"prompt_1","cwd":"/tmp/project","hook_event_name":"Stop","background_tasks":[{"id":"bg_1"}]}
        """.utf8)
        let event = try HookNormalizer.parse(source: .claude, data: payload, environment: [:])
        try expect(event.state == .background && event.hasBackgroundWork)
    }

    private static func testPromptOrigin() throws {
        func origin(_ json: String) throws -> IncomingAgentEvent {
            try HookNormalizer.parse(source: .claude, data: Data(json.utf8), environment: [:])
        }
        let typed = try origin("""
        {"session_id":"claude_1","prompt_id":"p1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","source":"user","prompt":"Fix it"}
        """)
        try expect(typed.promptOrigin == .user && typed.startsTrackedTurn)

        let injected = try origin("""
        {"session_id":"claude_1","prompt_id":"p2","cwd":"/tmp","hook_event_name":"UserPromptSubmit","source":"system","prompt":"<task-notification>"}
        """)
        try expect(injected.promptOrigin == .system && !injected.startsTrackedTurn)

        let wakeup = try origin("""
        {"session_id":"claude_1","prompt_id":"p3","cwd":"/tmp","hook_event_name":"UserPromptSubmit","source":"loop_wakeup"}
        """)
        try expect(wakeup.promptOrigin == .loopWakeup && !wakeup.startsTrackedTurn)

        // Codex and older Claude builds publish no origin, so they must keep
        // opening turns and keep notifying.
        let absent = try origin("""
        {"session_id":"claude_1","prompt_id":"p4","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"Fix it"}
        """)
        try expect(absent.promptOrigin == .unknown && absent.startsTrackedTurn)

        let subagent = try origin("""
        {"session_id":"claude_1","prompt_id":"p5","cwd":"/tmp","hook_event_name":"UserPromptSubmit","source":"user","agent_id":"agent_9"}
        """)
        try expect(subagent.agentID == "agent_9" && !subagent.startsTrackedTurn)
    }

    private static func testNotificationDefaults() throws {
        let suite = "MuxBeaconSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BeaconPreferences(defaults: defaults)
        try expect(!preferences.notifyOnStart && preferences.notifyOnReady && !preferences.notifyOnAttention && preferences.notifyOnFailure)
        // Pausing for background work is mid-run, not a completion.
        try expect(!preferences.notifyOnBackground && !preferences.shouldNotify(for: .background))
        try expect(preferences.shouldNotify(for: .ready) && preferences.shouldNotify(for: .failed))
        preferences.notifyOnBackground = true
        try expect(preferences.shouldNotify(for: .background) && preferences.shouldNotify(for: .ready))
    }

    private static func testInjectedPromptContinuesTurn() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = TmuxTarget(
            socketPath: "/tmp/tmux", sessionID: "$1", sessionName: "Atlas",
            windowID: "@1", windowIndex: 1, windowName: "agents",
            paneID: "%1", paneIndex: 0, paneTitle: "agent", panePath: "/tmp"
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let start = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "typed", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/project", model: nil, state: .working, timestamp: startedAt,
            promptOrigin: .user, tmux: target
        ))
        // A background task reports back mid-run: same tmux pane, new prompt ID.
        let injected = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "task-note", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/project", model: nil, state: .working,
            timestamp: startedAt.addingTimeInterval(60), promptOrigin: .system, tmux: target
        ))
        try expect(injected.id == start.id && injected.state == .working)
        try expect(try store.fetch(id: start.id)?.startedAt == startedAt)
        // The real turn must not be retired as superseded by its own continuation.
        try expect(try store.fetch(id: start.id)?.state == .working)
        try expect(try store.fetchEvents().count == 1)

        let stop = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "task-note", hookEventName: "Stop",
            cwd: "/tmp/project", model: nil, state: .ready,
            timestamp: startedAt.addingTimeInterval(300), tmux: target
        ))
        try expect(stop.id == start.id && stop.state == .ready && !stop.acknowledged)
        // The ledger measures the whole user turn, not the last fragment of it.
        try expect(abs(stop.duration - 300) < 0.01)
        try expect(try store.timeEntries().count == 1)

        // A late hook carrying a folded continuation's prompt ID resolves back to
        // the turn that absorbed it instead of opening a stray record.
        let late = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "task-note", hookEventName: "StopFailure",
            cwd: "/tmp/project", model: nil, state: .failed,
            timestamp: startedAt.addingTimeInterval(1_600), tmux: target
        ))
        try expect(late.id == start.id && late.state == .ready)
        try expect(try store.fetchEvents().count == 1)
    }

    private static func testInjectedPromptWithoutTurnQuiet() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A task notification arriving after the user's turn already finished is
        // provider chatter, not a turn the user is waiting on.
        let injected = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "task-note", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/project", model: nil, state: .working, promptOrigin: .system
        ))
        try expect(injected.state == .working && injected.acknowledged)
        let stop = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "task-note", hookEventName: "Stop",
            cwd: "/tmp/project", model: nil, state: .ready
        ))
        try expect(stop.id == injected.id && stop.state == .ready && stop.acknowledged)
    }

    private static func testCompletedTurnIsImmutable() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSince1970: 2_000)
        _ = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "typed", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/project", model: nil, state: .working, timestamp: startedAt, promptOrigin: .user
        ))
        let ready = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "typed", hookEventName: "Stop",
            cwd: "/tmp/project", model: nil, state: .ready, timestamp: startedAt.addingTimeInterval(100)
        ))
        try expect(ready.state == .ready)
        // Claude reuses a finished turn's prompt ID until the next prompt, so a
        // late rate-limit StopFailure must not rewrite a delivered completion.
        let late = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "typed", hookEventName: "StopFailure",
            cwd: "/tmp/project", model: nil, state: .failed, timestamp: startedAt.addingTimeInterval(1_400)
        ))
        try expect(late.id == ready.id && late.state == .ready)
        try expect(try store.fetch(id: ready.id)?.state == .ready)
        try expect(try store.fetch(id: ready.id)?.completedAt == startedAt.addingTimeInterval(100))
        try expect(try store.fetchEvents().count == 1)

        // A duplicate completion — Codex sends both a Stop hook and its notify
        // callback — must stay one record.
        let duplicate = try store.record(IncomingAgentEvent(
            source: .claude, sessionID: "claude", turnID: "typed", hookEventName: "Stop",
            cwd: "/tmp/project", model: nil, state: .ready, timestamp: startedAt.addingTimeInterval(101)
        ))
        try expect(duplicate.completedAt == startedAt.addingTimeInterval(100))
        try expect(try store.fetchEvents().count == 1)
    }

    private static func testCodexNotifyChained() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codexConfig = directory.appendingPathComponent("config.toml")
        let installer = ConfigInstaller(
            binaryPath: "/Applications/Mux Beacon.app/Contents/Helpers/mux-beacon",
            claudeSettings: directory.appendingPathComponent("claude.json"),
            codexHooks: directory.appendingPathComponent("codex.json"),
            codexConfig: codexConfig,
            backupDirectory: directory.appendingPathComponent("backups")
        )
        // A wrapper owning the notify slot that re-invokes the previous command
        // still delivers Codex completions.
        let chained = """
        notify = ["/Applications/Wrapper.app/Contents/MacOS/wrapper", "turn-ended", "--previous-notify", "[\\"mux-beacon\\",\\"codex-notify\\"]"]
        """
        try Data((chained + "\n").utf8).write(to: codexConfig)
        try expect(installer.codexNotifyStatus() == .chained)
        let report = try installer.install(apply: true)
        try expect(report.warnings.isEmpty)
        try expect(try String(contentsOf: codexConfig, encoding: .utf8).contains("Wrapper.app"))
        try expect(installer.codexNotifyStatus() == .chained)

        // A foreign notify that does not forward is still reported as occupied.
        try Data("notify = [\"/usr/local/bin/other\"]\n".utf8).write(to: codexConfig)
        try expect(installer.codexNotifyStatus() == .occupied)
    }

    private static func testRouteLabel() throws {
        let tmux = TmuxTarget(
            socketPath: "/tmp/tmux", sessionID: "$1", sessionName: "Atlas",
            windowID: "@7", windowIndex: 7, windowName: "agents",
            paneID: "%2", paneIndex: 2, paneTitle: "agent", panePath: "/tmp"
        )
        let event = AgentEvent(
            id: "route", source: .codex, sessionID: "session", state: .ready,
            hookEventName: "Stop", cwd: "/tmp", projectName: "project", tmux: tmux
        )
        try expect(event.routeLabel == "Atlas › agents" && !event.routeLabel.contains("pane"))
        var demo = event
        demo.isDemo = true
        try expect(demo.routeLabel == "Atlas › agents · demo")
        do {
            try TargetRouter.jump(to: demo)
            throw SelfTestError.failedExpectation
        } catch RoutingError.demo {
            // Demo events must never attempt live tmux navigation.
        }
    }

    private static func testNotificationGlyphs() throws {
        try expect(AgentState.ready.notificationGlyph == "🟢")
        try expect(AgentState.failed.notificationGlyph == "🔴")
        try expect(AgentState.needsAttention.notificationGlyph == "🟡")
        try expect(AgentState.working.notificationGlyph == "🔵")
        try expect(!AgentState.background.notificationGlyph.isEmpty)
        try expect(AgentState.stale.notificationGlyph.isEmpty)
    }

    private static func testBadgeFormat() throws {
        try expect(TmuxStateWriter.badgeFormat.contains("● WORKING"))
        try expect(!TmuxStateWriter.badgeFormat.contains("fg=blue,bold"))
        try expect(!TmuxStateWriter.badgeFormat.contains("fg=green,bold"))
    }

    private static func testStoreFlow() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSince1970: 100)
        let start = try store.record(IncomingAgentEvent(
            source: .codex, sessionID: "session", turnID: "turn", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/project", model: nil, state: .working, timestamp: startedAt, preview: "secret"
        ))
        let stop = try store.record(IncomingAgentEvent(
            source: .codex, sessionID: "session", turnID: "turn", hookEventName: "Stop",
            cwd: "/tmp/project", model: nil, state: .ready, timestamp: startedAt.addingTimeInterval(125)
        ))
        try expect(start.id == stop.id && stop.state == .ready && stop.preview == nil)
        let entryCount = try store.timeEntries().count
        try expect(abs(stop.duration - 125) < 0.01 && entryCount == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("test.sqlite3").path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600)
    }

    private static func testActiveEvent() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = IncomingAgentEvent(
            source: .codex, sessionID: "session", turnID: "turn", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/project", model: nil, state: .working
        )
        _ = try store.record(start)
        try expect(try store.activeEvent(source: .codex, sessionID: "session") != nil)
        _ = try store.record(IncomingAgentEvent(
            source: .codex, sessionID: "session", turnID: "turn", hookEventName: "Stop",
            cwd: "/tmp/project", model: nil, state: .ready
        ))
        try expect(try store.activeEvent(source: .codex, sessionID: "session") == nil)
    }

    private static func testSessionFallbackMerge() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSince1970: 500)
        let start = try store.record(IncomingAgentEvent(
            source: .codex, sessionID: "thread", turnID: "prompt-1", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/project", model: nil, state: .working, timestamp: startedAt
        ))
        // Codex's turn-complete callback carries a turn ID from a different
        // namespace than the prompt hook's prompt ID.
        let stop = try store.record(IncomingAgentEvent(
            source: .codex, sessionID: "thread", turnID: "turn-9", hookEventName: "Stop",
            cwd: "/tmp/project", model: nil, state: .ready, timestamp: startedAt.addingTimeInterval(300)
        ))
        try expect(stop.id == start.id && stop.state == .ready && !stop.acknowledged)
        try expect(abs(stop.duration - 300) < 0.01)
    }

    private static func testUntrackedCompletionQuiet() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try store.record(IncomingAgentEvent(
            source: .codex, sessionID: "automation", turnID: "task-1", hookEventName: "Stop",
            cwd: "/tmp/project", model: nil, state: .ready
        ))
        try expect(ready.state == .ready && ready.acknowledged)
        try expect(try store.activeEvent(source: .codex, sessionID: "automation") == nil)
    }

    private static func testSessionReconciliation() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = TmuxTarget(
            socketPath: "/tmp/tmux", sessionID: "$1", sessionName: "Atlas",
            windowID: "@1", windowIndex: 1, windowName: "agents",
            paneID: "%1", paneIndex: 0, paneTitle: "agent", panePath: "/tmp"
        )
        let first = try store.record(IncomingAgentEvent(
            source: .codex, sessionID: "old", turnID: "one", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/old", model: nil, state: .working,
            timestamp: Date(timeIntervalSince1970: 10), tmux: target
        ))
        let second = try store.record(IncomingAgentEvent(
            source: .codex, sessionID: "new", turnID: "two", hookEventName: "UserPromptSubmit",
            cwd: "/tmp/new", model: nil, state: .working,
            timestamp: Date(timeIntervalSince1970: 10), tmux: target
        ))
        let retired = try store.fetch(id: first.id)
        let current = try store.fetch(id: second.id)
        try expect(retired?.state == .stale && retired?.acknowledged == true && current?.state == .working)
    }

    private static func testHistoryRetention() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expired = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-6 * 24 * 60 * 60)

        func event(id: String, state: AgentState, updatedAt: Date, acknowledged: Bool) -> AgentEvent {
            AgentEvent(
                id: id, source: .codex, sessionID: id, state: state,
                hookEventName: state == .working ? "UserPromptSubmit" : "Stop",
                cwd: "/tmp", projectName: "project", createdAt: updatedAt,
                startedAt: updatedAt, updatedAt: updatedAt,
                completedAt: state.isTerminal ? updatedAt : nil,
                acknowledged: acknowledged
            )
        }

        try store.upsert(event(id: "old-stale", state: .stale, updatedAt: expired, acknowledged: true))
        try store.upsert(event(id: "old-read", state: .ready, updatedAt: expired, acknowledged: true))
        try store.upsert(event(id: "old-unread", state: .ready, updatedAt: expired, acknowledged: false))
        try store.upsert(event(id: "old-running", state: .working, updatedAt: expired, acknowledged: false))
        try store.upsert(event(id: "recent-stale", state: .stale, updatedAt: recent, acknowledged: true))

        try store.pruneExpiredHistory(now: now)
        try expect(try store.fetch(id: "old-stale") == nil)
        try expect(try store.fetch(id: "old-read") == nil)
        try expect(try store.fetch(id: "old-unread") != nil)
        try expect(try store.fetch(id: "old-running") != nil)
        try expect(try store.fetch(id: "recent-stale") != nil)
    }

    private static func testMalformedHookConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = directory.appendingPathComponent("claude.json")
        let codex = directory.appendingPathComponent("codex.json")
        let codexConfig = directory.appendingPathComponent("config.toml")
        let malformed = Data("{\"hooks\":{\"UserPromptSubmit\":\"not-an-array\"}}".utf8)
        try malformed.write(to: claude)
        try Data("{}".utf8).write(to: codex)
        let installer = ConfigInstaller(
            binaryPath: "/tmp/mux-beacon",
            claudeSettings: claude,
            codexHooks: codex,
            codexConfig: codexConfig,
            backupDirectory: directory.appendingPathComponent("backups")
        )
        do {
            _ = try installer.install(apply: false)
            throw SelfTestError.failedExpectation
        } catch is ConfigInstallerError {
            return
        }
    }

    private static func testInstaller() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = directory.appendingPathComponent("claude.json")
        let codex = directory.appendingPathComponent("codex.json")
        let codexConfig = directory.appendingPathComponent("config.toml")
        let existing: [String: Any] = [
            "permissions": ["defaultMode": "bypassPermissions"],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/existing"]]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: claude)
        try data.write(to: codex)
        try Data("model = \"gpt-5\"\n".utf8).write(to: codexConfig)
        let installer = ConfigInstaller(
            binaryPath: "/Applications/Mux Beacon.app/Contents/Helpers/mux-beacon",
            claudeSettings: claude,
            codexHooks: codex,
            codexConfig: codexConfig,
            backupDirectory: directory.appendingPathComponent("backups")
        )
        _ = try installer.install(apply: true)
        let second = try installer.install(apply: true)
        try expect(second.changes.allSatisfy(\.eventsAdded.isEmpty))
        let installed = try String(contentsOf: codex)
        try expect(installed.contains("existing") && !installed.contains("PermissionRequest"))
        let installedConfig = try String(contentsOf: codexConfig)
        try expect(installedConfig.contains("codex-notify") && installedConfig.contains("model = \"gpt-5\""))
        try expect(!installedConfig.contains("\\/"))
        try expect(installer.codexNotifyStatus() == .installed)
        _ = try installer.uninstall(apply: true)
        let result = try String(contentsOf: codex)
        try expect(result.contains("existing") && !result.contains("relay --source codex"))
        let uninstalledConfig = try String(contentsOf: codexConfig)
        try expect(!uninstalledConfig.contains("codex-notify") && uninstalledConfig.contains("model = \"gpt-5\""))

        try Data("notify = [\"/usr/local/bin/existing-notifier\"]\n".utf8).write(to: codexConfig)
        let occupied = try installer.install(apply: true)
        try expect(occupied.warnings.count == 1)
        try expect(try String(contentsOf: codexConfig).contains("existing-notifier"))
        try expect(!String(contentsOf: codexConfig).contains("codex-notify"))

        try Data("# old # mux-beacon-managed\nnotify = [\"\\/tmp\\/mux-beacon\", \"codex-notify\"] # mux-beacon-managed\n".utf8).write(to: codexConfig)
        try expect(installer.codexNotifyStatus() == .needsRepair)
        _ = try installer.install(apply: true)
        let repaired = try String(contentsOf: codexConfig)
        try expect(installer.codexNotifyStatus() == .installed && !repaired.contains("\\/"))
    }

    private static func testCSV() throws {
        let event = AgentEvent(
            id: "id,1", source: .claude, sessionID: "session", state: .ready, hookEventName: "Stop",
            cwd: "/tmp/project", projectName: "A \"quoted\", project",
            startedAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20),
            completedAt: Date(timeIntervalSince1970: 20)
        )
        let csv = String(decoding: TimeEntryExporter.csv([TimeEntryDraft(event: event)]), as: UTF8.self)
        try expect(csv.contains("\"id,1\"") && csv.contains("\"A \"\"quoted\"\", project\""))
    }

    private static func temporaryStore() throws -> (URL, EventStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, EventStore(databaseURL: directory.appendingPathComponent("test.sqlite3")))
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool) throws {
        guard try condition() else { throw SelfTestError.failedExpectation }
    }
}

private enum SelfTestError: LocalizedError {
    case failedExpectation
    var errorDescription: String? { "expectation failed" }
}
