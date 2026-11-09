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
    let staleTolerance = AlertSettings.standard.staleTolerance

    enum LaunchAtLogin {
        case off, on
        /// Registered, but the user has to allow it in System Settings, Login Items.
        case needsApproval
    }

    @ObservationIgnored private var store: SettingsStore?
    @ObservationIgnored private let monitor: QuoteMonitor
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
        do {
            store = try options.settingsDirectory.map(SettingsStore.init(directory:)) ?? SettingsStore.applicationSupport()
        } catch {
            settingsProblem = "Couldn't find Application Support: \(error.localizedDescription)"
        }
        if let loading = store {
            do {
                settings = try loading.load()
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
        var monitorSettings = MonitorSettings.standard
        if options.demo {
            let offset = DemoProvider.regularHoursOffset(at: Date())
            clock = MonitorClock(now: { Date() + offset }, sleep: MonitorClock.system.sleep)
            provider = DemoProvider(now: clock.now)
            monitorSettings = (try? MonitorSettings(interval: MonitorSettings.shortestInterval)) ?? .standard
            clockOffset = offset
        } else {
            clock = .system
            provider = YahooFinanceProvider()
            clockOffset = 0
        }
        monitor = QuoteMonitor(provider: provider, settings: settings, monitorSettings: monitorSettings, clock: clock)
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
        MenuBarStatus(settings: settings, snapshot: snapshot, staleTolerance: staleTolerance, now: now)
    }

    /// The watchlist's rows at the Mac's time `date`, for a view that redraws every second.
    func rows(at date: Date) -> [SymbolRow] {
        SymbolRow.rows(
            watchlist: settings.watchlist, snapshot: snapshot, staleTolerance: staleTolerance, now: date + clockOffset)
    }

    func health(at date: Date) -> ConnectionHealth {
        ConnectionHealth(diagnostics: snapshot.diagnostics, now: date + clockOffset)
    }

    // MARK: What the user changes

    func showInMenuBar(_ symbol: TickerSymbol) {
        change { try $0.watchlist.showInMenuBar(symbol) }
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

    private func change(_ edit: (inout UserSettings) throws -> Void) {
        var changed = settings
        do {
            try edit(&changed)
        } catch {
            settingsProblem = error.localizedDescription
            return
        }
        settings = changed
        do {
            try store?.save(changed)
            if store != nil { settingsProblem = nil }
        } catch {
            settingsProblem = error.errorDescription
        }
        Task { [monitor] in await monitor.update(settings: changed) }
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
