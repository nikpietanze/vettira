import AppKit
import SwiftUI
import VettiraCore

@main
struct VettiraApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    // The menu-bar item, its popover and the dashboard are AppKit's (MenuBarController). An app
    // needs a scene; a Settings scene opens no window at launch.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the app's state and its menu-bar item from launch until Quit, whatever windows are open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState(options: Self.launchOptions)
        self.state = state
        menuBar = MenuBarController(state: state)
    }

    /// Only a Debug build reads its launch options (`--demo`, `--settings-dir`, `--notify`, or
    /// their environment variables).
    private static var launchOptions: LaunchOptions {
        #if DEBUG
        LaunchOptions.parse(ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        #else
        LaunchOptions()
        #endif
    }
}
