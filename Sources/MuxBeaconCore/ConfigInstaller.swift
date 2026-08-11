import Foundation

public struct InstallationChange: Sendable {
    public var path: String
    public var eventsAdded: [String]
    public var wasCreated: Bool

    public init(path: String, eventsAdded: [String], wasCreated: Bool) {
        self.path = path
        self.eventsAdded = eventsAdded
        self.wasCreated = wasCreated
    }
}

public struct InstallationReport: Sendable {
    public var applied: Bool
    public var changes: [InstallationChange]
    public var backups: [String]
}

public enum ConfigInstallerError: LocalizedError {
    case invalidRoot(String)
    case invalidHooks(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let path): "\(path) must contain a JSON object."
        case .invalidHooks(let path): "The hooks value in \(path) must be a JSON object."
        }
    }
}

public final class ConfigInstaller {
    public let binaryPath: String
    public let claudeSettings: URL
    public let codexHooks: URL
    public let backupDirectory: URL

    public init(
        binaryPath: String,
        claudeSettings: URL? = nil,
        codexHooks: URL? = nil,
        backupDirectory: URL? = nil
    ) {
        self.binaryPath = URL(fileURLWithPath: binaryPath).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeSettings = claudeSettings
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUX_BEACON_CLAUDE_SETTINGS"] ?? home.appendingPathComponent(".claude/settings.json").path)
        self.codexHooks = codexHooks
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUX_BEACON_CODEX_HOOKS"] ?? home.appendingPathComponent(".codex/hooks.json").path)
        self.backupDirectory = backupDirectory ?? BeaconPaths.backupDirectory
    }

    public func install(apply: Bool, includePermissionEvents: Bool = false) throws -> InstallationReport {
        var claudeEvents = ["UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"]
        var codexEvents = ["UserPromptSubmit", "Stop", "SessionEnd"]
        if includePermissionEvents {
            claudeEvents.append("PermissionRequest")
            codexEvents.append("PermissionRequest")
        }
        let specs: [(URL, AgentSource, [String])] = [
            (claudeSettings, .claude, claudeEvents),
            (codexHooks, .codex, codexEvents),
        ]
        var changes: [InstallationChange] = []
        var backups: [String] = []

        for (url, source, events) in specs {
            let existed = FileManager.default.fileExists(atPath: url.path)
            let root = try readObject(url)
            let (updated, added) = try addingHooks(root: root, source: source, events: events, path: url.path)
            changes.append(InstallationChange(path: url.path, eventsAdded: added, wasCreated: !existed))
            guard apply, !added.isEmpty else { continue }
            if existed { backups.append(try backup(url).path) }
            try writeObject(updated, to: url)
        }
        return InstallationReport(applied: apply, changes: changes, backups: backups)
    }

    public func uninstall(apply: Bool) throws -> InstallationReport {
        let specs: [(URL, AgentSource)] = [(claudeSettings, .claude), (codexHooks, .codex)]
        var changes: [InstallationChange] = []
        var backups: [String] = []

        for (url, source) in specs where FileManager.default.fileExists(atPath: url.path) {
            let root = try readObject(url)
            let (updated, removed) = try removingHooks(root: root, source: source, path: url.path)
            changes.append(InstallationChange(path: url.path, eventsAdded: removed, wasCreated: false))
            guard apply, !removed.isEmpty else { continue }
            backups.append(try backup(url).path)
            try writeObject(updated, to: url)
        }
        return InstallationReport(applied: apply, changes: changes, backups: backups)
    }

    public func status() -> [(AgentSource, Bool, String)] {
        [(.claude, claudeSettings), (.codex, codexHooks)].map { source, url in
            guard
                let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)
            else { return (source, false, url.path) }
            return (source, isManagedCommand(text, source: source), url.path)
        }
    }

    private func addingHooks(
        root: [String: Any],
        source: AgentSource,
        events: [String],
        path: String
    ) throws -> ([String: Any], [String]) {
        var root = root
        var hooks: [String: Any]
        if let existing = root["hooks"] {
            guard let object = existing as? [String: Any] else { throw ConfigInstallerError.invalidHooks(path) }
            hooks = object
        } else {
            hooks = [:]
        }

        let command = managedCommand(source: source)
        var added: [String] = []
        for event in events {
            var groups: [[String: Any]]
            if let existing = hooks[event] {
                guard let eventGroups = existing as? [[String: Any]] else {
                    throw ConfigInstallerError.invalidHooks("\(path) at hooks.\(event)")
                }
                groups = eventGroups
            } else {
                groups = []
            }
            let alreadyInstalled = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    guard let command = $0["command"] as? String else { return false }
                    return isManagedCommand(command, source: source)
                } == true
            }
            guard !alreadyInstalled else { continue }
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": event == "SessionEnd" ? 1 : 3,
                    "statusMessage": event == "UserPromptSubmit" ? "Mux Beacon: tracking turn" : "Mux Beacon",
                ]],
            ])
            hooks[event] = groups
            added.append(event)
        }
        root["hooks"] = hooks
        return (root, added)
    }

    private func removingHooks(
        root: [String: Any],
        source: AgentSource,
        path: String
    ) throws -> ([String: Any], [String]) {
        var root = root
        guard let existingHooks = root["hooks"] else { return (root, []) }
        guard var hooks = existingHooks as? [String: Any] else { throw ConfigInstallerError.invalidHooks(path) }
        var changedEvents: [String] = []

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var newGroups: [[String: Any]] = []
            var changed = false
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    newGroups.append(group)
                    continue
                }
                let filtered = handlers.filter {
                    guard let command = $0["command"] as? String else { return true }
                    return !isManagedCommand(command, source: source)
                }
                if filtered.count != handlers.count { changed = true }
                if !filtered.isEmpty {
                    group["hooks"] = filtered
                    newGroups.append(group)
                }
            }
            if changed { changedEvents.append(event) }
            if newGroups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = newGroups }
        }
        root["hooks"] = hooks
        return (root, changedEvents.sorted())
    }

    private func managedCommand(source: AgentSource) -> String {
        "MUX_BEACON_MANAGED=1 \(shellQuote(binaryPath)) relay --source \(source.rawValue)"
    }

    private func isManagedCommand(_ command: String, source: AgentSource) -> Bool {
        command.contains("MUX_BEACON_MANAGED=1") &&
            command.contains("relay --source \(source.rawValue)")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigInstallerError.invalidRoot(url.path)
        }
        return root
    }

    private func writeObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).mux-beacon.\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private func backup(_ url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let nonce = String(UUID().uuidString.prefix(8)).lowercased()
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)
        let backup = backupDirectory.appendingPathComponent("\(url.lastPathComponent).\(stamp).\(nonce).bak")
        try FileManager.default.copyItem(at: url, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }
}
