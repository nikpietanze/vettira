import SwiftUI
import VettiraCore

/// The Settings window's content (`MenuBarController` makes the window; Settings… in the popover,
/// the dashboard and the app menu, or Cmd-, open it): how often to update, how old a quote can
/// be, the default thresholds, where quotes come from with Test Connection, how the menu bar cycles
/// through the watchlist, and the app's switches.
/// Each change is saved as it's made.
struct SettingsView: View {
    static let windowID = "settings"
    /// Tall enough to show Test Connection's result, on a screen with room for it; the form
    /// scrolls in a shorter window.
    static let firstSize = NSSize(width: 520, height: 900)
    let state: AppState

    var body: some View {
        Form {
            Section("Updates") {
                let monitor = state.settings.monitorSettings
                Picker("Update interval", selection: Binding(
                    get: { monitor.interval }, set: { state.setUpdateInterval($0) })) {
                    ForEach(SettingsChoices.updateIntervals(current: monitor.interval)) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                Note("How often Vettira asks for quotes in regular hours: one request for each symbol that's on, "
                    + "one at a time. Outside regular hours it checks every \(DisplayFormat.duration(monitor.closedInterval)), "
                    + "and after an error it waits longer each time. While prices stream in regular hours, it asks "
                    + "every \(DisplayFormat.duration(monitor.streamingInterval)) for the day's chart instead.")
                let tolerance = state.settings.alertSettings.staleTolerance
                Picker("Stale after", selection: Binding(
                    get: { tolerance }, set: { state.setStaleTolerance($0) })) {
                    ForEach(SettingsChoices.staleTolerances(current: tolerance)) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                Note("A quote older than this is stale: Vettira shows it as stale and never alerts on it.")
                if let note = SettingsChoices.toleranceNote(for: state.settings) {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Default thresholds") {
                ThresholdsForm(current: state.settings.defaultThresholds) { early, strong in
                    state.setDefaultThresholds(early: early, strong: strong)
                }
                Note("How far below its high a price has to be for each warning, for every symbol without its own "
                    + "(set those in the dashboard). Illustrative levels, not validated trading signals: an alert is "
                    + "a possible reversal, not advice.")
            }
            Section("Quotes") {
                LabeledContent("Source", value: state.snapshot.diagnostics.source)
                Note("Vettira reads Yahoo Finance's unofficial, undocumented JSON endpoints, and in regular hours "
                    + "its streaming quote feed, which need no key or account. Yahoo doesn't support or endorse them or Vettira, can change or block them at any "
                    + "time, and its terms govern your use of the data. Quotes may be delayed, and aren't real-time "
                    + "or consolidated.")
                Link("Yahoo's Terms of Service", destination: Self.yahooTerms)
                    .font(.caption)
                ConnectionTestView(state: state)
            }
            Section("Menu bar") {
                Picker("Cycle symbols", selection: Binding(
                    get: { state.settings.menuBarCycle }, set: { state.setMenuBarCycle($0) })) {
                    ForEach(MenuBarCycle.intervals(current: state.settings.menuBarCycle), id: \.self) { seconds in
                        Text(seconds.map(DisplayFormat.duration) ?? "Off").tag(seconds)
                    }
                }
                Note("The menu bar shows each symbol that's on in turn, its ticker and price, moving on at this "
                    + "interval; off, it shows only the menu-bar symbol. The digits that changed at a price's last "
                    + "change are green when it rose and red when it fell, up or down, not advice. A stale price, "
                    + "or one from a closed market, is dimmed. Cycling asks for no extra quotes.")
            }
            Section("General") {
                Toggle("Alert sound", isOn: Binding(
                    get: { state.settings.notificationSound }, set: { state.setNotificationSound($0) }))
                Toggle("Launch at Login", isOn: Binding(
                    get: { state.launchAtLogin != .off }, set: { state.setLaunchAtLogin($0) }))
            }
            if let problem = state.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 900)
        .onAppear { state.refreshSystemStatus() }
    }

    private static let yahooTerms = URL(string: "https://legal.yahoo.com/us/en/yahoo/terms/otos/index.html")!
}

/// Test Connection: one quote for the menu-bar symbol, and what came back.
private struct ConnectionTestView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Test Connection") { state.testConnection() }
                    .disabled(state.connectionTest == .running)
                if state.connectionTest == .running {
                    ProgressView().controlSize(.small)
                }
            }
            Note("Asks for one quote for \(state.connectionTestSymbol), in turn with Vettira's own updates.")
            if case .done(let report) = state.connectionTest {
                VStack(alignment: .leading, spacing: 2) {
                    Label(report.headline, systemImage: icon(report.outcome))
                        .foregroundStyle(color(report.outcome))
                    Text(report.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connection-test-result")
            }
        }
    }

    private func icon(_ outcome: ConnectionTestReport.Outcome) -> String {
        switch outcome {
        case .connected: "checkmark.circle"
        case .stale: "hourglass"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func color(_ outcome: ConnectionTestReport.Outcome) -> Color {
        switch outcome {
        case .connected: .primary
        case .stale: .orange
        case .failed: .red
        }
    }
}

/// The early and stronger thresholds as typed percents, applied together, or why they can't be.
struct ThresholdsForm: View {
    let current: PullbackThresholds
    /// Applies what was typed; returns why it can't, when it can't.
    let apply: (_ early: String, _ strong: String) -> String?
    @State private var early = ""
    @State private var strong = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Early warning")
                    TextField("Early warning", text: $early).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("% below the high")
                }
                GridRow {
                    Text("Stronger warning")
                    TextField("Stronger warning", text: $strong).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("% below the high")
                }
            }
            .onSubmit(save)
            HStack {
                Button("Apply", action: save)
                    .disabled(!changed)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear(perform: reset)
        .onChange(of: current) { reset() }
        .onChange(of: early) { problem = nil }
        .onChange(of: strong) { problem = nil }
    }

    private var changed: Bool {
        early != Self.text(current.early) || strong != Self.text(current.strong)
    }

    private func save() {
        problem = apply(early, strong)
    }

    private func reset() {
        early = Self.text(current.early)
        strong = Self.text(current.strong)
        problem = nil
    }

    private static func text(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(0...4)))
    }
}

/// A caption under a setting.
private struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
