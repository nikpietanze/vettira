import SwiftUI
import VettiraCore

/// One symbol in the popover and the dashboard: ticker and high on the left; price, change from
/// the high, and data age or what's wrong on the right; the last warning this session below.
struct SymbolRowView: View {
    let row: SymbolRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 4) {
                    Text(row.symbol.rawValue).bold()
                    if row.isInMenuBar {
                        Image(systemName: "menubar.rectangle")
                            .foregroundStyle(.secondary)
                            .help("Shown in the menu bar")
                            .accessibilityLabel("Shown in the menu bar")
                    }
                }
                Spacer()
                Text(row.price ?? "\u{2014}")
                Text(row.changeFromHigh ?? "")
                    .frame(minWidth: 56, alignment: .trailing)
            }
            .monospacedDigit()
            HStack(alignment: .firstTextBaseline) {
                Text(row.high ?? "No high yet this session")
                Spacer()
                Text(detail)
                    .foregroundStyle(row.isEnabled && row.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let warning = row.lastWarning {
                Label("\(warning): possible reversal, not confirmed", systemImage: "arrow.down.right")
                    .font(.caption)
                    // Wraps in the popover's width rather than cutting the wording off.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(row.isEnabled ? 1 : 0.5)
    }

    /// `5 s old`, `stale · 3 min old`, `market closed · 2 h old`, `waiting`.
    private var detail: String {
        [row.status, row.dataAge.map { "\($0) old" }].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}
