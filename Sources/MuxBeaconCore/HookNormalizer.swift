import Foundation

public enum HookNormalizerError: LocalizedError {
    case invalidJSON
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "Hook input was not a JSON object."
        case .missingField(let name): "Hook input is missing \(name)."
        }
    }
}

public enum HookNormalizer {
    public static func parse(
        source: AgentSource,
        data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        spawnedByAgent: Bool = AgentAncestry.isNestedRun()
    ) throws -> IncomingAgentEvent {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw HookNormalizerError.invalidJSON }

        guard let sessionID = object.string("session_id"), !sessionID.isEmpty else {
            throw HookNormalizerError.missingField("session_id")
        }
        guard let hookName = object.string("hook_event_name"), !hookName.isEmpty else {
            throw HookNormalizerError.missingField("hook_event_name")
        }

        let cwd = object.string("cwd") ?? FileManager.default.currentDirectoryPath
        let turnID = object.string("turn_id") ?? object.string("prompt_id")
        // Claude Code publishes who injected the prompt. Task notifications,
        // auto-continuation, and loop or schedule wake-ups all arrive as real
        // UserPromptSubmit hooks; only `user` and `sdk` mean a person is waiting.
        let promptOrigin = PromptOrigin(hookValue: object.string("source"))
        // Present only when the hook fired inside a subagent.
        let agentID = object.string("agent_id")
        let backgroundTasks = object.array("background_tasks")?.isEmpty == false
        let sessionCrons = object.array("session_crons")?.isEmpty == false
        let hasBackground = backgroundTasks || sessionCrons

        let state: AgentState
        switch hookName {
        case "UserPromptSubmit": state = .working
        case "PermissionRequest", "Notification": state = .needsAttention
        case "Stop": state = hasBackground ? .background : .ready
        case "StopFailure": state = .failed
        case "SessionEnd": state = .stale
        default: state = .working
        }

        let preview: String?
        switch hookName {
        case "UserPromptSubmit": preview = object.string("prompt")
        case "Stop": preview = object.string("last_assistant_message")
        case "StopFailure": preview = object.string("error") ?? object.string("last_assistant_message")
        case "PermissionRequest":
            preview = (object["tool_input"] as? [String: Any])?.string("description")
                ?? object.string("tool_name")
        case "Notification": preview = object.string("message")
        default: preview = nil
        }

        let shouldCaptureOrigin = hookName == "UserPromptSubmit"
        let tmux = TmuxInspector.capture(environment: environment)
        return IncomingAgentEvent(
            source: source,
            sessionID: sessionID,
            turnID: turnID,
            hookEventName: hookName,
            cwd: cwd,
            model: object.string("model"),
            state: state,
            timestamp: now,
            preview: preview?.firstLine(limit: 180),
            hasBackgroundWork: hasBackground,
            promptOrigin: promptOrigin,
            agentID: agentID,
            spawnedByAgent: spawnedByAgent,
            tmux: tmux,
            ghostty: shouldCaptureOrigin
                ? GhosttyInspector.captureFocusedTerminal(environment: environment, tmux: tmux)
                : nil
        )
    }

    public static func parseCodexNotification(
        data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        spawnedByAgent: Bool = AgentAncestry.isNestedRun()
    ) throws -> IncomingAgentEvent {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw HookNormalizerError.invalidJSON }
        guard object.string("type") == "agent-turn-complete" else {
            throw HookNormalizerError.missingField("type=agent-turn-complete")
        }
        guard let sessionID = object.string("thread-id") ?? object.string("thread_id"), !sessionID.isEmpty else {
            throw HookNormalizerError.missingField("thread-id")
        }

        return IncomingAgentEvent(
            source: .codex,
            sessionID: sessionID,
            turnID: object.string("turn-id") ?? object.string("turn_id"),
            hookEventName: "Stop",
            cwd: object.string("cwd") ?? FileManager.default.currentDirectoryPath,
            model: nil,
            state: .ready,
            timestamp: now,
            preview: object.string("last-assistant-message")?.firstLine(limit: 180),
            spawnedByAgent: spawnedByAgent,
            tmux: TmuxInspector.capture(environment: environment)
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
}

private extension String {
    func firstLine(limit: Int) -> String {
        let line = split(whereSeparator: \.isNewline).first.map(String.init) ?? self
        if line.count <= limit { return line }
        return String(line.prefix(limit - 1)) + "…"
    }
}
