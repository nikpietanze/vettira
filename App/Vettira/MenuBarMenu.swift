import AppKit
import SwiftUI
import VettiraCore

struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Dashboard") {
            openWindow(id: DashboardView.windowID)
            // A menu-bar app isn't active, so its window would open behind the frontmost app.
            NSApp.activate()
        }
        Divider()
        Button("Quit \(Vettira.name)") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
