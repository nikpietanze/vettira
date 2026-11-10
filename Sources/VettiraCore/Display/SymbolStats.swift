import Foundation

/// The figures under the symbol chart, whatever timeframe it shows: the day's open, previous close
/// and volume, from the latest quote and the day's bars that came with it; the day's high and low
/// only as the provider supplies them for the regular session; then Vettira's own, the session or
/// observed high (labelled as which it is), the change from it, and the thresholds. A figure
/// Vettira doesn't have is a dash, and none of them needs a request.
public struct SymbolStats: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public enum Tone: Equatable, Sendable {
            case plain
            /// Below the high: the change from it.
            case down
        }

        public var id: String { label }
        public let label: String
        public let value: String
        public let tone: Tone
    }

    /// Open, High, Low, Prev close, Volume, the session or observed high, From high, Thresholds.
    public let items: [Item]

    /// The figures for `state`'s latest quote (none for a symbol that's off or waiting), with
    /// `thresholds`, the symbol's own or the defaults.
    public init(state: SymbolSnapshot?, thresholds: PullbackThresholds) {
        let quote = state?.quote
        let bars = quote?.intraday ?? []
        let open = bars.first(where: { $0.close != nil }).flatMap { $0.open ?? $0.close }
        // The provider's own count for the day; the bars' sum only without it, since bars can
        // leave trades out.
        let volumes = bars.compactMap(\.volume)
        let volume = quote?.dayVolume ?? (volumes.isEmpty ? nil : volumes.reduce(0, +))
        func price(_ value: Double?) -> String { value.map(DisplayFormat.price) ?? "\u{2014}" }

        let sessionHigh = state?.high
        let pullback = state?.pullbackPercent
        items = [
            Item(label: "Open", value: price(open), tone: .plain),
            // Only the provider's: a high Vettira worked out itself is the observed high, below.
            Item(label: "High", value: price(quote?.sessionHigh), tone: .plain),
            Item(label: "Low", value: price(quote?.sessionLow), tone: .plain),
            Item(label: "Prev close", value: price(quote?.previousClose), tone: .plain),
            Item(label: "Volume", value: volume.map(DisplayFormat.volume) ?? "\u{2014}", tone: .plain),
            Item(
                label: sessionHigh?.kind == .session ? "Session high" : "Observed high",
                value: price(sessionHigh?.price), tone: .plain),
            Item(
                label: "From high", value: pullback.map(DisplayFormat.changeFromHigh) ?? "\u{2014}",
                tone: (pullback ?? 0) >= 0.005 ? .down : .plain),
            Item(label: "Thresholds", value: DisplayFormat.thresholds(thresholds), tone: .plain),
        ]
    }
}
