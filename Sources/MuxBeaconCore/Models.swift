import Foundation

/// Single source of truth for the CLI-reported version.
/// Keep Packaging/Info.plist's CFBundleShortVersionString and CHANGELOG.md in sync.
public enum BeaconVersion {
    public static let current = "0.2.2"
}

public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String { rawValue.capitalized }
}

public enum AgentState: String, Codable, CaseIterable, Sendable {
    case working
    case needsAttention
    case background
    case ready
    case failed
    case stale

    public var isTerminal: Bool {
        switch self {
        case .ready, .failed, .stale: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .working: "Working"
        case .needsAttention: "Needs attention"
        case .background: "Background work"
        case .ready: "Ready"
        case .failed: "Failed"
        case .stale: "Stale"
        }
    }

    public var symbolName: String {
        switch self {
        case .working: "sparkles"
        case .needsAttention: "hand.raised.fill"
        case .background: "clock.arrow.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stale: "questionmark.circle"
        }
    }

    /// Colored dot for notification titles, matching the tmux badge palette.
    /// Notification text is plain, so the emoji is the only color channel available.
    public var notificationGlyph: String {
        switch self {
        case .working: "🔵"
        case .needsAttention: "🟡"
        case .background: "🟣"
        case .ready: "🟢"
        case .failed: "🔴"
        case .stale: ""
        }
    }
}

public enum RoutingConfidence: String, Codable, Sendable {
    case exact
    case captured
    case ambiguous
    case unavailable
}

public struct TmuxTarget: Codable, Equatable, Sendable {
    public var socketPath: String
    public var serverPID: Int?
    public var sessionID: String
    public var sessionName: String
    public var windowID: String
    public var windowIndex: Int
    public var windowName: String
    public var paneID: String
    public var paneIndex: Int
    public var paneTitle: String
    public var panePath: String
    public var clientTTY: String?
    public var clientPID: Int?
    public var confidence: RoutingConfidence

    public init(
        socketPath: String,
        serverPID: Int? = nil,
        sessionID: String,
        sessionName: String,
        windowID: String,
        windowIndex: Int,
        windowName: String,
        paneID: String,
        paneIndex: Int,
        paneTitle: String,
        panePath: String,
        clientTTY: String? = nil,
        clientPID: Int? = nil,
        confidence: RoutingConfidence = .ambiguous
    ) {
        self.socketPath = socketPath
        self.serverPID = serverPID
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.windowID = windowID
        self.windowIndex = windowIndex
        self.windowName = windowName
        self.paneID = paneID
        self.paneIndex = paneIndex
        self.paneTitle = paneTitle
        self.panePath = panePath
        self.clientTTY = clientTTY
        self.clientPID = clientPID
        self.confidence = confidence
    }

    public var displayPath: String {
        "\(sessionName) › \(windowName)"
    }
}

public struct GhosttyTarget: Codable, Equatable, Sendable {
    public var terminalID: String
    public var terminalName: String?
    public var workingDirectory: String?
    public var capturedAt: Date
    public var confidence: RoutingConfidence

    public init(
        terminalID: String,
        terminalName: String? = nil,
        workingDirectory: String? = nil,
        capturedAt: Date = Date(),
        confidence: RoutingConfidence = .captured
    ) {
        self.terminalID = terminalID
        self.terminalName = terminalName
        self.workingDirectory = workingDirectory
        self.capturedAt = capturedAt
        self.confidence = confidence
    }
}

public struct AgentEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var source: AgentSource
    public var sessionID: String
    public var turnID: String?
    public var state: AgentState
    public var hookEventName: String
    public var cwd: String
    public var projectName: String
    public var model: String?
    public var createdAt: Date
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var acknowledged: Bool
    public var logged: Bool
    public var isDemo: Bool
    public var tmux: TmuxTarget?
    public var ghostty: GhosttyTarget?
    public var preview: String?

    public init(
        id: String,
        source: AgentSource,
        sessionID: String,
        turnID: String? = nil,
        state: AgentState,
        hookEventName: String,
        cwd: String,
        projectName: String,
        model: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        acknowledged: Bool = false,
        logged: Bool = false,
        isDemo: Bool = false,
        tmux: TmuxTarget? = nil,
        ghostty: GhosttyTarget? = nil,
        preview: String? = nil
    ) {
        self.id = id
        self.source = source
        self.sessionID = sessionID
        self.turnID = turnID
        self.state = state
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.projectName = projectName
        self.model = model
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.acknowledged = acknowledged
        self.logged = logged
        self.isDemo = isDemo
        self.tmux = tmux
        self.ghostty = ghostty
        self.preview = preview
    }

    public var duration: TimeInterval {
        max(0, (completedAt ?? Date()).timeIntervalSince(startedAt))
    }

    public var durationLabel: String {
        DurationFormatter.compact(duration)
    }

    public var routeLabel: String {
        guard let tmux else { return "Outside tmux" }
        return isDemo ? "\(tmux.displayPath) · demo" : tmux.displayPath
    }
}

public struct IncomingAgentEvent: Sendable {
    public var source: AgentSource
    public var sessionID: String
    public var turnID: String?
    public var hookEventName: String
    public var cwd: String
    public var model: String?
    public var state: AgentState
    public var timestamp: Date
    public var preview: String?
    public var hasBackgroundWork: Bool
    public var isDemo: Bool
    public var tmux: TmuxTarget?
    public var ghostty: GhosttyTarget?

    public init(
        source: AgentSource,
        sessionID: String,
        turnID: String?,
        hookEventName: String,
        cwd: String,
        model: String?,
        state: AgentState,
        timestamp: Date = Date(),
        preview: String? = nil,
        hasBackgroundWork: Bool = false,
        isDemo: Bool = false,
        tmux: TmuxTarget? = nil,
        ghostty: GhosttyTarget? = nil
    ) {
        self.source = source
        self.sessionID = sessionID
        self.turnID = turnID
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.model = model
        self.state = state
        self.timestamp = timestamp
        self.preview = preview
        self.hasBackgroundWork = hasBackgroundWork
        self.isDemo = isDemo
        self.tmux = tmux
        self.ghostty = ghostty
    }
}

public struct TimeEntryDraft: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var projectName: String
    public var description: String
    public var startedAt: Date
    public var endedAt: Date
    public var duration: TimeInterval
    public var source: AgentSource
    public var externalID: String?

    public init(event: AgentEvent) {
        id = event.id
        projectName = event.projectName
        description = "\(event.source.displayName) turn in \(event.projectName)"
        startedAt = event.startedAt
        endedAt = event.completedAt ?? event.updatedAt
        duration = max(0, endedAt.timeIntervalSince(startedAt))
        source = event.source
        externalID = nil
    }
}

public struct TimeExportResult: Codable, Equatable, Sendable {
    public var localID: String
    public var externalID: String?
    public var success: Bool
    public var message: String?

    public init(localID: String, externalID: String? = nil, success: Bool, message: String? = nil) {
        self.localID = localID
        self.externalID = externalID
        self.success = success
        self.message = message
    }
}

public protocol TimeExportProvider: Sendable {
    var identifier: String { get }
    func validateConfiguration() async throws
    func export(_ entries: [TimeEntryDraft]) async throws -> [TimeExportResult]
}

public enum DurationFormatter {
    public static func compact(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
