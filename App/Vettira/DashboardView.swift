import SwiftUI
import VettiraCore

/// The dashboard window's content (`MenuBarController` makes the window). It reads the app's state like the popover does, so closing it stops
/// nothing and reopening it shows the same state.
struct DashboardView: View {
    static let windowID = "dashboard"
    let state: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    SymbolList(state: state, rows: state.rows(at: context.date))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HealthView(health: state.health(at: context.date))
                SourceNote(source: state.snapshot.diagnostics.source)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
