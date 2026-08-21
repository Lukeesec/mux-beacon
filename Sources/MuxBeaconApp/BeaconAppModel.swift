import Combine
import Foundation
import MuxBeaconCore
@preconcurrency import UserNotifications

@MainActor
final class BeaconAppModel: ObservableObject {
    static let shared = BeaconAppModel()

    @Published private(set) var events: [AgentEvent] = []
    @Published var lastError: String?
    @Published private(set) var refreshConfirmed = false

    private let store = EventStore()
    private let preferences = BeaconPreferences.shared
    private let notificationTracker = NotificationTracker()
    private var observer: NSObjectProtocol?
    private var timer: AnyCancellable?
    private var healthTimer: AnyCancellable?
    private var refreshGeneration = 0

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .muxBeaconEventsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let id = notification.object as? String
            Task { @MainActor in self?.reload(notifyEventID: id) }
        }
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.reload() }
        healthTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.performHealthCheck() }
        reload()
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    var unreadCount: Int {
        events.filter { !$0.acknowledged && [.ready, .failed, .needsAttention].contains($0.state) }.count
    }
    var menuBarSymbol: String { unreadCount > 0 ? "dot.radiowaves.left.and.right" : "circle.dotted" }
    var attention: [AgentEvent] { events.filter { $0.state == .needsAttention && !$0.acknowledged } }
    var ready: [AgentEvent] { events.filter { [.ready, .failed].contains($0.state) && !$0.acknowledged } }
    var running: [AgentEvent] { events.filter { [.working, .background].contains($0.state) } }
    var history: [AgentEvent] {
        events.filter {
            $0.state == .stale || ($0.acknowledged && ![.working, .background].contains($0.state))
        }.prefix(30).map { $0 }
    }

    func reload(notifyEventID: String? = nil) {
        do {
            try store.pruneExpiredHistory()
            events = try store.fetchEvents(limit: 100)
            if let id = notifyEventID, !id.isEmpty, let event = events.first(where: { $0.id == id }) {
                deliverNotificationIfNeeded(event)
            }
            let recentCutoff = Date().addingTimeInterval(-30)
            for event in events where event.updatedAt >= recentCutoff {
                deliverNotificationIfNeeded(event)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshManually() {
        performHealthCheck()
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshConfirmed = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.refreshGeneration == generation else { return }
            self.refreshConfirmed = false
        }
    }

    func performHealthCheck() {
        do {
            _ = try EventHealthChecker.run(store: store)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func jump(_ event: AgentEvent) {
        do {
            try TargetRouter.jump(to: event)
            try store.acknowledge(id: event.id)
            if let updated = try store.fetch(id: event.id) { TmuxStateWriter.update(updated) }
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func acknowledge(_ event: AgentEvent) {
        do {
            try store.acknowledge(id: event.id)
            if let updated = try store.fetch(id: event.id) { TmuxStateWriter.update(updated) }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [event.id])
            reload()
        } catch { lastError = error.localizedDescription }
    }

    func markLogged(_ event: AgentEvent) {
        do {
            try store.markLogged(id: event.id)
            reload()
        } catch { lastError = error.localizedDescription }
    }

    private func deliverNotificationIfNeeded(_ event: AgentEvent) {
        let ticket = NotificationTicket(eventID: event.id, state: event.state)
        guard !event.isDemo, !event.acknowledged, preferences.shouldNotify(for: event.state), notificationTracker.begin(ticket) else { return }

        let content = UNMutableNotificationContent()
        let stateLabel: String
        switch event.state {
        case .working: stateLabel = "Started"
        case .needsAttention: stateLabel = "Needs attention"
        // Not a completion: the agent parked itself waiting on a background task
        // and will keep going on its own.
        case .background: stateLabel = "Waiting on background work"
        case .ready: stateLabel = "Ready"
        case .failed: stateLabel = "Failed"
        case .stale: return
        }
        content.title = "\(event.state.notificationGlyph) \(event.projectName) — \(stateLabel)"
        switch event.state {
        case .working: content.subtitle = event.source.displayName
        case .background: content.subtitle = "\(event.source.displayName) · still running · \(event.durationLabel)"
        default: content.subtitle = "\(event.source.displayName) · \(event.durationLabel)"
        }
        content.body = preferences.storePreviews
            ? [event.routeLabel, event.preview].compactMap { $0 }.joined(separator: "\n")
            : event.routeLabel
        content.categoryIdentifier = "AGENT_EVENT"
        content.threadIdentifier = "\(event.source.rawValue):\(event.sessionID)"
        content.targetContentIdentifier = event.id
        content.userInfo = ["eventID": event.id]
        if event.state == .background {
            // A progress note, not a summons: silent, and it never wakes the display.
            content.interruptionLevel = .passive
        } else if preferences.notificationSound {
            content.sound = .default
        }

        let skipWatchedSession = preferences.skipWatchedSession
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [notificationTracker] settings in
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
                notificationTracker.finish(ticket, delivered: false)
                return
            }
            // Checked here rather than on the main actor: it shells out to tmux.
            // The ticket stays consumed, so this is decided once — looking away
            // later does not produce a late banner for work already seen.
            if skipWatchedSession, FocusInspector.isWatching(event) {
                BeaconLog.write("notification skipped, pane is on screen: \(event.id) [\(event.state.rawValue)]")
                return
            }
            center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil)) { error in
                if let error {
                    BeaconLog.write("notification delivery: \(error.localizedDescription)")
                } else {
                    BeaconLog.write("notification queued: \(event.id) [\(event.state.rawValue)]")
                }
                notificationTracker.finish(ticket, delivered: error == nil)
            }
        }
    }
}

private struct NotificationTicket: Sendable {
    var eventID: String
    var state: AgentState

    var key: String { "\(eventID):\(state.rawValue)" }
    var isTerminal: Bool { state.isTerminal }
}

private final class NotificationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()
    private var settled = Set<String>()

    func begin(_ ticket: NotificationTicket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A turn announces its outcome once. Without this, a turn already
        // reported as Ready could be reported again under a different terminal
        // state.
        if ticket.isTerminal, settled.contains(ticket.eventID) { return false }
        guard keys.insert(ticket.key).inserted else { return false }
        if ticket.isTerminal { settled.insert(ticket.eventID) }
        return true
    }

    func finish(_ ticket: NotificationTicket, delivered: Bool) {
        guard !delivered else { return }
        lock.lock()
        keys.remove(ticket.key)
        if ticket.isTerminal { settled.remove(ticket.eventID) }
        lock.unlock()
    }
}
