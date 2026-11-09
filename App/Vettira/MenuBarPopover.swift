import SwiftUI
import VettiraCore

/// The popover the menu-bar item opens: every symbol's price, high, pullback and data age, the
/// connection's health, anything the user has to fix, and the app's switches.
struct MenuBarPopover: View {
    let state: AppState
    let openDashboard: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    SymbolList(state: state, rows: state.rows(at: context.date))
                    Divider()
                    HealthView(health: state.health(at: context.date))
                }
            }
            Problems(state: state)
            Divider()
            Toggle("Alert sound", isOn: Binding(
                get: { state.settings.notificationSound }, set: { state.setNotificationSound($0) }))
            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLogin != .off }, set: { state.setLaunchAtLogin($0) }))
            Divider()
            HStack {
                Button("Open Dashboard", action: openDashboard)
                Button("Settings\u{2026}", action: openSettings)
                Spacer()
                Button("Quit \(Vettira.name)") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            SourceNote(source: state.snapshot.diagnostics.source)
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { state.refreshSystemStatus() }
    }
}

/// The watchlist's rows; clicking one shows it in the menu bar.
struct SymbolList: View {
    let state: AppState
    let rows: [SymbolRow]

    var body: some View {
        if rows.isEmpty {
            Text("No symbols on the watchlist yet.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    Button { state.showInMenuBar(row.symbol) } label: {
                        SymbolRowView(row: row).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(row.symbol.rawValue) in the menu bar")
                }
            }
        }
    }
}

struct HealthView: View {
    let health: ConnectionHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(health.headline, systemImage: icon)
                .foregroundStyle(health.level == .failing ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            if let detail = health.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var icon: String {
        switch health.level {
        case .waiting: "clock"
        case .connected: "dot.radiowaves.left.and.right"
        case .closed: "moon.zzz"
        case .failing: "exclamationmark.triangle"
        }
    }
}

/// What the user has to know or fix: notifications turned off, a settings file Vettira couldn't
/// read, a notification or login item the system refused.
private struct Problems: View {
    let state: AppState

    var body: some View {
        if state.notifications == .denied {
            VStack(alignment: .leading, spacing: 4) {
                Label("Notifications are off for Vettira, so alerts only show here.", systemImage: "bell.slash")
                Button("Open Notification Settings") { state.openNotificationSettings() }
            }
        }
        if let problem = state.notificationProblem {
            Label("The last alert's notification failed: \(problem)", systemImage: "bell.slash")
        }
        if state.launchAtLogin == .needsApproval {
            VStack(alignment: .leading, spacing: 4) {
                Label("Allow Vettira in Login Items to launch it at login.", systemImage: "person.badge.clock")
                Button("Open Login Items") { state.openLoginItemsSettings() }
            }
        }
        if let problem = state.launchAtLoginProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
        }
        if let problem = state.settingsProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where the quotes come from and what they are, under every list of them.
struct SourceNote: View {
    let source: String

    var body: some View {
        Text("Quotes: \(source). They may be delayed, and aren't real-time or consolidated. "
            + "An alert is a possible reversal, not advice.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
