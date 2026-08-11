import AppKit
import MuxBeaconCore
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
        let acknowledge = UNNotificationAction(identifier: "ACKNOWLEDGE", title: "Acknowledge")
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "AGENT_EVENT",
                actions: [open, acknowledge],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error { BeaconLog.write("notification authorization: \(error.localizedDescription)") }
            center.getNotificationSettings { settings in
                let status: String
                switch settings.authorizationStatus {
                case .authorized: status = "authorized"
                case .denied: status = "denied"
                case .notDetermined: status = "not-determined"
                case .provisional: status = "provisional"
                case .ephemeral: status = "ephemeral"
                @unknown default: status = "unknown"
                }
                try? status.write(to: BeaconPaths.notificationStatus, atomically: true, encoding: .utf8)
            }
        }

        if CommandLine.arguments.contains("--screenshot") || ProcessInfo.processInfo.environment["MUX_BEACON_SCREENSHOT_MODE"] == "1" {
            showPreviewWindow()
        }
    }

    private func showPreviewWindow() {
        let model = BeaconAppModel()
        let settingsMode = ProcessInfo.processInfo.environment["MUX_BEACON_SCREENSHOT_VIEW"] == "settings"
        let size = settingsMode ? NSSize(width: 520, height: 520) : NSSize(width: 450, height: 620)
        let rootView = settingsMode
            ? AnyView(BeaconSettingsView().frame(width: size.width, height: size.height))
            : AnyView(BeaconPanel(model: model, isStandalone: true).frame(width: size.width, height: size.height))
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mux Beacon"
        window.titlebarAppearsTransparent = true
        window.contentViewController = controller
        window.contentMinSize = size
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window

        if let outputPath = ProcessInfo.processInfo.environment["MUX_BEACON_SCREENSHOT_PATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.capture(window: window, outputPath: outputPath)
            }
        }
    }

    private func capture(window: NSWindow, outputPath: String) {
        guard let view = window.contentView else { return }
        let bounds = view.bounds
        guard let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            BeaconLog.write("screenshot export: \(error.localizedDescription)")
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "muxbeacon" && url.host == "event" {
            let eventID = url.pathComponents.dropFirst().joined(separator: "/")
                .removingPercentEncoding ?? ""
            guard !eventID.isEmpty else { continue }
            do {
                let store = EventStore()
                guard let event = try store.fetch(id: eventID) else { continue }
                try TargetRouter.jump(to: event)
                try store.acknowledge(id: eventID)
                EventBroadcaster.post(eventID: eventID)
            } catch {
                BeaconLog.write("deep link failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let eventID = response.notification.request.content.userInfo["eventID"] as? String else { return }
        let store = EventStore()
        do {
            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier, "OPEN":
                if let event = try store.fetch(id: eventID) {
                    try TargetRouter.jump(to: event)
                    try store.acknowledge(id: eventID)
                }
            case "ACKNOWLEDGE":
                try store.acknowledge(id: eventID)
            default:
                return
            }
            if let updated = try store.fetch(id: eventID) { TmuxStateWriter.update(updated) }
            EventBroadcaster.post(eventID: eventID)
        } catch {
            BeaconLog.write("notification action failed: \(error.localizedDescription)")
        }
    }
}
