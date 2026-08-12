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
    public var warnings: [String]
}

public enum CodexNotifyStatus: Sendable {
    case installed
    case available
    case occupied
    case needsRepair
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
    public let codexConfig: URL
    public let backupDirectory: URL

    public init(
        binaryPath: String,
        claudeSettings: URL? = nil,
        codexHooks: URL? = nil,
        codexConfig: URL? = nil,
        backupDirectory: URL? = nil
    ) {
        self.binaryPath = URL(fileURLWithPath: binaryPath).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeSettings = claudeSettings
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUX_BEACON_CLAUDE_SETTINGS"] ?? home.appendingPathComponent(".claude/settings.json").path)
        self.codexHooks = codexHooks
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUX_BEACON_CODEX_HOOKS"] ?? home.appendingPathComponent(".codex/hooks.json").path)
        self.codexConfig = codexConfig
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUX_BEACON_CODEX_CONFIG"] ?? home.appendingPathComponent(".codex/config.toml").path)
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
        var warnings: [String] = []

        for (url, source, events) in specs {
            let existed = FileManager.default.fileExists(atPath: url.path)
            let root = try readObject(url)
            let (updated, added) = try addingHooks(root: root, source: source, events: events, path: url.path)
            changes.append(InstallationChange(path: url.path, eventsAdded: added, wasCreated: !existed))
            guard apply, !added.isEmpty else { continue }
            if existed { backups.append(try backup(url).path) }
            try writeObject(updated, to: url)
        }
        let notifyChange = try installCodexNotify(apply: apply)
        changes.append(notifyChange.change)
        if let backup = notifyChange.backup { backups.append(backup) }
        if let warning = notifyChange.warning { warnings.append(warning) }
        return InstallationReport(applied: apply, changes: changes, backups: backups, warnings: warnings)
    }

    public func uninstall(apply: Bool) throws -> InstallationReport {
        let specs: [(URL, AgentSource)] = [(claudeSettings, .claude), (codexHooks, .codex)]
        var changes: [InstallationChange] = []
        var backups: [String] = []
        let warnings: [String] = []

        for (url, source) in specs where FileManager.default.fileExists(atPath: url.path) {
            let root = try readObject(url)
            let (updated, removed) = try removingHooks(root: root, source: source, path: url.path)
            changes.append(InstallationChange(path: url.path, eventsAdded: removed, wasCreated: false))
            guard apply, !removed.isEmpty else { continue }
            backups.append(try backup(url).path)
            try writeObject(updated, to: url)
        }
        let notifyChange = try uninstallCodexNotify(apply: apply)
        changes.append(notifyChange.change)
        if let backup = notifyChange.backup { backups.append(backup) }
        return InstallationReport(applied: apply, changes: changes, backups: backups, warnings: warnings)
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

    public func codexNotifyStatus() -> CodexNotifyStatus {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return .available }
        if text.hasPrefix(managedNotifyPrefix()) { return .installed }
        if hasManagedNotifySetting(text) { return .needsRepair }
        return hasNotifySetting(text) ? .occupied : .available
    }

    private static let notifyMarker = "# mux-beacon-managed"

    private func installCodexNotify(apply: Bool) throws -> (change: InstallationChange, backup: String?, warning: String?) {
        let existed = FileManager.default.fileExists(atPath: codexConfig.path)
        let text = existed ? try String(contentsOf: codexConfig, encoding: .utf8) : ""
        let change = InstallationChange(path: codexConfig.path, eventsAdded: [], wasCreated: !existed)
        let prefix = managedNotifyPrefix()
        if text.hasPrefix(prefix) { return (change, nil, nil) }
        if hasNotifySetting(text) {
            if !hasManagedNotifySetting(text) {
                return (change, nil, "Codex notify is already configured; preserved it, so Codex completion fallback was not installed.")
            }
        }

        var changed = change
        changed.eventsAdded = ["agent-turn-complete"]
        guard apply else { return (changed, nil, nil) }
        let backup = existed ? try backup(codexConfig).path : nil
        var preserved = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.contains(Self.notifyMarker) }
            .joined(separator: "\n")
        while preserved.hasPrefix("\n") { preserved.removeFirst() }
        try writeText(prefix + preserved, to: codexConfig)
        return (changed, backup, nil)
    }

    private func uninstallCodexNotify(apply: Bool) throws -> (change: InstallationChange, backup: String?) {
        guard FileManager.default.fileExists(atPath: codexConfig.path) else {
            return (InstallationChange(path: codexConfig.path, eventsAdded: [], wasCreated: false), nil)
        }
        let text = try String(contentsOf: codexConfig, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let filtered = lines.filter { !$0.contains(Self.notifyMarker) }
        let removed = filtered.count != lines.count
        let change = InstallationChange(
            path: codexConfig.path,
            eventsAdded: removed ? ["agent-turn-complete"] : [],
            wasCreated: false
        )
        guard apply, removed else { return (change, nil) }
        let backup = try backup(codexConfig).path
        var updated = filtered.joined(separator: "\n")
        while updated.hasPrefix("\n") { updated.removeFirst() }
        try writeText(updated, to: codexConfig)
        return (change, backup)
    }

    private func hasNotifySetting(_ text: String) -> Bool {
        text.range(of: #"(?m)^[\t ]*notify[\t ]*="# , options: .regularExpression) != nil
    }

    private func hasManagedNotifySetting(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isNewline }).contains {
            $0.contains("notify") && $0.contains("codex-notify") && $0.contains(Self.notifyMarker)
        }
    }

    private func managedNotifyPrefix() -> String {
        "# Mux Beacon Codex completion callback \(Self.notifyMarker)\nnotify = [\(tomlString(binaryPath)), \"codex-notify\"] \(Self.notifyMarker)\n\n"
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
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

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).mux-beacon.\(UUID().uuidString)")
        try Data(text.utf8).write(to: temporary, options: .atomic)
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
