import Foundation

/// What a launch reads from its storage directory: the settings to run on, and where this run
/// saves them and the alert engine's state.
public struct LaunchStorage: Sendable {
    /// The saved settings, or the defaults when there are none or they couldn't be used.
    public let settings: UserSettings
    /// Why the saved settings couldn't be used, when they couldn't: the run is on the defaults.
    public let problem: SettingsStoreError?
    /// Where changes to the settings are saved: `nil` when `settings.json` is there but couldn't
    /// be read, since a save would replace it.
    public let settingsStore: SettingsStore?
    /// Where the alert engine's state is loaded from and saved to: only when the settings loaded.
    /// A run on the defaults because `settings.json` couldn't be used has an empty watchlist,
    /// whose first poll would drop every symbol's saved state, so it leaves `alert-state.json` as
    /// it is.
    public let alertStateStore: AlertStateStore?

    /// Loads the settings from `store`.
    public init(loading store: SettingsStore) {
        do {
            settings = try store.load()
            problem = nil
        } catch {
            settings = .defaults
            problem = error
        }
        if case .unreadable = problem {
            settingsStore = nil
        } else {
            settingsStore = store
        }
        alertStateStore = problem == nil ? AlertStateStore(directory: store.directory) : nil
    }
}
