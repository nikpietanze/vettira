/// A source of quotes.
///
/// Everything past the provider (polling, session highs, alerts, the app) depends on this protocol
/// and on `Quote`, never on a particular provider, so another provider, a streaming one included,
/// can be added without changing them.
public protocol MarketDataProvider: Sendable {
    /// The provider's name, shown as each quote's source and in Settings.
    var name: String { get }

    /// Whether the provider pushes quotes as they change. When it doesn't, quotes are polled.
    var streams: Bool { get }

    /// The latest quotes for `symbols`, fetched in as few requests as the provider allows.
    ///
    /// Symbols the provider doesn't know come back in the batch's `unknownSymbols`, and symbols it
    /// returned without a usable price or time in its `unusableSymbols`, rather than failing the
    /// whole batch. Only a response that can't be read at all fails it.
    func quotes(for symbols: [String]) async throws(ProviderError) -> QuoteBatch

    /// Checks that the provider can be reached and returns quotes, for Settings' Test Connection.
    /// Throws the error that stops it.
    func testConnection() async throws(ProviderError)
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
