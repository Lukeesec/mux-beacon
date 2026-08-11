import AppKit
import MuxBeaconCore
import SwiftUI

struct BeaconPanel: View {
    @ObservedObject var model: BeaconAppModel
    var isStandalone = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.events.isEmpty { emptyState }
            else { eventList }
            Divider()
            footer
        }
        .frame(width: isStandalone ? nil : 420, height: isStandalone ? nil : 560)
        .background(.regularMaterial)
        .alert("Mux Beacon", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14))
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("MUX BEACON")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(1.1)
                Text(model.unreadCount == 0 ? "All agents accounted for" : "\(model.unreadCount) agent\(model.unreadCount == 1 ? "" : "s") waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
            Button {
                (NSApp.delegate as? AppDelegate)?.openInboxWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .help("Open window")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                section("NEEDS ATTENTION", events: model.attention)
                section("READY", events: model.ready)
                section("RUNNING", events: model.running)
                section("RECENT", events: model.recent)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func section(_ title: String, events: [AgentEvent]) -> some View {
        if !events.isEmpty {
            Section {
                ForEach(events) { event in
                    EventRow(
                        event: event,
                        open: { model.jump(event) },
                        acknowledge: { model.acknowledge(event) },
                        markLogged: { model.markLogged(event) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } header: {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 5)
                    .background(.regularMaterial)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "circle.dotted")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 4) {
                Text("No agent activity yet")
                    .font(.headline)
                Text("Install the hooks, or load demo data to explore the inbox.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Load demo data") { model.seedDemo() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Demo") { model.seedDemo() }
                .buttonStyle(.plain)
            Button("Clear demo") { model.clearDemo() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.plain)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }
}

private struct EventRow: View {
    let event: AgentEvent
    let open: () -> Void
    let acknowledge: () -> Void
    let markLogged: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                PulsingStateIcon(event: event, color: stateColor)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(event.projectName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(event.source.displayName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(event.durationLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(event.state.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(stateColor)
                    Text(event.routeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { open() }
            if !event.acknowledged { Button("Acknowledge") { acknowledge() } }
            if event.completedAt != nil && !event.logged { Button("Mark time logged") { markLogged() } }
            Divider()
            Text(event.id)
        }
        .accessibilityLabel("\(event.source.displayName), \(event.projectName), \(event.state.displayName), \(event.durationLabel)")
    }

    private var stateColor: Color {
        switch event.state {
        case .working: .accentColor
        case .needsAttention: .orange
        case .background: .indigo
        case .ready: .green
        case .failed: .red
        case .stale: .secondary
        }
    }
}

private struct PulsingStateIcon: View {
    let event: AgentEvent
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Image(systemName: event.state.symbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .opacity(event.state == .working && pulse ? 0.46 : 1)
            .onAppear {
                guard event.state == .working, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
