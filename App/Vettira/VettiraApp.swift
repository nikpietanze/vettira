import AppKit
import SwiftUI
import VettiraCore

@main
struct VettiraApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    // The menu-bar item, its popover, the dashboard and Settings are AppKit's (MenuBarController).
    // An app needs a scene; a Settings scene opens no window at launch. The app menu's Settings…
    // (Cmd-,), there while a window is open, opens MenuBarController's.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings\u{2026}") { delegate.showSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}

/// Owns the app's state and its menu-bar item from launch until Quit, whatever windows are open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = Self.launchOptions
        let state = AppState(options: options)
        self.state = state
        #if DEBUG
        if let snapshot = options.snapshot {
            // Renders the views offscreen, then quits: no menu-bar item, no window on screen.
            let menuBar = MenuBarController(state: state, remembersFrames: false, inMenuBar: false)
            self.menuBar = menuBar
            SnapshotRenderer(state: state, button: menuBar.button, snapshot: snapshot).start()
            return
        }
        #endif
        menuBar = MenuBarController(state: state, remembersFrames: options.remembersWindowFrames)
    }

    func showSettings() {
        menuBar?.showSettings()
    }

    /// Only a Debug build reads its launch options (`--demo`, `--settings-dir`, `--notify`,
    /// `--snapshot`, or their environment variables).
    private static var launchOptions: LaunchOptions {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return LaunchOptions.launch(
            ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
            debugBuild: debugBuild)
    }
}
