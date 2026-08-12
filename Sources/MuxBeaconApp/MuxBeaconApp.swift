import SwiftUI

@main
struct MuxBeaconApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BeaconAppModel.shared

    var body: some Scene {
        MenuBarExtra {
            BeaconPanel(
                model: model,
                openInbox: { appDelegate.openInboxWindow() },
                openSettings: { appDelegate.openSettingsWindow() }
            )
        } label: {
            Label("Mux Beacon", systemImage: model.menuBarSymbol)
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
