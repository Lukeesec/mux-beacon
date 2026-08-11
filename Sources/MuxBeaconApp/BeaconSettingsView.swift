import AppKit
import MuxBeaconCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct BeaconSettingsView: View {
    @AppStorage("notifyOnStart", store: UserDefaults(suiteName: BeaconPreferences.suiteName)) private var notifyOnStart = true
    @AppStorage("notifyOnReady", store: UserDefaults(suiteName: BeaconPreferences.suiteName)) private var notifyOnReady = true
    @AppStorage("notifyOnAttention", store: UserDefaults(suiteName: BeaconPreferences.suiteName)) private var notifyOnAttention = false
    @AppStorage("notifyOnFailure", store: UserDefaults(suiteName: BeaconPreferences.suiteName)) private var notifyOnFailure = true
    @AppStorage("notificationSound", store: UserDefaults(suiteName: BeaconPreferences.suiteName)) private var notificationSound = true
    @AppStorage("storePreviews", store: UserDefaults(suiteName: BeaconPreferences.suiteName)) private var storePreviews = false
    @AppStorage("retentionDays", store: UserDefaults(suiteName: BeaconPreferences.suiteName)) private var retentionDays = 30
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Prompt submitted", isOn: $notifyOnStart)
                Toggle("Turn completed", isOn: $notifyOnReady)
                Toggle("Permission requested", isOn: $notifyOnAttention)
                Toggle("Turn failed", isOn: $notifyOnFailure)
                Toggle("Play sound", isOn: $notificationSound)
                Text("Permission notifications are optional. Install their hooks with mux-beacon install --apply --with-permission-events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Store and show message previews", isOn: $storePreviews)
                Text("Off by default. Mux Beacon otherwise stores only agent, project, timing, state, and tmux routing metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper("Keep records for \(retentionDays) days", value: $retentionDays, in: 1...365)
                HStack {
                    Text("Clockify")
                    Spacer()
                    Text("Provider interface ready")
                        .foregroundStyle(.secondary)
                }
                Text("Direct Clockify credentials and API sync are intentionally deferred; local JSON and CSV exports use the same time-entry model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Open Mux Beacon at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: setLaunchAtLogin
                ))
                Button("Open data folder") { NSWorkspace.shared.open(BeaconPaths.home) }
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 520)
        .alert("Could not update login item", isPresented: Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = error.localizedDescription
        }
    }
}
