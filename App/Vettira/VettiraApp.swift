import SwiftUI
import VettiraCore

@main
struct VettiraApp: App {
    var body: some Scene {
        MenuBarExtra(Vettira.name, systemImage: "chart.xyaxis.line") {
            MenuBarMenu()
        }
        // Its own scene, so closing it leaves the menu-bar item, and the app, running.
        Window(Vettira.name, id: DashboardView.windowID) {
            DashboardView()
        }
    }
}
