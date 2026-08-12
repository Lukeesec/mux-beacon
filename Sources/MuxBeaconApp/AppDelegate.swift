import AppKit
import MuxBeaconCore
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var previewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var inboxRequestTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "OPEN", title: "Open in Ghostty", options: [])
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

        inboxRequestTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.consumeInboxRequest() }
        }

        if CommandLine.arguments.contains("--screenshot") || ProcessInfo.processInfo.environment["MUX_BEACON_SCREENSHOT_MODE"] == "1" {
            showPreviewWindow()
        }
        consumeInboxRequest()
    }

    func openInboxWindow() {
        showPreviewWindow()
    }

    func openSettingsWindow() {
        activateForWindow()
        if let settingsWindow {
            present(settingsWindow)
            return
        }
        let size = NSSize(width: 540, height: 620)
        let controller = NSHostingController(rootView: BeaconSettingsView())
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mux Beacon Settings"
        window.delegate = self
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 500, height: 500)
        window.center()
        settingsWindow = window
        present(window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func consumeInboxRequest() {
        guard FileManager.default.fileExists(atPath: BeaconPaths.inboxRequest.path) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: BeaconPaths.inboxRequest.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        try? FileManager.default.removeItem(at: BeaconPaths.inboxRequest)
        guard let modifiedAt, Date().timeIntervalSince(modifiedAt) < 10 else { return }
        showPreviewWindow()
    }

    private func showPreviewWindow() {
        activateForWindow()
        if let previewWindow {
            present(previewWindow)
            return
        }
        let model = BeaconAppModel.shared
        let settingsMode = ProcessInfo.processInfo.environment["MUX_BEACON_SCREENSHOT_VIEW"] == "settings"
        let size = settingsMode ? NSSize(width: 540, height: 960) : NSSize(width: 450, height: 620)
        let rootView = settingsMode
            ? AnyView(BeaconSettingsView().frame(width: size.width, height: size.height))
            : AnyView(BeaconPanel(
                model: model,
                isStandalone: true,
                openInbox: { [weak self] in self?.openInboxWindow() },
                openSettings: { [weak self] in self?.openSettingsWindow() }
            ).frame(width: size.width, height: size.height))
        let controller = NSHostingController(rootView: rootView)
        // The settings form paints no material of its own, so the under-titlebar
        // region of a full-size content view captures as a transparent band.
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if !settingsMode { styleMask.insert(.fullSizeContentView) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Mux Beacon"
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.contentViewController = controller
        window.contentMinSize = size
        window.setContentSize(size)
        window.center()
        previewWindow = window
        present(window)

        if let outputPath = ProcessInfo.processInfo.environment["MUX_BEACON_SCREENSHOT_PATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.capture(window: window, outputPath: outputPath)
            }
        }
    }

    private func activateForWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(_ window: NSWindow) {
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            self.activateForWindow()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window === previewWindow { previewWindow = nil }
            if window === settingsWindow { settingsWindow = nil }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.previewWindow == nil, self.settingsWindow == nil else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func capture(window: NSWindow, outputPath: String) {
        guard let view = window.contentView else { return }
        let bounds = view.bounds
        // Render at a fixed 2x so screenshots are identical regardless of the
        // backing scale of whichever screen the window landed on.
        let scale: CGFloat = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        representation.size = bounds.size
        view.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            BeaconLog.write("screenshot export: \(error.localizedDescription)")
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url: url) }
    }

    private func handle(url: URL) {
        guard url.scheme == "muxbeacon" else { return }
        if url.host == "inbox" {
            showPreviewWindow()
            return
        }
        if url.host == "settings" {
            openSettingsWindow()
            return
        }
        guard url.host == "event" else { return }
        // URL.pathComponents already percent-decodes; decoding again corrupts IDs containing "%".
        let eventID = url.pathComponents.dropFirst().joined(separator: "/")
        guard !eventID.isEmpty else { return }
        do {
            let store = EventStore()
            guard let event = try store.fetch(id: eventID) else { return }
            try TargetRouter.jump(to: event)
            try store.acknowledge(id: eventID)
            EventBroadcaster.post(eventID: eventID)
        } catch {
            BeaconLog.write("deep link failed: \(error.localizedDescription)")
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
