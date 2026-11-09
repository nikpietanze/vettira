import AppKit
import Foundation
import Observation
import os
import ServiceManagement
import UserNotifications
import VettiraCore

/// The app's shared state, owned by the app, not by a view: it loads the settings, runs the quote
/// monitor from launch until Quit, keeps its latest snapshot, and posts each alert as a
/// notification. The menu bar, its popover and the dashboard only read it, so closing the
/// dashboard or the popover never stops monitoring.
@Observable @MainActor
final class AppState {
    private(set) var settings: UserSettings
    /// The monitor's latest snapshot.
    private(set) var snapshot: MonitorSnapshot
    /// The monitor's time, moved every few seconds, so the menu bar's staleness keeps up between
    /// polls (the monitor waits up to 15 minutes between them while it backs off).
    private(set) var now: Date
    /// Why the settings couldn't be read or saved, when they couldn't.
    private(set) var settingsProblem: String?
    private(set) var notifications: NotificationAuthorization = .notDetermined
    /// Why the system refused the last notification, when it did.
    private(set) var notificationProblem: String?
    private(set) var launchAtLogin: LaunchAtLogin = .off
    private(set) var launchAtLoginProblem: String?
    /// Settings' Test Connection: not run yet, running, or what it found.
    private(set) var connectionTest: ConnectionTest = .notRun

    enum LaunchAtLogin {
        case off, on
        /// Registered, but the user has to allow it in System Settings, Login Items.
        case needsApproval
    }

    enum ConnectionTest: Equatable {
        case notRun, running
        case done(ConnectionTestReport)
    }

    @ObservationIgnored private var store: SettingsStore?
    @ObservationIgnored private let monitor: QuoteMonitor
    /// The monitor's provider: Test Connection asks it too, so its request waits its turn behind
    /// the monitor's and keeps to the same pacing.
    @ObservationIgnored private let provider: any MarketDataProvider
    @ObservationIgnored private let center: any AlertNotificationCenter
    @ObservationIgnored private let delivery: AlertDelivery
    /// Set as the system notification center's delegate when alerts go there.
    @ObservationIgnored private let presenter: NotificationPresenter?
    /// How far the monitor's clock is from the Mac's: zero but for a demo run.
    @ObservationIgnored private let clockOffset: TimeInterval
    @ObservationIgnored private let log = Logger(subsystem: "com.andiamosoftware.vettira", category: "app")

    init(options: LaunchOptions) {
        var store: SettingsStore?
        var settings = UserSettings.defaults
        // Whether these are the user's settings, not the defaults a file that couldn't be used
        // left the run with.
        var settingsLoaded = false
        do {
            store = try SettingsStore(
                directory: options.storageDirectory(applicationSupport: SettingsStore.applicationSupportDirectory))
        } catch {
            settingsProblem = "Couldn't find Application Support: \(error.localizedDescription)"
        }
        if let loading = store {
            do {
                settings = try loading.load()
                settingsLoaded = true
            } catch {
                settingsProblem = error.errorDescription
                // A file that's there but can't be read is left alone: saving would replace it.
                if case .unreadable = error { store = nil }
            }
        }
        self.store = store
        self.settings = settings

        let provider: any MarketDataProvider
        let clock: MonitorClock
        if options.demo {
            let offset = DemoProvider.regularHoursOffset(at: Date())
            clock = MonitorClock(now: { Date() + offset }, sleep: MonitorClock.system.sleep)
            provider = DemoProvider(now: clock.now)
            clockOffset = offset
        } else {
            clock = .system
            provider = YahooFinanceProvider()
            clockOffset = 0
        }
        self.provider = provider
        // What the alert engine remembers, so a relaunch doesn't alert again for a pullback it
        // already alerted. A file that can't be used is logged and alerts start afresh. Kept only
        // when the settings loaded: a run on the defaults because settings.json couldn't be read
        // or was corrupt has an empty watchlist, which would drop every symbol's saved state.
        let stateLog = Logger(subsystem: "com.andiamosoftware.vettira", category: "alert-state")
        let stateStore = options.keepsAlertState && settingsLoaded
            ? store.map { AlertStateStore(directory: $0.directory) } : nil
        var engineState = ReversalAlertEngine.State()
        if let stateStore {
            do {
                engineState = try stateStore.load()
                stateLog.notice("Alert state: \(engineState.trackedSymbols.count) symbols from \(stateStore.fileURL.path, privacy: .public)")
            } catch {
                stateLog.error("\(error.localizedDescription, privacy: .public)")
            }
        } else {
            stateLog.notice("Alert state: not kept for this run")
        }
        monitor = QuoteMonitor(provider: provider, settings: settings, engineState: engineState, clock: clock) { state in
            do {
                try stateStore?.save(state)
            } catch {
                stateLog.error("\(error.localizedDescription, privacy: .public)")
            }
        }
        switch options.notifications {
        case .system:
            center = UserNotificationCenter()
            presenter = NotificationPresenter()
        case .log:
            // A check run: nothing reaches the screen, and no permission is asked for.
            let log = Logger(subsystem: "com.andiamosoftware.vettira", category: "notifications")
            center = LogNotificationCenter { line in log.notice("\(line, privacy: .public)") }
            presenter = nil
        }
        delivery = AlertDelivery(center: center)
        // The monitor's own first snapshot comes through its stream; until then, the same: each
        // enabled symbol waiting for its first quote.
        let waiting = settings.watchlist.entries.filter(\.isEnabled).map { ($0.symbol, SymbolSnapshot(symbol: $0.symbol)) }
        snapshot = MonitorSnapshot(
            symbols: Dictionary(uniqueKeysWithValues: waiting), diagnostics: MonitorDiagnostics(source: provider.name))
        now = Date() + clockOffset
        start()
    }

