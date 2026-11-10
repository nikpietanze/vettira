import Charts
import SwiftUI
import VettiraCore

/// A symbol's chart window, opened by clicking the symbol in the dashboard or the popover: its
/// name, price and change over the period at the top; an area chart with a crosshair that follows
/// the pointer; the timeframes; and the day's figures with Vettira's own (the high, the change
/// from it, the thresholds). What it draws is worked out in Core (`SymbolChart`, `SymbolStats`);
/// history is fetched only when a timeframe is opened (`AppState.history(for:timeframe:)`).
struct SymbolChartView: View {
    static func windowID(_ symbol: TickerSymbol) -> String { "chart-\(symbol.rawValue)" }
    static let firstSize = NSSize(width: 720, height: 600)

    let state: AppState
    let symbol: TickerSymbol
    @State private var timeframe: ChartTimeframe
    /// The last history fetched, for any timeframe.
    @State private var fetched: PriceHistory?
    @State private var loading = false
    @State private var problem: String?
    @State private var hoverX: Double?

    /// `fetched` and `hoverX` let a snapshot show a timeframe already loaded and the crosshair.
    init(
        state: AppState, symbol: TickerSymbol, timeframe: ChartTimeframe = .oneDay, fetched: PriceHistory? = nil,
        hoverX: Double? = nil
    ) {
        self.state = state
        self.symbol = symbol
        _timeframe = State(initialValue: timeframe)
        _fetched = State(initialValue: fetched)
        _hoverX = State(initialValue: hoverX)
    }

    var body: some View {
        let quote = state.state(of: symbol)?.quote
        // 1D shows the polls' 5-minute bars until its minute bars come, or while those are an
        // earlier session's.
        let history = timeframe == .oneDay
            ? ChartHistoryStore.oneDay(fetched: fetched, polled: ChartHistoryStore.polledDay(quote))
            : fetched?.timeframe == timeframe ? fetched : nil
        let chart = history.flatMap { SymbolChart(history: $0, latest: quote, now: state.now) }
        let tint = Color.direction(chart?.direction)
        VStack(alignment: .leading, spacing: 10) {
            header(quote: quote, history: history, chart: chart, tint: tint)
            Group {
                if let chart {
                    AreaChart(chart: chart, hoverX: $hoverX)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                } else {
                    Text("No prices for this period yet.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            TimeframePills(selection: $timeframe, tint: tint)
            StatsGrid(stats: state.stats(for: symbol))
            SourceNote(source: state.snapshot.diagnostics.source)
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 520)
        .onChange(of: timeframe) { hoverX = nil }
        .task(id: Loading(timeframe: timeframe, open: isOpen)) {
            // Windows are kept when closed, so a closed one's view stays: it asks for nothing.
            guard isOpen else { return }
            await load()
            // 1D wakes each minute while its window is open, and in regular hours asks again, so
            // each new minute's bar joins the line; the latest quote's price ends it in between.
            // Opened before the open, it starts asking at the open.
            while timeframe == .oneDay, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ChartTimeframe.refreshInterval))
                if Task.isCancelled { break }
                if timeframe.refreshes(at: state.now) { await load() }
            }
        }
    }

    /// What the loading task follows: the timeframe, and whether the window is open.
    private struct Loading: Equatable {
        let timeframe: ChartTimeframe
        let open: Bool
    }

    private var isOpen: Bool { state.openWindows.contains(Self.windowID(symbol)) }

