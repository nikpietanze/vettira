import SwiftUI
import VettiraCore

struct DashboardView: View {
    static let windowID = "dashboard"

    var body: some View {
        ContentUnavailableView(
            Vettira.name, systemImage: "chart.xyaxis.line",
            description: Text("Your watchlist will show here."))
            .frame(minWidth: 480, minHeight: 320)
    }
}