    // MARK: What the views show

    var menuBar: MenuBarStatus {
        MenuBarStatus(settings: settings, snapshot: snapshot, now: now)
    }

    /// The watchlist's rows at the Mac's time `date`, for a view that redraws every second.
    func rows(at date: Date) -> [SymbolRow] {
        SymbolRow.rows(settings: settings, snapshot: snapshot, now: date + clockOffset)
    }

    func health(at date: Date) -> ConnectionHealth {
        ConnectionHealth(diagnostics: snapshot.diagnostics, now: date + clockOffset)
    }

    func diagnostics(at date: Date) -> DiagnosticsSummary {
        DiagnosticsSummary(diagnostics: snapshot.diagnostics, settings: settings, now: date + clockOffset)
    }

    /// The symbol Test Connection asks for: the menu bar's, or SPY while the watchlist is empty.
    var connectionTestSymbol: TickerSymbol {
        settings.watchlist.menuBarSymbol ?? (try? TickerSymbol("SPY"))!
    }

    // MARK: What the user changes

    // Each change is saved straight away and handed to the monitor. Those that can be refused
    // return why, for the view to show.

    /// Adds what the user typed, checked as a ticker. Returns why it can't, when it can't.
    func addSymbol(_ text: String) -> String? {
        do {
            let symbol = try TickerSymbol(text)
            return change { try $0.watchlist.add(symbol) }
        } catch {
            return error.errorDescription
        }
    }

    func remove(_ symbol: TickerSymbol) {
        change { try $0.watchlist.remove(symbol) }
    }

    /// Moves the dragged symbols to before the row at `offset` in the watchlist as it's listed.
    func move(_ symbols: [TickerSymbol], toOffset offset: Int) {
        let order = settings.watchlist.displayOrder.map(\.symbol)
        let source = IndexSet(symbols.compactMap { order.firstIndex(of: $0) })
        guard !source.isEmpty else { return }
        change { $0.watchlist.move(fromOffsets: source, toOffset: min(offset, order.count)) }
    }

    /// Moves the symbol one place up (`-1`) or down (`1`) the list.
    func move(_ symbol: TickerSymbol, by steps: Int) {
        change { try $0.watchlist.move(symbol, by: steps) }
    }

    func setPinned(_ pinned: Bool, for symbol: TickerSymbol) {
        change { try $0.watchlist.setPinned(pinned, for: symbol) }
    }

    func setEnabled(_ enabled: Bool, for symbol: TickerSymbol) {
        change { try $0.watchlist.setEnabled(enabled, for: symbol) }
    }

    func showInMenuBar(_ symbol: TickerSymbol) {
        change { try $0.watchlist.showInMenuBar(symbol) }
    }

    /// Gives the symbol its own thresholds, from what the user typed. Returns why it can't.
    func setThresholds(early: String, strong: String, for symbol: TickerSymbol) -> String? {
        change { try $0.watchlist.setThresholds(PullbackThresholds(early: early, strong: strong), for: symbol) }
    }

    /// Puts the symbol back on the default thresholds.
    func useDefaultThresholds(for symbol: TickerSymbol) {
        change { try $0.watchlist.setThresholds(nil, for: symbol) }
    }

    /// Sets the default thresholds from what the user typed. Returns why it can't.
    func setDefaultThresholds(early: String, strong: String) -> String? {
        change { $0.defaultThresholds = try PullbackThresholds(early: early, strong: strong) }
    }

    func setUpdateInterval(_ seconds: TimeInterval) {
        change { $0.monitorSettings = try MonitorSettings(interval: seconds) }
    }

