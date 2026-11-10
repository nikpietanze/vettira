/// A source that pushes quotes as prices change, over one long-lived connection, alongside a polled
/// `MarketDataProvider`.
///
/// A stream only adds prices between polls: it has no first quote for a symbol until its price
/// next changes, and no day's bars, previous close or session high, so the polled provider still
/// supplies those, and takes over whenever the stream is down. `QuoteStreamer` keeps one
/// connection open for the monitor.
public protocol QuoteStream: Sendable {
    /// The stream's name, shown as each streamed quote's source.
    var name: String { get }

    /// A new connection, subscribed to nothing yet. Nothing is sent until its first
    /// `subscribe(_:)`, which fails if the connection can't be opened.
    func connect() -> any QuoteStreamConnection
}

/// One open connection to a `QuoteStream`.
public protocol QuoteStreamConnection: Sendable {
    /// Adds `symbols` to what the connection streams.
    func subscribe(_ symbols: [String]) async throws(ProviderError)

    /// Stops streaming `symbols`.
    func unsubscribe(_ symbols: [String]) async throws(ProviderError)

    /// Waits for the next regular-session quote for a subscribed symbol. Throws once the
    /// connection fails or closes; it doesn't reopen.
    func next() async throws(ProviderError) -> Quote

    /// Closes the connection. A `next()` waiting on it throws.
    func close()
}
