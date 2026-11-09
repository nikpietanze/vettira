import AppKit
import Observation
import os
import SwiftUI
import VettiraCore

/// The menu-bar item, its popover and the dashboard window, in AppKit: an `NSStatusItem` whose
/// button toggles a transient `NSPopover`, each hosting the SwiftUI views. A window-style
/// `MenuBarExtra` opens its panel only on a real mouse event, so neither accessibility (VoiceOver,
/// UI scripts) nor the app itself could open it; this button's action is the one a click, a press
/// and VoiceOver all take. They read `AppState`, which the app owns, so closing the popover or the
/// dashboard stops nothing.
@MainActor
final class MenuBarController: NSObject {
    private let state: AppState
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var dashboard: NSWindow?
    private let log = Logger(subsystem: "com.andiamosoftware.vettira", category: "menu-bar")

    init(state: AppState) {
        self.state = state
        super.init()
        popover.behavior = .transient
        let content = NSHostingController(
            rootView: MenuBarPopover(state: state, openDashboard: { [weak self] in self?.showDashboard() }))
        // The popover takes the content's size and follows it as rows and warnings come and go.
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
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
        guard let button = item.button else { return }
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
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // So the popover's controls take the keyboard, as they do after a click.
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Opens the dashboard, made the first time and kept when it's closed.
    private func showDashboard() {
        popover.performClose(nil)
        let window = dashboard ?? makeDashboard()
        dashboard = window
        window.makeKeyAndOrderFront(nil)
        // A menu-bar app isn't active, so its window would open behind the frontmost app.
        NSApp.activate()
    }

    private func makeDashboard() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: DashboardView(state: state)))
        window.title = Vettira.name
        window.identifier = NSUserInterfaceItemIdentifier(DashboardView.windowID)
        window.setAccessibilityIdentifier(DashboardView.windowID)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Closing hides it; the app, and monitoring, keep running.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName(DashboardView.windowID)
        return window
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
