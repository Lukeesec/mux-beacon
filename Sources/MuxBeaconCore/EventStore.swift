import CSQLite
import Foundation

public enum EventStoreError: LocalizedError {
    case open(String)
    case statement(String)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .open(let detail): "Could not open Mux Beacon's database: \(detail)"
        case .statement(let detail): "Mux Beacon database operation failed: \(detail)"
        case .encoding: "Could not encode or decode an event."
        }
    }
}

public final class EventStore: @unchecked Sendable {
    public static let historyRetentionDays = 7
    private let databaseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL = BeaconPaths.database) {
        self.databaseURL = databaseURL
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    @discardableResult
    public func record(_ incoming: IncomingAgentEvent, storePreview: Bool = false) throws -> AgentEvent {
        var current = try findCurrent(
            source: incoming.source,
            sessionID: incoming.sessionID,
            turnID: incoming.turnID
        )
        // A hook carrying the prompt ID of a folded continuation belongs to the
        // turn that absorbed it, open or closed.
        if current == nil, let turnID = incoming.turnID {
            current = try findByContinuation(source: incoming.source, sessionID: incoming.sessionID, turnID: turnID)
        }
        // Codex's completion callback uses a different ID namespace than its
        // prompt hook, so an unmatched turn ID still belongs to the session's
        // newest active turn.
        if current == nil, incoming.turnID != nil, incoming.hookEventName != "UserPromptSubmit" {
            current = try findCurrent(source: incoming.source, sessionID: incoming.sessionID, turnID: nil)
        }

        // A turn that already reported a completion is closed. Claude keeps
        // reusing a finished turn's prompt ID until the next prompt arrives, so
        // a late StopFailure — rate limit, overload, server error — would
        // otherwise rewrite a delivered "Ready" into a red "Failed" and notify
        // again for work that had already succeeded.
        if let settled = current, settled.state.isTerminal, settled.completedAt != nil {
            return settled
        }

        let isPrompt = incoming.hookEventName == "UserPromptSubmit"
        let opensTurn = isPrompt && incoming.startsTrackedTurn
        let event: AgentEvent

        if opensTurn {
            let identity = incoming.turnID ?? "\(incoming.timestamp.timeIntervalSince1970)-\(UUID().uuidString)"
            event = AgentEvent(
                id: "\(incoming.source.rawValue):\(incoming.sessionID):\(identity)",
                source: incoming.source,
                sessionID: incoming.sessionID,
                turnID: incoming.turnID,
                state: .working,
                hookEventName: incoming.hookEventName,
                cwd: incoming.cwd,
                projectName: Self.projectName(for: incoming.cwd),
                model: incoming.model,
                createdAt: incoming.timestamp,
                startedAt: incoming.timestamp,
                updatedAt: incoming.timestamp,
                tmux: incoming.tmux,
                ghostty: incoming.ghostty,
                preview: storePreview ? incoming.preview : nil
            )
        } else if isPrompt,
                  var running = try findCurrent(source: incoming.source, sessionID: incoming.sessionID, turnID: nil) {
            // A machine-injected prompt — task notification, auto-continuation,
            // loop or schedule wake-up — is not a new turn. Fold it into the one
            // already in flight so the turn keeps its start time, keeps its
            // unread state, and is never retired as superseded by its own
            // continuation.
            running.state = .working
            running.hookEventName = incoming.hookEventName
            running.updatedAt = incoming.timestamp
            running.model = incoming.model ?? running.model
            running.tmux = running.tmux ?? incoming.tmux
            running.ghostty = running.ghostty ?? incoming.ghostty
            running.absorbContinuation(turnID: incoming.turnID)
            event = running
        } else if var existing = current {
            existing.state = incoming.state
            existing.hookEventName = incoming.hookEventName
            existing.updatedAt = incoming.timestamp
            existing.model = incoming.model ?? existing.model
            existing.tmux = existing.tmux ?? incoming.tmux
            existing.ghostty = existing.ghostty ?? incoming.ghostty
            if storePreview { existing.preview = incoming.preview ?? existing.preview }
            if incoming.state.isTerminal { existing.completedAt = incoming.timestamp }
            event = existing
        } else {
            let identity = incoming.turnID ?? UUID().uuidString
            event = AgentEvent(
                id: "\(incoming.source.rawValue):\(incoming.sessionID):\(identity)",
                source: incoming.source,
                sessionID: incoming.sessionID,
                turnID: incoming.turnID,
                state: incoming.state,
                hookEventName: incoming.hookEventName,
                cwd: incoming.cwd,
                projectName: Self.projectName(for: incoming.cwd),
                model: incoming.model,
                createdAt: incoming.timestamp,
                startedAt: incoming.timestamp,
                updatedAt: incoming.timestamp,
                completedAt: incoming.state.isTerminal ? incoming.timestamp : nil,
                // A terminal event for a session with no tracked prompt is
                // provider chatter (for example Codex automation tasks), not a
                // turn the user is waiting on. A turn opened by a machine-
                // injected prompt after the user's turn already finished is the
                // same thing. Keep both in History without notifying or counting
                // as unread.
                acknowledged: incoming.state.isTerminal || !incoming.startsTrackedTurn,
                isDemo: incoming.isDemo,
                tmux: incoming.tmux,
                ghostty: incoming.ghostty,
                preview: storePreview ? incoming.preview : nil
            )
        }

        try upsert(event)
        if opensTurn {
            _ = try reconcileSupersededEvents(at: incoming.timestamp)
        }
        try pruneExpiredHistory(now: incoming.timestamp)
        return event
    }

    public func upsert(_ event: AgentEvent) throws {
        try withDatabase { db in
            let data = try encoder.encode(event)
            guard let payload = String(data: data, encoding: .utf8) else { throw EventStoreError.encoding }
            let sql = """
            INSERT INTO events (id, source, session_id, turn_id, state, updated_at, acknowledged, logged, is_demo, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              source=excluded.source,
              session_id=excluded.session_id,
              turn_id=excluded.turn_id,
              state=excluded.state,
              updated_at=excluded.updated_at,
              acknowledged=excluded.acknowledged,
              logged=excluded.logged,
              is_demo=excluded.is_demo,
              payload=excluded.payload;
            """
            try execute(db, sql: sql) { statement in
                self.bind(event.id, to: 1, statement: statement)
                self.bind(event.source.rawValue, to: 2, statement: statement)
                self.bind(event.sessionID, to: 3, statement: statement)
                self.bind(event.turnID, to: 4, statement: statement)
                self.bind(event.state.rawValue, to: 5, statement: statement)
                sqlite3_bind_double(statement, 6, event.updatedAt.timeIntervalSince1970)
                sqlite3_bind_int(statement, 7, event.acknowledged ? 1 : 0)
                sqlite3_bind_int(statement, 8, event.logged ? 1 : 0)
                sqlite3_bind_int(statement, 9, event.isDemo ? 1 : 0)
                self.bind(payload, to: 10, statement: statement)
            }
        }
    }

    public func fetch(id: String) throws -> AgentEvent? {
        try queryOne("SELECT payload FROM events WHERE id = ? LIMIT 1", values: [id])
    }

    public func fetchEvents(limit: Int = 100) throws -> [AgentEvent] {
        try withDatabase { db in
            var statement: OpaquePointer?
            let sql = "SELECT payload FROM events ORDER BY updated_at DESC, rowid DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw EventStoreError.statement(errorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var events: [AgentEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let event = decodeColumn(statement, index: 0) { events.append(event) }
            }
            return events
        }
    }

    public func latestActionable() throws -> AgentEvent? {
        try withDatabase { db in
            let sql = """
            SELECT payload FROM events
            WHERE state IN ('ready', 'needsAttention', 'failed') AND acknowledged = 0
            ORDER BY updated_at DESC LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw EventStoreError.statement(errorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return decodeColumn(statement, index: 0)
        }
    }

    public func activeEvent(source: AgentSource, sessionID: String) throws -> AgentEvent? {
        try findCurrent(source: source, sessionID: sessionID, turnID: nil)
    }

    public func acknowledge(id: String) throws {
        guard var event = try fetch(id: id) else { return }
        event.acknowledged = true
        event.updatedAt = Date()
        try upsert(event)
    }

    public func markLogged(id: String) throws {
        guard var event = try fetch(id: id) else { return }
        event.logged = true
        event.updatedAt = Date()
        try upsert(event)
    }

    public func markStale(id: String, at timestamp: Date = Date()) throws {
        guard var event = try fetch(id: id) else { return }
        event.state = .stale
        event.completedAt = event.completedAt ?? timestamp
        event.updatedAt = timestamp
        event.acknowledged = true
        try upsert(event)
    }

    @discardableResult
    public func reconcileSupersededEvents(at timestamp: Date = Date()) throws -> Int {
        var seenTargets = Set<String>()
        var changed = 0
        for var event in try fetchEvents(limit: 1_000) where !event.isDemo {
            if event.state == .stale, !event.acknowledged {
                event.acknowledged = true
                try upsert(event)
                changed += 1
                continue
            }
            guard
                [.working, .background, .needsAttention].contains(event.state),
                let target = event.tmux
            else { continue }
            let key = "\(target.socketPath)\u{1f}\(target.paneID)"
            if seenTargets.insert(key).inserted { continue }
            event.state = .stale
            event.completedAt = event.completedAt ?? timestamp
            event.updatedAt = timestamp
            event.acknowledged = true
            try upsert(event)
            changed += 1
        }
        return changed
    }

    public func deleteDemoEvents() throws {
        try withDatabase { db in
            try execute(db, sql: "DELETE FROM events WHERE is_demo = 1")
        }
    }

    public func pruneExpiredHistory(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.historyRetentionDays * 24 * 60 * 60))
        try withDatabase { db in
            try execute(
                db,
                sql: """
                DELETE FROM events
                WHERE updated_at < ?
                  AND (state = 'stale' OR (acknowledged = 1 AND state NOT IN ('working', 'background')))
                """
            ) { statement in
                sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            }
        }
    }

    public func timeEntries(includeLogged: Bool = true) throws -> [TimeEntryDraft] {
        try fetchEvents(limit: 10_000)
            .filter { $0.completedAt != nil && (includeLogged || !$0.logged) }
            .map(TimeEntryDraft.init(event:))
    }

    /// Turns own the prompt IDs of the continuations folded into them, but those
    /// IDs never reach the indexed `turn_id` column, so this scans the session's
    /// recent records instead.
    private func findByContinuation(source: AgentSource, sessionID: String, turnID: String) throws -> AgentEvent? {
        try withDatabase { db in
            let sql = "SELECT payload FROM events WHERE source = ? AND session_id = ? ORDER BY updated_at DESC LIMIT 50"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw EventStoreError.statement(errorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            bind(source.rawValue, to: 1, statement: statement)
            bind(sessionID, to: 2, statement: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let event = decodeColumn(statement, index: 0) else { continue }
                if event.continuationTurnIDs?.contains(turnID) == true { return event }
            }
            return nil
        }
    }

    private func findCurrent(source: AgentSource, sessionID: String, turnID: String?) throws -> AgentEvent? {
        try withDatabase { db in
            let sql: String
            let values: [String]
            if let turnID {
                sql = "SELECT payload FROM events WHERE source = ? AND session_id = ? AND turn_id = ? ORDER BY updated_at DESC LIMIT 1"
                values = [source.rawValue, sessionID, turnID]
            } else {
                sql = "SELECT payload FROM events WHERE source = ? AND session_id = ? AND state IN ('working','needsAttention','background') ORDER BY updated_at DESC LIMIT 1"
                values = [source.rawValue, sessionID]
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw EventStoreError.statement(errorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in values.enumerated() { bind(value, to: Int32(offset + 1), statement: statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return decodeColumn(statement, index: 0)
        }
    }

    private func queryOne(_ sql: String, values: [String]) throws -> AgentEvent? {
        try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw EventStoreError.statement(errorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in values.enumerated() { bind(value, to: Int32(offset + 1), statement: statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return decodeColumn(statement, index: 0)
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: databaseURL.deletingLastPathComponent().path
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            defer { if db != nil { sqlite3_close(db) } }
            throw EventStoreError.open(db.map(errorMessage) ?? "unknown error")
        }
        defer { sqlite3_close(db) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        sqlite3_busy_timeout(db, 1_500)
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        try migrate(db)
        return try body(db)
    }

    private func migrate(_ db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS events (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          session_id TEXT NOT NULL,
          turn_id TEXT,
          state TEXT NOT NULL,
          updated_at REAL NOT NULL,
          acknowledged INTEGER NOT NULL DEFAULT 0,
          logged INTEGER NOT NULL DEFAULT 0,
          is_demo INTEGER NOT NULL DEFAULT 0,
          payload TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_updated ON events(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_events_session ON events(source, session_id, turn_id);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw EventStoreError.statement(errorMessage(db))
        }
    }

    private func execute(
        _ db: OpaquePointer,
        sql: String,
        bindings: ((OpaquePointer) -> Void)? = nil
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw EventStoreError.statement(errorMessage(db))
        }
        defer { sqlite3_finalize(statement) }
        bindings?(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw EventStoreError.statement(errorMessage(db))
        }
    }

    private func bind(_ value: String?, to index: Int32, statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.transient)
        }
    }

    private func decodeColumn(_ statement: OpaquePointer?, index: Int32) -> AgentEvent? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return try? decoder.decode(AgentEvent.self, from: Data(String(cString: bytes).utf8))
    }

    private func errorMessage(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }

    private static func projectName(for cwd: String) -> String {
        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

public extension Notification.Name {
    static let muxBeaconEventsChanged = Notification.Name("com.lukeesec.MuxBeacon.eventsChanged")
}

public enum EventBroadcaster {
    public static func post(eventID: String) {
        DistributedNotificationCenter.default().post(
            name: .muxBeaconEventsChanged,
            object: eventID,
            userInfo: nil
        )
    }
}
