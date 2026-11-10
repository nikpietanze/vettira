import Foundation

/// What `QuoteMonitor` knows after a poll: each enabled symbol's state and the monitor's own
/// health, for the menu bar and the dashboard.
public struct MonitorSnapshot: Equatable, Sendable {
    /// Each enabled symbol on the watchlist. A disabled symbol isn't monitored, so it isn't here.
    public var symbols: [TickerSymbol: SymbolSnapshot]
    public var diagnostics: MonitorDiagnostics

    public init(symbols: [TickerSymbol: SymbolSnapshot], diagnostics: MonitorDiagnostics) {
        self.symbols = symbols
        self.diagnostics = diagnostics
    }
}

/// One symbol's latest quote, its high and pullback, and its last alert.
public struct SymbolSnapshot: Equatable, Sendable {
    public let symbol: TickerSymbol
    /// The latest quote the provider returned, whether or not the alert engine could use it.
    /// `nil` until one comes.
    public var quote: Quote?
    /// How old `quote` was when the snapshot was taken: the data age. The quote's own `timestamp`
    /// gives it at any later moment (`Quote.age(at:)`).
    public var dataAge: TimeInterval?
    /// Whether the data is too old to alert on: no quote yet, a quote older than the staleness
    /// tolerance, or one the provider says is delayed by more. Outside regular hours it turns stale
    /// once the last session's quote is older than the tolerance (by default, a minute after the
    /// close).
    public var isStale: Bool
    /// The high the pullback is measured from, and whether it's the session or the observed high,
    /// for the current trading day's session. `nil` before the session's first usable quote.
    public var high: SessionHigh?
    /// How far the last usable quote this session was below `high`, in percent.
    public var pullbackPercent: Double?
    /// Why the alert engine couldn't use the latest quote (stale, outside regular hours, and so
    /// on); `nil` when it used it, or there's no quote.
    public var lastRejection: QuoteRejection?
    /// The last alert for this symbol since the monitor started.
    public var lastAlert: ReversalAlert?
    /// Why the provider returned no quote for the symbol on the last poll, when it didn't.
    public var problem: SymbolProblem?

    public init(symbol: TickerSymbol) {
        self.symbol = symbol
        isStale = true
    }
}

/// Why the provider returned no quote for a symbol.
public enum SymbolProblem: Equatable, Sendable {
    /// The provider doesn't know the symbol.
    case unknownSymbol
    /// The provider returned it without a usable price or quote time (halted, newly listed).
    case noUsableQuote
}

/// How the monitor is doing: where its data comes from, when it last got some, and what's
/// slowing it down.
public struct MonitorDiagnostics: Equatable, Sendable {
    /// The provider's name.
    public var source: String
    /// The market's session state at the last poll; `nil` before the first poll, or when the
    /// market calendar doesn't cover the date (so no session, and no alerts).
    public var marketState: SessionState?
    /// When the last poll finished, by the Mac's clock.
    public var lastPoll: Date?
    /// When quotes last came back from the provider, by the Mac's clock.
    public var lastReceived: Date?
    /// How long the monitor waits after the last poll before the next: the update interval in
    /// regular hours, the slow check outside them, longer while backing off.
    public var pollDelay: TimeInterval?
    /// When the next poll is due.
    public var nextPoll: Date?
    /// The error the last poll failed with; `nil` once a poll succeeds.
    public var lastError: ProviderError?
    /// How many polls in a row have failed; the backoff grows with it.
    public var consecutiveFailures: Int
    /// How the streaming connection is doing; `nil` when nothing streams, as with the demo's
    /// made-up prices, or before the streamer first says.
    public var stream: StreamStatus?

    public init(source: String) {
        self.source = source
        consecutiveFailures = 0
    }
}
