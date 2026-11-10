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
    private let item: NSStatusItem
    private var button: NSButton { item.button! }
    private let popover = NSPopover()
    /// The windows made so far, by identifier, kept when they're closed.
    private var windows: [String: NSWindow] = [:]
    private var dock = DockPresence()
    /// Whether windows reopen where they were left (`LaunchOptions.remembersWindowFrames`).
    private let remembersFrames: Bool
    private let log = Logger(subsystem: "com.andiamosoftware.vettira", category: "menu-bar")

    init(state: AppState, remembersFrames: Bool) {
        self.state = state
        self.remembersFrames = remembersFrames
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        let content = NSHostingController(
            rootView: MenuBarPopover(
                state: state, openDashboard: { [weak self] in self?.showDashboard() },
                openSettings: { [weak self] in self?.showSettings() },
                openChart: { [weak self] in self?.showChart($0) }))
        // The popover takes the content's size and follows it as rows and warnings come and go.
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        render()
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

    /// Shows the menu-bar status, and again each time it changes.
    private func render() {
        let status = withObservationTracking {
            state.menuBar
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        let button = button
        #if DEBUG
        let changed = button.attributedTitle.string != status.title
        #endif
        button.image = Self.image(status)
        button.attributedTitle = Self.title(status)
        button.toolTip = status.accessibilityValue
        // The label names the item whatever it shows; the value is its status in words, the
        // colours' meaning included. The button's cell is the element accessibility reads, so both get them.
        for element in [button, button.cell].compactMap({ $0 as? NSAccessibilityProtocol & NSObject }) {
            element.setAccessibilityLabel(Vettira.name)
            element.setAccessibilityValue(status.accessibilityValue)
        }
        #if DEBUG
        if changed { log.info("Menu-bar item accessibility: label \(button.cell?.accessibilityLabel() ?? "none", privacy: .public), title \(button.cell?.accessibilityTitle() ?? "none", privacy: .public), appearance \(button.effectiveAppearance.name.rawValue, privacy: .public)") }
        #endif
    }

    /// With nothing to show, the app's icon, so there's still an item to click; otherwise none.
    static func image(_ status: MenuBarStatus) -> NSImage? {
        status.segments.isEmpty ? NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil) : nil
    }

    /// The status's text in the menu bar's font with digits all the same width, so the item
    /// doesn't twitch as a price changes, each piece in its tone's colour: system colours, which follow a light,
    /// dark or highlighted menu bar.
    static func title(_ status: MenuBarStatus) -> NSAttributedString {
        let title = NSMutableAttributedString()
        for segment in status.segments {
            let color: NSColor = switch segment.tone.ink {
            case .label(let opacity): label(opacity: opacity)
            case .green: .systemGreen
            case .red: .systemRed
            }
            title.append(NSAttributedString(string: segment.text, attributes: [.font: font, .foregroundColor: color]))
        }
        return title
    }

    /// The label colour at `opacity` of its own. Dynamic, so it resolves when the button draws, in
    /// the menu bar's appearance, not the app's. `withAlphaComponent` alone would replace the
    /// label colour's own alpha, which is already under 1 (0.7 in a vibrant light one), so 0.75
    /// would make it darker there, not softer.
    private static func label(opacity: Double) -> NSColor {
        guard opacity < 1 else { return .labelColor }
        return NSColor(name: nil) { appearance in
            var label = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
            }
            return label.withAlphaComponent(label.alphaComponent * opacity)
        }
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
            DashboardView(
                state: state, openSettings: { [weak self] in self?.showSettings() },
                openChart: { [weak self] in self?.showChart($0) })
        }
    }

    /// Opens a symbol's chart window, one per symbol, made the first time and kept when it's closed.
    func showChart(_ symbol: TickerSymbol) {
        show(SymbolChartView.windowID(symbol), title: symbol.rawValue, firstSize: SymbolChartView.firstSize) { [state] in
            SymbolChartView(state: state, symbol: symbol)
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