    private func header(quote: Quote?, history: PriceHistory?, chart: SymbolChart?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(symbol.rawValue).font(.system(size: 13, weight: .semibold))
                Text(quote?.name ?? history?.name ?? state.snapshot.diagnostics.source)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                // The data's age, always: the chart never looks live when it isn't.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let row = state.rows(at: context.date).first { $0.symbol == symbol }
                    Text(age(row))
                        .font(.caption)
                        .foregroundStyle(row.map { $0.isEnabled && $0.isStale } == true ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text((chart?.last ?? quote?.price).map(DisplayFormat.price) ?? "\u{2014}")
                    .font(.system(size: 28, weight: .semibold))
                if let chart {
                    Text(chart.change)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// `Quote 14:00:05 EST · 5 s old`, `market closed · 2 h old`, `off`.
    private func age(_ row: SymbolRow?) -> String {
        guard let row else { return "" }
        let quote = row.quoteTime.map { "Quote \($0)" }
        return [row.status, quote, row.dataAge.map { "\($0) old" }].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// The timeframe's history: from the cache when it's there, otherwise one request, through
    /// the provider's pacing, in turn with the polls.
    private func load() async {
        problem = nil
        loading = false
        if let cached = await state.cachedHistory(for: symbol, timeframe: timeframe) {
            fetched = cached
            return
        }
        loading = true
        // A cancelled load (the user picked another timeframe) leaves the newer one's spinner alone:
        // the request it waited for carries on, and comes back after the newer load started.
        defer { if !Task.isCancelled { loading = false } }
        do {
            let history = try await state.history(for: symbol, timeframe: timeframe)
            if !Task.isCancelled { fetched = history }
        } catch {
            if !Task.isCancelled { problem = "\(error.message) \(error.nextStep)" }
        }
    }
}

/// The price as straight lines from one real bar's close to the next, never smoothed, so it never
/// shows a price that didn't trade, over a fill that fades down, green when the period is up and red
/// when it's down; on 1D the previous close as a dotted line. Hovering shows a crosshair and a
/// tooltip with the time, price, change and volume of the nearest real bar.
private struct AreaChart: View {
    let chart: SymbolChart
    @Binding var hoverX: Double?
    /// Wide enough for the longest time label (`12 Oct`, `Tue 3`).
    private static let labelWidth: CGFloat = 64

    var body: some View {
        let color = Color.direction(chart.direction)
        let hovered = hoverX.flatMap(chart.nearest(toX:))
        let ticks = chart.ticks(atMost: 7)
        Chart {
            ForEach(chart.points) { point in
                AreaMark(
                    x: .value("Time", point.x), yStart: .value("Base", chart.priceDomain.lowerBound),
                    yEnd: .value("Price", point.price), series: .value("Run", point.segment))
                    .interpolationMethod(.linear)
                    .foregroundStyle(.linearGradient(
                        colors: [color.opacity(0.30), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.x), y: .value("Price", point.price), series: .value("Run", point.segment))
                    .interpolationMethod(.linear)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            if let level = chart.previousCloseLine {
                RuleMark(y: .value("Previous close", level))
                    .foregroundStyle(Color.secondary.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.x))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(y: .value("Price", hovered.price))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Time", hovered.x), y: .value("Price", hovered.price))
                    .symbol {
                        Circle().fill(color).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    }
            }
        }
        .chartXScale(domain: chart.xDomain)
        .chartYScale(domain: chart.priceDomain)
        .chartXAxis {
            AxisMarks(values: ticks.map(\.x)) { value in
                AxisValueLabel(collisionResolution: .disabled) {
                    if let x = value.as(Double.self), let tick = ticks.first(where: { abs($0.x - x) < 1e-9 }) {
                        // The label starts just past its mark (4 points); a frame pulled back by
                        // that and half its width centres it under the mark instead.
                        Text(tick.label)
                            .frame(width: Self.labelWidth)
                            .offset(x: -Self.labelWidth / 2 - 4)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                AxisValueLabel {
                    if let price = value.as(Double.self) { Text(DisplayFormat.price(price)) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoverX = proxy.value(atX: location.x - plot.minX, as: Double.self)
                            case .ended:
                                hoverX = nil
                            }
                        }
                    if let hovered, let x = proxy.position(forX: hovered.x) {
                        let width: CGFloat = 132
                        Tooltip(readout: chart.readout(hovered))
                            .frame(width: width, alignment: .leading)
                            .offset(x: plot.minX + (x > plot.width - width - 16 ? x - width - 10 : x + 10), y: plot.minY + 4)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(chart.description)
        .accessibilityIdentifier("symbol-chart")
    }
}

/// The crosshair's tooltip: `13:24 ET`, `741.86  +0.40%`, `Vol 412K`.
private struct Tooltip: View {
    let readout: SymbolChart.Readout

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(readout.time).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(readout.price).fontWeight(.semibold)
                if let change = readout.change {
                    Text(change).foregroundStyle(Color.direction(readout.direction))
                }
            }
            if let volume = readout.volume {
                Text(volume).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .fixedSize()
    }
}

/// 1D, 5D, 1M, 6M, YTD, 1Y, 5Y as pills; the selected one tinted with the chart's colour.
private struct TimeframePills: View {
    @Binding var selection: ChartTimeframe
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ChartTimeframe.allCases) { timeframe in
                let selected = timeframe == selection
                Button { selection = timeframe } label: {
                    Text(timeframe.rawValue)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(selected ? tint.opacity(0.16) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(timeframe.period)
                .accessibilityLabel(timeframe.period)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("timeframe-\(timeframe.rawValue)")
            }
        }
    }
}

/// The day's figures and Vettira's own, four to a row, each label on the left and its value on
/// the right, over a hairline.
private struct StatsGrid: View {
    let stats: SymbolStats

    var body: some View {
        let rows = stride(from: 0, to: stats.items.count, by: 4).map { Array(stats.items[$0..<min($0 + 4, stats.items.count)]) }
        Grid(horizontalSpacing: 20, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index]) { item in
                        VStack(spacing: 0) {
                            HStack {
                                Text(item.label).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(item.value)
                                    .monospacedDigit()
                                    .foregroundStyle(item.tone == .down ? Color.direction(.down) : .primary)
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

extension Color {
    /// System green for up, system red for down, the secondary colour otherwise: up or down over
    /// the period, never buy or sell.
    static func direction(_ direction: PriceChart.Direction?) -> Color {
        switch direction {
        case .up: Color(nsColor: .systemGreen)
        case .down: Color(nsColor: .systemRed)
        case .flat, .unknown, nil: .secondary
        }
    }
}
