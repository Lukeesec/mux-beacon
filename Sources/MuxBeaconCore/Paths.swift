import Foundation

public enum BeaconPaths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["MUX_BEACON_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mux Beacon", isDirectory: true)
    }

    public static var database: URL { home.appendingPathComponent("beacon.sqlite3") }
    public static var log: URL { home.appendingPathComponent("mux-beacon.log") }
    public static var notificationStatus: URL { home.appendingPathComponent("notification-status.txt") }
    public static var inboxRequest: URL { home.appendingPathComponent("open-inbox.request") }
    public static func hookReceipt(source: AgentSource) -> URL {
        home.appendingPathComponent("last-hook-\(source.rawValue).txt")
    }
    public static var codexCompletionReceipt: URL { home.appendingPathComponent("last-codex-completion.txt") }
    public static var backupDirectory: URL { home.appendingPathComponent("backups", isDirectory: true) }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }
}

public enum HookReceiptWriter {
    public static func record(source: AgentSource, eventName: String, at date: Date = Date()) {
        do {
            try BeaconPaths.ensureDirectories()
            let value = "\(ISO8601DateFormatter().string(from: date))\t\(eventName)\n"
            try value.write(to: BeaconPaths.hookReceipt(source: source), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: BeaconPaths.hookReceipt(source: source).path
            )
        } catch {
            BeaconLog.write("hook receipt: \(error.localizedDescription)")
        }
    }

    public static func recordCodexCompletion(at date: Date = Date()) {
        do {
            try BeaconPaths.ensureDirectories()
            try "\(ISO8601DateFormatter().string(from: date))\n".write(
                to: BeaconPaths.codexCompletionReceipt,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: BeaconPaths.codexCompletionReceipt.path
            )
        } catch {
            BeaconLog.write("completion receipt: \(error.localizedDescription)")
        }
    }
}

public enum BeaconLog {
    public static func write(_ message: String) {
        do {
            try BeaconPaths.ensureDirectories()
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: BeaconPaths.log.path) {
                let handle = try FileHandle(forWritingTo: BeaconPaths.log)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: BeaconPaths.log, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: BeaconPaths.log.path)
            }
        } catch {
            // Hooks must never fail an agent because diagnostic logging failed.
        }
    }
}
