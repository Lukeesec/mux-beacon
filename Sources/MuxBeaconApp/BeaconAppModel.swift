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
            events = try store.fetchEvents(limit: 100)
            if let id = notifyEventID, !id.isEmpty, let event = events.first(where: { $0.id == id }) {
                deliverNotificationIfNeeded(event)
            }
            let recentCutoff = Date().addingTimeInterval(-30)
            for event in events where event.updatedAt >= recentCutoff {
                deliverNotificationIfNeeded(event)
            }
            let cutoff = Calendar.current.date(byAdding: .day, value: -preferences.retentionDays, to: Date()) ?? .distantPast
            try store.prune(olderThan: cutoff)
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
        let key = "\(event.id):\(event.state.rawValue)"
        guard !event.isDemo, !event.acknowledged, preferences.shouldNotify(for: event.state), notificationTracker.begin(key) else { return }

        let content = UNMutableNotificationContent()
        let stateLabel: String
        switch event.state {
        case .working: stateLabel = "Started"
        case .needsAttention: stateLabel = "Needs attention"
        case .background: stateLabel = "Background work"
        case .ready: stateLabel = "Ready"
        case .failed: stateLabel = "Failed"
        case .stale: return
        }
        content.title = "\(event.projectName) — \(stateLabel)"
        content.subtitle = event.state == .working
            ? event.source.displayName
            : "\(event.source.displayName) · \(event.durationLabel)"
        content.body = preferences.storePreviews
            ? [event.routeLabel, event.preview].compactMap { $0 }.joined(separator: "\n")
            : event.routeLabel
        content.categoryIdentifier = "AGENT_EVENT"
        content.threadIdentifier = "\(event.source.rawValue):\(event.sessionID)"
        content.summaryArgument = event.projectName
        content.targetContentIdentifier = event.id
        content.userInfo = ["eventID": event.id]
        if preferences.notificationSound { content.sound = .default }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [notificationTracker] settings in
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
                notificationTracker.finish(key, delivered: false)
                return
            }
            center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil)) { error in
                if let error {
                    BeaconLog.write("notification delivery: \(error.localizedDescription)")
                } else {
                    BeaconLog.write("notification queued: \(event.id)")
                }
                notificationTracker.finish(key, delivered: error == nil)
            }
        }
    }
}

private final class NotificationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()

    func begin(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.insert(key).inserted
    }

    func finish(_ key: String, delivered: Bool) {
        guard !delivered else { return }
        lock.lock()
        keys.remove(key)
        lock.unlock()
    }
}
