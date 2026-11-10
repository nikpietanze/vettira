import AppKit
import Observation
import os
import SwiftUI
import VettiraCore

/// The menu-bar item, its popover, and the dashboard and Settings windows, in AppKit: an
/// `NSStatusItem` whose button toggles a transient `NSPopover`, each hosting the SwiftUI views. A
/// window-style `MenuBarExtra` opens its panel only on a real mouse event, so neither
/// accessibility (VoiceOver, UI scripts) nor the app itself could open it; this button's action is
/// the one a click, a press and VoiceOver all take. They read `AppState`, which the app owns, so
/// closing the popover or a window stops nothing.
///
/// While a window is open Vettira shows in the Dock and the app switcher, so the window can be
/// found like any app's; once the last one closes it's a menu-bar item only again (`DockPresence`).
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let state: AppState
    /// The menu-bar item: none in a snapshot run, which puts nothing on screen.
    private let item: NSStatusItem?
    /// What the menu bar shows: the item's button, or in a snapshot run one that's never on
    /// screen, which `SnapshotRenderer` draws.
    let button: NSButton
    private let popover = NSPopover()
    /// The windows made so far, by identifier, kept when they're closed.
    private var windows: [String: NSWindow] = [:]
    private var dock = DockPresence()
    /// Whether windows reopen where they were left (`LaunchOptions.remembersWindowFrames`).
    private let remembersFrames: Bool
    private let log = Logger(subsystem: "com.andiamosoftware.vettira", category: "menu-bar")

    /// `inMenuBar` false makes no menu-bar item, only the button it would have, off screen.
    init(state: AppState, remembersFrames: Bool, inMenuBar: Bool = true) {
        self.state = state
        self.remembersFrames = remembersFrames
        if inMenuBar {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.item = item
            button = item.button ?? NSButton()
        } else {
            item = nil
            button = NSButton(title: "", target: nil, action: nil)
            button.isBordered = false
            button.font = .menuBarFont(ofSize: 0)
        }
        super.init()
        popover.behavior = .transient
        let content = NSHostingController(
            rootView: MenuBarPopover(
                state: state, openDashboard: { [weak self] in self?.showDashboard() },
                openSettings: { [weak self] in self?.showSettings() }))
        // The popover takes the content's size and follows it as rows and warnings come and go.
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        button.imagePosition = .imageLeading
        if item != nil {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        render()
    }

    /// Shows the menu-bar status, and again each time it changes.
    private func render() {
        let status = withObservationTracking {
            state.menuBar
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        let button = button
        #if DEBUG
        let changed = button.title != status.title
        #endif
        button.image = NSImage(systemSymbolName: status.indicator.systemImage, accessibilityDescription: nil)
        button.title = status.title
        button.toolTip = status.detail
        // The label names the item whatever it shows; the value is its status. The button's cell
        // is the element accessibility reads, so both get them.
        for element in [button, button.cell].compactMap({ $0 as? NSAccessibilityProtocol & NSObject }) {
            element.setAccessibilityLabel(Vettira.name)
            element.setAccessibilityValue(status.detail)
        }
        #if DEBUG
        if changed { log.info("Menu-bar item accessibility: label \(button.cell?.accessibilityLabel() ?? "none", privacy: .public), title \(button.cell?.accessibilityTitle() ?? "none", privacy: .public)") }
        #endif
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // So the popover's controls take the keyboard, as they do after a click.
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Opens the dashboard, made the first time and kept when it's closed.
    func showDashboard() {
        show(DashboardView.windowID, title: Vettira.name) { [state] in
            DashboardView(state: state, openSettings: { [weak self] in self?.showSettings() })
        }
    }

    /// Opens Settings, made the first time and kept when it's closed.
    func showSettings() {
        show(SettingsView.windowID, title: "\(Vettira.name) Settings", firstSize: SettingsView.firstSize) { [state] in
            SettingsView(state: state)
        }
    }

    private func show(_ id: String, title: String, firstSize: NSSize? = nil, content: () -> some View) {
        popover.performClose(nil)
        let window = windows[id] ?? makeWindow(id, title: title, firstSize: firstSize, content: content())
        windows[id] = window
        if dock.opened(id) { applyDockPresence() }
        window.makeKeyAndOrderFront(nil)
        // A menu-bar app isn't active, so its window would open behind the frontmost app.
        NSApp.activate()
    }

    /// `firstSize` is the content size the first time the window opens, made no taller than the
    /// screen has room for; after that it opens with the frame it last had, unless the run is a
    /// check, which neither reads nor saves frames.
    private func makeWindow(_ id: String, title: String, firstSize: NSSize?, content: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.setAccessibilityIdentifier(id)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Closing hides it; the app, and monitoring, keep running.
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !(remembersFrames && window.setFrameUsingName(id)) {
            if let firstSize, let screen = window.screen ?? NSScreen.main {
                let room = window.contentRect(forFrameRect: screen.visibleFrame).height
                window.setContentSize(NSSize(width: firstSize.width, height: min(firstSize.height, room)))
            }
            window.center()
        }
        if remembersFrames { window.setFrameAutosaveName(id) }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let id = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        if dock.closed(id) { applyDockPresence() }
    }

    private func applyDockPresence() {
        NSApp.setActivationPolicy(dock.showsInDock ? .regular : .accessory)
        log.notice("Dock: \(self.dock.showsInDock ? "shown" : "hidden", privacy: .public), windows open: \(self.dock.openWindows.sorted().joined(separator: ", "), privacy: .public)")
    }
}

extension MenuBarStatus.Indicator {
    var systemImage: String {
        switch self {
        case .empty, .notMonitored, .waiting, .live: "chart.xyaxis.line"
        case .pullback(.early): "arrow.down.right"
        case .pullback(.strong): "arrow.down.right.circle.fill"
        case .closed: "moon.zzz"
        case .stale: "hourglass"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}
