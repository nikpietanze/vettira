/// A source of quotes.
///
/// Everything past the provider (polling, session highs, alerts, the app) depends on this protocol
/// and on `Quote`, never on a particular provider, so another provider can be added without
/// changing them. A provider is polled; prices pushed between polls come from a `QuoteStream`.
/// It also gives a symbol's price history for the chart, one timeframe at a time, only when asked.
public protocol MarketDataProvider: Sendable {
    /// The provider's name, shown as each quote's source and in Settings.
    var name: String { get }

    /// The latest quotes for `symbols`, fetched in as few requests as the provider allows.
    ///
    /// Symbols the provider doesn't know come back in the batch's `unknownSymbols`, and symbols it
    /// returned without a usable price or time in its `unusableSymbols`, rather than failing the
    /// whole batch. Only a response that can't be read at all fails it.
    func quotes(for symbols: [String]) async throws(ProviderError) -> QuoteBatch

    /// Asks for one quote for `symbol`, for Settings' Test Connection, through the same requests
    /// and pacing as `quotes(for:)`. Throws the error that stops it, the symbol being unknown or
    /// having no usable quote included.
    func testConnection(symbol: String) async throws(ProviderError) -> Quote

    /// `symbol`'s bars over `timeframe`, in one request through the same pacing as `quotes(for:)`,
    /// never alongside one. Throws `.unknownSymbols` for a symbol the provider doesn't know, and
    /// `.noUsableQuote` when it returned nothing for it. Only `ChartHistoryStore` calls it, when the
    /// user opens a timeframe; nothing asks for history in the background.
    func history(for symbol: String, timeframe: ChartTimeframe) async throws(ProviderError) -> PriceHistory
}

extension MarketDataProvider {
    /// One `quotes(for:)` call for the symbol: its quote, or why there's none.
    public func testConnection(symbol: String) async throws(ProviderError) -> Quote {
        let batch = try await quotes(for: [symbol])
        if let quote = batch.quotes.first { return quote }
        if !batch.unknownSymbols.isEmpty { throw .unknownSymbols(batch.unknownSymbols) }
        if !batch.unusableSymbols.isEmpty { throw .noUsableQuote(batch.unusableSymbols) }
        throw .malformedResponse(detail: "no quote for \(symbol)")
    }
}

/// What one request for quotes returned.
public struct QuoteBatch: Sendable, Equatable {
    /// The quotes the provider returned.
    public var quotes: [Quote]
    /// The requested symbols the provider doesn't know.
    public var unknownSymbols: [String]
    /// The symbols the provider returned without a usable price or quote time (a halted or newly
    /// listed symbol, say), so they have no quote this time.
    public var unusableSymbols: [String]

    public init(quotes: [Quote], unknownSymbols: [String] = [], unusableSymbols: [String] = []) {
        self.quotes = quotes
        self.unknownSymbols = unknownSymbols
        self.unusableSymbols = unusableSymbols
    }
}