    func setStaleTolerance(_ seconds: TimeInterval) {
        change { try $0.setStaleTolerance(seconds) }
    }

    /// Asks the provider for one quote for `connectionTestSymbol`, once at a time, and keeps what
    /// it found. The request waits behind any of the monitor's, at the provider's pacing.
    func testConnection() {
        guard connectionTest != .running else { return }
        connectionTest = .running
        let symbol = connectionTestSymbol
        let tolerance = settings.alertSettings.staleTolerance
        let offset = clockOffset
        Task { [provider] in
            let report = await ConnectionTestReport.run(
                on: provider, symbol: symbol, staleTolerance: tolerance, now: { Date() + offset })
            connectionTest = .done(report)
            log.notice("Test Connection for \(symbol, privacy: .public): \(report.headline, privacy: .public)")
        }
    }

    func setNotificationSound(_ on: Bool) {
        change { $0.notificationSound = on }
    }

    /// Registers or unregisters Vettira as a login item. Off until the user turns it on.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginProblem = nil
        } catch {
            launchAtLoginProblem = error.localizedDescription
        }
        refreshSystemStatus()
    }

    /// Reads back what the user can change outside Vettira, in System Settings: notifications and
    /// the login item. The popover calls it each time it opens.
    func refreshSystemStatus() {
        launchAtLogin = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
        Task {
            notifications = await center.authorization()
        }
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.andiamosoftware.vettira"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Makes the edit, saves it and hands it to the monitor; or returns why the edit was refused,
    /// changing nothing.
    @discardableResult
    private func change(_ edit: (inout UserSettings) throws -> Void) -> String? {
        var changed = settings
        do {
            try edit(&changed)
        } catch {
            return error.localizedDescription
        }
        guard changed != settings else { return nil }
        settings = changed
        do {
            try store?.save(changed)
            if store != nil { settingsProblem = nil }
        } catch {
            settingsProblem = error.errorDescription
        }
        Task { [monitor] in await monitor.update(settings: changed) }
        return nil
    }

    // MARK: Monitoring

    /// Starts monitoring for as long as the app runs: Quit ends the process, and these tasks with it.
    private func start() {
        if let presenter { UNUserNotificationCenter.current().delegate = presenter }
        let monitor = monitor
        Task { await monitor.run() }
        Task { [weak self] in
            for await snapshot in monitor.snapshots {
                self?.receive(snapshot)
            }
        }
        Task { [weak self] in
            for await alert in monitor.alerts {
                await self?.notify(alert)
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.tick()
            }
        }
        Task { [weak self] in
            await self?.prepareNotifications()
        }
        refreshSystemStatus()
        log.notice("Monitoring started: quotes from \(self.snapshot.diagnostics.source, privacy: .public), settings in \(self.store?.directory.path ?? "nowhere", privacy: .public), notifications to \(self.presenter == nil ? "the log" : "the system", privacy: .public)")
    }

    private func receive(_ snapshot: MonitorSnapshot) {
        let before = menuBar.title
        self.snapshot = snapshot
        now = Date() + clockOffset
        menuBarChanged(from: before)
    }

    private func tick() {
        let before = menuBar.title
        now = Date() + clockOffset
        menuBarChanged(from: before)
    }

    private func menuBarChanged(from before: String) {
        let status = menuBar
        guard status.title != before else { return }
        log.info("Menu bar: \(status.title, privacy: .public) | \(status.detail, privacy: .public)")
    }

    /// Asks for permission to notify the first time an alert can come: at launch when a symbol is
    /// monitored. With nothing to monitor it only reads the status, and the first alert asks.
    private func prepareNotifications() async {
        if settings.watchlist.entries.contains(where: \.isEnabled) {
            notifications = await delivery.authorize()
        } else {
            notifications = await center.authorization()
        }
        log.notice("Notifications: \(String(describing: self.notifications), privacy: .public)")
    }

    private func notify(_ alert: ReversalAlert) async {
        log.notice("Alert: \(alert.summary, privacy: .public)")
        switch await delivery.deliver(alert, sound: settings.notificationSound) {
        case .delivered:
            notifications = .allowed
            notificationProblem = nil
            log.notice("Sent \(alert.symbol, privacy: .public)'s \(alert.signal.rawValue, privacy: .public) warning to \(self.presenter == nil ? "the log" : "Notification Center", privacy: .public)")
        case .denied:
            notifications = .denied
            log.notice("Notifications are off: not posted")
        case .failed(let reason):
            notificationProblem = reason
            log.error("The notification wasn't posted: \(reason, privacy: .public)")
        }
    }
}
