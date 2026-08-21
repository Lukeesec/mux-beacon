import Foundation

public final class BeaconPreferences: @unchecked Sendable {
    public static let shared = BeaconPreferences()
    public static let suiteName = "com.lukeesec.MuxBeacon.shared"

    private enum Key {
        static let notifyOnStart = "notifyOnStart"
        static let notifyOnReady = "notifyOnReady"
        static let notifyOnAttention = "notifyOnAttention"
        static let notifyOnBackground = "notifyOnBackground"
        static let notifyOnFailure = "notifyOnFailure"
        static let notificationSound = "notificationSound"
        static let skipWatchedSession = "skipWatchedSession"
        static let storePreviews = "storePreviews"
    }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
        self.defaults.register(defaults: [
            Key.notifyOnStart: false,
            Key.notifyOnReady: true,
            Key.notifyOnAttention: false,
            Key.notifyOnBackground: false,
            Key.notifyOnFailure: true,
            Key.notificationSound: true,
            Key.skipWatchedSession: true,
            Key.storePreviews: false,
        ])
    }

    public var notifyOnStart: Bool {
        get { defaults.bool(forKey: Key.notifyOnStart) }
        set { defaults.set(newValue, forKey: Key.notifyOnStart) }
    }

    public var notifyOnReady: Bool {
        get { defaults.bool(forKey: Key.notifyOnReady) }
        set { defaults.set(newValue, forKey: Key.notifyOnReady) }
    }

    public var notifyOnAttention: Bool {
        get { defaults.bool(forKey: Key.notifyOnAttention) }
        set { defaults.set(newValue, forKey: Key.notifyOnAttention) }
    }

    /// Claude fires `Stop` when it parks itself waiting on background work, not
    /// only when a turn is over. That is mid-run, so it is off by default and
    /// deliberately kept separate from completion alerts.
    public var notifyOnBackground: Bool {
        get { defaults.bool(forKey: Key.notifyOnBackground) }
        set { defaults.set(newValue, forKey: Key.notifyOnBackground) }
    }

    public var notifyOnFailure: Bool {
        get { defaults.bool(forKey: Key.notifyOnFailure) }
        set { defaults.set(newValue, forKey: Key.notifyOnFailure) }
    }

    public var notificationSound: Bool {
        get { defaults.bool(forKey: Key.notificationSound) }
        set { defaults.set(newValue, forKey: Key.notificationSound) }
    }

    /// A banner for the pane already on screen is noise. On by default; every
    /// uncertain case still notifies.
    public var skipWatchedSession: Bool {
        get { defaults.bool(forKey: Key.skipWatchedSession) }
        set { defaults.set(newValue, forKey: Key.skipWatchedSession) }
    }

    public var storePreviews: Bool {
        get { defaults.bool(forKey: Key.storePreviews) }
        set { defaults.set(newValue, forKey: Key.storePreviews) }
    }

    public func shouldNotify(for state: AgentState) -> Bool {
        switch state {
        case .working: notifyOnStart
        case .ready: notifyOnReady
        case .background: notifyOnBackground
        case .needsAttention: notifyOnAttention
        case .failed: notifyOnFailure
        case .stale: false
        }
    }
}

public enum DemoSeeder {
    @discardableResult
    public static func seed(store: EventStore, now: Date = Date()) throws -> [AgentEvent] {
        try store.deleteDemoEvents()
        let samples: [(AgentSource, AgentState, String, TimeInterval, String, Int, String, Int)] = [
            (.claude, .needsAttention, "payments-api", 94, "Payments", 3, "api-review", 1),
            (.codex, .ready, "mux-beacon", 751, "Beacon", 1, "native-app", 0),
            (.claude, .working, "docs-pipeline", 228, "Docs", 7, "site-build", 0),
            (.codex, .failed, "edge-cache", 43, "Infra", 2, "deploy-debug", 2),
        ]
        return try samples.enumerated().map { index, sample in
            let started = now.addingTimeInterval(-sample.3)
            let tmux = TmuxTarget(
                socketPath: "/private/tmp/tmux-demo/default",
                sessionID: "$\(index + 1)",
                sessionName: sample.4,
                windowID: "@\(index + 20)",
                windowIndex: sample.5,
                windowName: sample.6,
                paneID: "%\(index + 40)",
                paneIndex: sample.7,
                paneTitle: sample.6,
                panePath: "/Users/demo/repos/\(sample.2)",
                clientTTY: "/dev/ttys\(20 + index)",
                confidence: .exact
            )
            let terminal = sample.1.isTerminal ? now : nil
            let event = AgentEvent(
                id: "demo-\(index)",
                source: sample.0,
                sessionID: "demo-session-\(index)",
                turnID: "demo-turn-\(index)",
                state: sample.1,
                hookEventName: sample.1 == .working ? "UserPromptSubmit" : "Stop",
                cwd: "/Users/demo/repos/\(sample.2)",
                projectName: sample.2,
                model: sample.0 == .codex ? "gpt-5.6" : "claude-opus",
                createdAt: started,
                startedAt: started,
                updatedAt: now,
                completedAt: terminal,
                acknowledged: false,
                logged: false,
                isDemo: true,
                tmux: tmux,
                preview: nil
            )
            try store.upsert(event)
            return event
        }
    }
}

public enum TimeEntryExporter {
    public static func json(_ entries: [TimeEntryDraft]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    public static func csv(_ entries: [TimeEntryDraft]) -> Data {
        let formatter = ISO8601DateFormatter()
        var rows = ["id,project,description,started_at,ended_at,duration_seconds,source"]
        rows += entries.map {
            [
                csvField($0.id), csvField($0.projectName), csvField($0.description),
                csvField(formatter.string(from: $0.startedAt)), csvField(formatter.string(from: $0.endedAt)),
                String(Int($0.duration.rounded())), csvField($0.source.rawValue),
            ].joined(separator: ",")
        }
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }

    private static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
