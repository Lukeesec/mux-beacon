import SwiftUI

@main
struct MuxBeaconApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BeaconAppModel()

    var body: some Scene {
        MenuBarExtra {
            BeaconPanel(model: model)
        } label: {
            Label("Mux Beacon", systemImage: model.menuBarSymbol)
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Mux Beacon", id: "preview") {
            BeaconPanel(model: model, isStandalone: true)
                .frame(minWidth: 430, minHeight: 580)
        }
        .defaultSize(width: 450, height: 620)

        Settings {
            BeaconSettingsView()
        }
    }
}
