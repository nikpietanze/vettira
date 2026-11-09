import SwiftUI
import VettiraCore

/// The dashboard window's content (`MenuBarController` makes the window): the watchlist as a
/// table, with everything about each symbol and the controls to edit it, then the connection's
/// health and diagnostics. It reads the app's state like the popover does, so closing it stops
/// nothing and reopening it shows the same state.
struct DashboardView: View {
    static let windowID = "dashboard"
    let state: AppState
    let openSettings: () -> Void
    @State private var search = ""
    @State private var selection: TickerSymbol?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                AddSymbolField(state: state)
                Spacer()
                TextField("Search", text: $search, prompt: Text("Search symbols"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .accessibilityIdentifier("search")
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let rows = state.rows(at: context.date)
                WatchlistTable(
                    state: state, rows: rows.filter { $0.matches(search) }, searching: !search.isEmpty,
                    selection: $selection)
                    .overlay {
                        if rows.isEmpty {
                            Text("No symbols on the watchlist yet. Add one above.").foregroundStyle(.secondary)
                        } else if !rows.contains(where: { $0.matches(search) }) {
                            Text("No symbol matches \u{201C}\(search)\u{201D}.").foregroundStyle(.secondary)
                        }
                    }
            }
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .top, spacing: 24) {
                    HealthView(health: state.health(at: context.date))
                        .frame(maxWidth: 320, alignment: .leading)
                    DiagnosticsView(summary: state.diagnostics(at: context.date))
                    Spacer()
                    Button("Settings\u{2026}", action: openSettings)
                }
            }
            SourceNote(source: state.snapshot.diagnostics.source)
        }
        .padding()
        .frame(minWidth: 1160, minHeight: 480)
    }
}

/// Adds a symbol from what the user types, saying why when it can't.
private struct AddSymbolField: View {
    let state: AppState
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Symbol", text: $text, prompt: Text("Add a symbol, like SPY"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(add)
                    .accessibilityIdentifier("add-symbol")
                Button("Add", action: add)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: text) { problem = nil }
    }

    private func add() {
        problem = state.addSymbol(text)
        if problem == nil { text = "" }
    }
}

/// Every symbol, pinned first, with its controls: on or off, pinned, shown in the menu bar, its
/// thresholds, moved up or down, removed. Dragging a row reorders the list while it isn't
/// filtered by a search.
private struct WatchlistTable: View {
    let state: AppState
    let rows: [SymbolRow]
    let searching: Bool
    @Binding var selection: TickerSymbol?

