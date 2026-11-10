import Foundation

/// What the menu-bar item shows for one symbol: its ticker and latest price, `SPY 741.12`, the
/// characters that changed at its last change coloured by direction (`PriceChange`); or, dimmed,
/// a price that isn't live (the market closed, stale data), or a sign there's no price (waiting,
/// turned off, no quote). No chart and no words: the detail, for the tooltip and VoiceOver, says
/// it all in words, the price's age and any warning the price is still past included.
public struct MenuBarStatus: Equatable, Sendable {
    public enum Indicator: Equatable, Sendable {
        /// The watchlist is empty, so there's no symbol to show.
        case empty
        /// The symbol is turned off, so it isn't monitored.
        case notMonitored
        /// No quote for it yet.
        case waiting
        /// A fresh regular-session quote.
        case live
        /// A warning fired this session and the price is still past a threshold: the larger one
        /// it's past, up to the warning that fired. A possible reversal, not a confirmed one.
        case pullback(PullbackSignal)
        /// Outside the regular session, so the price is the last session's and nothing alerts.
        case closed
        /// The quote is too old to alert on.
        case stale
        /// The provider has no quote for the symbol, or the last update failed before one came.
        case unavailable
    }

    /// How a piece of the menu bar's text is drawn.
    public enum Tone: Equatable, Sendable {
        /// The menu bar's own text colour.
        case normal
        /// Characters that changed when the price last rose: system green.
        case up
        /// Characters that changed when the price last fell: system red.
        case down
        /// The secondary text colour: a price that isn't live, or no price.
        case dimmed
    }

    public struct Segment: Equatable, Sendable {
        public let text: String
        public let tone: Tone

        public init(_ text: String, _ tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    /// The symbol shown, or `nil` when the watchlist is empty.
    public let symbol: TickerSymbol?
    /// The menu bar's text in pieces, each with its tone: `SPY 74` normal then `1.12` green.
    /// Empty when there's no symbol.
    public private(set) var segments: [Segment]
    public let indicator: Indicator
    /// A sentence saying the same in full.
    public let detail: String
    /// The price's last change in words, when its colours show: `Last change: up from 740.43.`
    public private(set) var changeDescription: String?

    /// The menu bar's text: `SPY 741.12`, `SPY …`; empty when there's no symbol.
    public var title: String { segments.map(\.text).joined() }

    /// Everything the item says, for the tooltip and VoiceOver: `detail`, then the last change.
    public var accessibilityValue: String {
        [detail, changeDescription].compactMap { $0 }.joined(separator: " ")
    }

    /// The status of `symbol` (the menu-bar symbol by default) at `now`, coloured by its last
    /// change in `changes`. A quote older than the settings' staleness tolerance is stale.
    public init(
        settings: UserSettings, snapshot: MonitorSnapshot, now: Date, showing symbol: TickerSymbol? = nil,
        changes: PriceChanges = PriceChanges(), calendar: MarketCalendar = .usEquities
    ) {
        self.init(text: settings, symbol: symbol ?? settings.watchlist.menuBarSymbol, snapshot: snapshot, now: now,
                  calendar: calendar)
        guard let symbol = self.symbol, let price = snapshot.symbols[symbol]?.quote?.price,
              let change = changes[symbol], change.to == DisplayFormat.price(price)
        else { return }
        switch indicator {
        case .live, .pullback:
            let tone: Tone = change.direction == .up ? .up : .down
            segments = [Segment("\(symbol) \(change.unchanged)", .normal), Segment(String(change.changed), tone)]
                .filter { !$0.text.isEmpty }
            changeDescription = "Last change: \(change.direction == .up ? "up" : "down") from \(change.from)."
        default:
            break
        }
    }

    private init(
        text settings: UserSettings, symbol: TickerSymbol?, snapshot: MonitorSnapshot, now: Date,
        calendar: MarketCalendar
    ) {
        let staleTolerance = settings.alertSettings.staleTolerance
        guard let symbol else {
            self.init(nil, [], .empty, "The watchlist is empty, so there's no symbol to show.")
            return
        }
        func dimmed(_ text: String) -> [Segment] { [Segment("\(symbol) \(text)", .dimmed)] }
        guard let state = snapshot.symbols[symbol] else {
            self.init(symbol, dimmed("off"), .notMonitored, "\(symbol) is turned off, so it isn't monitored.")
            return
        }
        guard let quote = state.quote else {
            if let problem = state.problem {
                self.init(symbol, dimmed("\u{2014}"), .unavailable, problem.sentence(for: symbol))
            } else if let error = snapshot.diagnostics.lastError {
                self.init(symbol, dimmed("\u{2014}"), .unavailable, "No quote for \(symbol): \(error.message)")
            } else {
                self.init(symbol, dimmed("\u{2026}"), .waiting, "Waiting for the first quote for \(symbol).")
            }
            return
        }
        let price = DisplayFormat.price(quote.price)
        let age = DisplayFormat.duration(quote.age(at: now))
        // Dimmed when it isn't live, so it never looks it; until it changes, a live price is all
        // the menu bar's own colour.
        let title = [Segment("\(symbol) \(price)", .normal)]
        if snapshot.diagnostics.marketState != .regular {
            self.init(
                symbol, dimmed(price), .closed,
                "\(symbol) \(price), the last regular-session price. The market is closed, so nothing alerts. "
                    + "Quote \(age) old.")
        } else if state.isStale(at: now, tolerance: staleTolerance) {
            self.init(symbol, dimmed(price), .stale, "\(symbol) \(price): the quote is \(age) old, too old to alert on.")
        } else if let high = state.high, let pullback = state.pullbackPercent {
            let position = "\(symbol) \(price) is \(DisplayFormat.percent(pullback)) below its \(high.kind.label) of "
                + "\(DisplayFormat.price(high.price)). Quote \(age) old."
            let thresholds = settings.thresholds(for: symbol) ?? settings.defaultThresholds
            let past: PullbackSignal? = pullback >= thresholds.strong ? .strong : pullback >= thresholds.early ? .early : nil
            if let alert = state.alertThisSession(at: now, calendar: calendar), let past {
                let signal = min(past, alert.signal)
                self.init(
                    symbol, title, .pullback(signal), "\(signal.label): possible reversal, not confirmed. " + position)
            } else {
                self.init(symbol, title, .live, position)
            }
        } else {
            self.init(symbol, title, .live, "\(symbol) \(price). Quote \(age) old.")
        }
    }

    private init(_ symbol: TickerSymbol?, _ segments: [Segment], _ indicator: Indicator, _ detail: String) {
        self.symbol = symbol
        self.segments = segments
        self.indicator = indicator
        self.detail = detail
    }
}

extension SymbolProblem {
    /// A short label: "unknown symbol" or "no usable quote".
    public var label: String {
        switch self {
        case .unknownSymbol: "unknown symbol"
        case .noUsableQuote: "no usable quote"
        }
    }

    func sentence(for symbol: TickerSymbol) -> String {
        switch self {
        case .unknownSymbol: "The provider doesn't recognize \(symbol)."
        case .noUsableQuote: "The provider returned no usable price for \(symbol); it may be halted."
        }
    }
}
