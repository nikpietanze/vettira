/// Whether Vettira shows in the Dock and the app switcher. It's a menu-bar app, so it doesn't,
/// except while one of its windows (the dashboard, Settings) is open, so that window can be found
/// like any app's. A minimized window is still open; closing the last one takes Vettira out of the
/// Dock again, and monitoring carries on either way.
public struct DockPresence: Equatable, Sendable {
    /// The identifiers of the windows that are open.
    public private(set) var openWindows: Set<String> = []

    public init() {}

    public var showsInDock: Bool { !openWindows.isEmpty }

    /// The window opened. Returns whether `showsInDock` changed. Opening one that's open changes nothing.
    @discardableResult
    public mutating func opened(_ window: String) -> Bool {
        let before = showsInDock
        openWindows.insert(window)
        return showsInDock != before
    }

    /// The window closed. Returns whether `showsInDock` changed. Closing one that isn't open changes nothing.
    @discardableResult
    public mutating func closed(_ window: String) -> Bool {
        let before = showsInDock
        openWindows.remove(window)
        return showsInDock != before
    }
}