    var body: some View {
        Table(of: SymbolRow.self, selection: $selection) {
            TableColumn("On") { row in
                Toggle("Monitor \(row.symbol.rawValue)", isOn: Binding(
                    get: { row.isEnabled }, set: { state.setEnabled($0, for: row.symbol) }))
                    .labelsHidden()
                    .help(row.isEnabled ? "Monitored: turn off to stop updating it" : "Off: turn on to monitor it")
            }
            .width(24)
            TableColumn("Symbol") { row in
                HStack(spacing: 6) {
                    IconButton(
                        row.isPinned ? "Unpin \(row.symbol)" : "Pin \(row.symbol)",
                        systemImage: row.isPinned ? "pin.fill" : "pin", highlighted: row.isPinned
                    ) { state.setPinned(!row.isPinned, for: row.symbol) }
                    Text(row.symbol.rawValue).bold()
                    Spacer(minLength: 0)
                    IconButton(
                        row.isInMenuBar ? "\(row.symbol) is shown in the menu bar" : "Show \(row.symbol) in the menu bar",
                        systemImage: "menubar.rectangle", highlighted: row.isInMenuBar
                    ) { state.showInMenuBar(row.symbol) }
                }
            }
            .width(min: 96, ideal: 104)
            TableColumn("Price") { row in
                Text(row.price ?? "\u{2014}").monospacedDigit()
            }
            .width(min: 56, ideal: 64)
            TableColumn("High") { row in
                Text(row.high ?? "\u{2014}").monospacedDigit()
                    .help("A session high is the provider's; an observed high is the highest Vettira has seen since it started")
            }
            .width(min: 120, ideal: 140)
            TableColumn("From high") { row in
                Text(row.changeFromHigh ?? "\u{2014}").monospacedDigit()
            }
            .width(min: 56, ideal: 64)
            TableColumn("Thresholds") { row in
                ThresholdsButton(state: state, row: row)
            }
            .width(min: 140, ideal: 150)
            TableColumn("Quote time and age") { row in
                HStack(spacing: 6) {
                    Text(row.quoteTime ?? "\u{2014}").monospacedDigit()
                    Text(dataAge(row))
                        .foregroundStyle(row.isEnabled && row.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .lineLimit(1)
            }
            .width(min: 150, ideal: 180)
            TableColumn("Warning this session") { row in
                Text(row.lastWarning ?? "")
                    .lineLimit(1)
                    .help("A possible reversal, not confirmed, and not advice")
            }
            .width(min: 150, ideal: 180)
            TableColumn("") { row in
                HStack(spacing: 4) {
                    IconButton("Move \(row.symbol) up", systemImage: "chevron.up") { state.move(row.symbol, by: -1) }
                    IconButton("Move \(row.symbol) down", systemImage: "chevron.down") { state.move(row.symbol, by: 1) }
                    IconButton("Remove \(row.symbol)", systemImage: "trash") { state.remove(row.symbol) }
                }
            }
            .width(72)
        } rows: {
            ForEach(rows) { row in
                TableRow(row).draggable(row.symbol.rawValue)
            }
            .dropDestination(for: String.self) { offset, dropped in
                guard !searching else { return }
                state.move(dropped.compactMap { try? TickerSymbol($0) }, toOffset: offset)
            }
        }
        .contextMenu(forSelectionType: TickerSymbol.self) { symbols in
            if let symbol = symbols.first, let entry = state.settings.watchlist.entry(for: symbol) {
                Button(entry.isEnabled ? "Turn Off" : "Turn On") { state.setEnabled(!entry.isEnabled, for: symbol) }
                Button(entry.isPinned ? "Unpin" : "Pin") { state.setPinned(!entry.isPinned, for: symbol) }
                Button("Show in Menu Bar") { state.showInMenuBar(symbol) }
                Divider()
                Button("Move Up") { state.move(symbol, by: -1) }
                Button("Move Down") { state.move(symbol, by: 1) }
                Divider()
                Button("Remove \(symbol.rawValue)") { state.remove(symbol) }
            }
        }
        .onDeleteCommand {
            if let selection { state.remove(selection) }
        }
    }

    /// `5 s old`, `stale · 3 min old`, `market closed · 2 h old`, `waiting`.
    private func dataAge(_ row: SymbolRow) -> String {
        [row.status, row.dataAge.map { "\($0) old" }].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

/// A borderless icon button whose label is its accessibility description and tooltip.
private struct IconButton: View {
    let label: String
    let systemImage: String
    var highlighted = false
    let action: () -> Void

    init(_ label: String, systemImage: String, highlighted: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.highlighted = highlighted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A symbol's thresholds, its own or the defaults; clicking it opens their editor.
private struct ThresholdsButton: View {
    let state: AppState
    let row: SymbolRow
    @State private var editing = false

    var body: some View {
        Button {
            editing = true
        } label: {
            HStack(spacing: 4) {
                Text(row.thresholds).monospacedDigit()
                if !row.hasOwnThresholds {
                    Text("default").foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Thresholds for \(row.symbol.rawValue): \(row.thresholds)\(row.hasOwnThresholds ? "" : ", the defaults")")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            SymbolThresholdsEditor(state: state, symbol: row.symbol)
        }
    }
}

/// Gives a symbol its own thresholds, or puts it back on the defaults.
private struct SymbolThresholdsEditor: View {
    let state: AppState
    let symbol: TickerSymbol

    var body: some View {
        let own = state.settings.watchlist.entry(for: symbol)?.thresholds
        VStack(alignment: .leading, spacing: 10) {
            Text("\(symbol.rawValue) thresholds").font(.headline)
            Toggle("Use the defaults (\(DisplayFormat.thresholds(state.settings.defaultThresholds)))", isOn: Binding(
                get: { own == nil },
                set: { useDefaults in
                    if useDefaults {
                        state.useDefaultThresholds(for: symbol)
                    } else {
                        _ = state.setThresholds(
                            early: "\(state.settings.defaultThresholds.early)",
                            strong: "\(state.settings.defaultThresholds.strong)", for: symbol)
                    }
                }))
            if let own {
                ThresholdsForm(current: own) { early, strong in
                    state.setThresholds(early: early, strong: strong, for: symbol)
                }
            }
            Text("Illustrative levels, not validated trading signals.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .fixedSize()
    }
}

/// The diagnostics as a two-column list: label, value.
private struct DiagnosticsView: View {
    let summary: DiagnosticsSummary

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            ForEach(summary.items) { item in
                GridRow {
                    Text(item.label).foregroundStyle(.secondary)
                    Text(item.value).textSelection(.enabled)
                }
            }
        }
        .font(.caption)
        .accessibilityIdentifier("diagnostics")
    }
}
