import Foundation
import MuxBeaconCore

@main
struct MuxBeaconSelfTest {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("Codex UserPromptSubmit fixture", testCodexStart),
            ("Claude background Stop fixture", testClaudeBackground),
            ("Permission notifications default off", testPermissionDefault),
            ("Turn persistence and duration", testStoreFlow),
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

    private static func testClaudeBackground() throws {
        let payload = Data("""
        {"session_id":"claude_123","prompt_id":"prompt_1","cwd":"/tmp/project","hook_event_name":"Stop","background_tasks":[{"id":"bg_1"}]}
        """.utf8)
        let event = try HookNormalizer.parse(source: .claude, data: payload, environment: [:])
        try expect(event.state == .background && event.hasBackgroundWork)
    }

    private static func testPermissionDefault() throws {
        let suite = "MuxBeaconSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BeaconPreferences(defaults: defaults)
        try expect(preferences.notifyOnStart && !preferences.notifyOnAttention)
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

    private static func testMalformedHookConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = directory.appendingPathComponent("claude.json")
        let codex = directory.appendingPathComponent("codex.json")
        let malformed = Data("{\"hooks\":{\"UserPromptSubmit\":\"not-an-array\"}}".utf8)
        try malformed.write(to: claude)
        try Data("{}".utf8).write(to: codex)
        let installer = ConfigInstaller(
            binaryPath: "/tmp/mux-beacon",
            claudeSettings: claude,
            codexHooks: codex,
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
        let existing: [String: Any] = [
            "permissions": ["defaultMode": "bypassPermissions"],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/existing"]]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: claude)
        try data.write(to: codex)
        let installer = ConfigInstaller(
            binaryPath: "/Applications/Mux Beacon.app/Contents/Helpers/mux-beacon",
            claudeSettings: claude,
            codexHooks: codex,
            backupDirectory: directory.appendingPathComponent("backups")
        )
        _ = try installer.install(apply: true)
        let second = try installer.install(apply: true)
        try expect(second.changes.allSatisfy(\.eventsAdded.isEmpty))
        let installed = try String(contentsOf: codex)
        try expect(installed.contains("existing") && !installed.contains("PermissionRequest"))
        _ = try installer.uninstall(apply: true)
        let result = try String(contentsOf: codex)
        try expect(result.contains("existing") && !result.contains("relay --source codex"))
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
