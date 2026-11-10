import Foundation

/// Keeps one connection to a `QuoteStream` open for the symbols the monitor asks for, and hands it
/// the prices as they come, at most once a second.
///
/// It's a light client too (docs/architecture.md, "Streaming"): one connection for the whole
/// watchlist, opened only while there's something to stream (the monitor asks for the enabled
/// symbols in regular hours, and nothing outside them), changed with subscribe and unsubscribe
/// messages when the watchlist changes, and closed when there's nothing left. When it fails, it
/// waits before reconnecting, doubling the wait each time up to 5 minutes, while the monitor polls.
public actor QuoteStreamer {
    /// What the streamer tells the monitor.
    public enum Update: Equatable, Sendable {
        /// The latest streamed quote for each symbol whose price changed since the last update.
        case quotes([Quote])
        /// The connection's state changed.
        case status(StreamStatus)
    }

    /// Every update, in order. At most one `.quotes` a second.
    public nonisolated let updates: AsyncStream<Update>
    private let sink: AsyncStream<Update>.Continuation

    /// The shortest time between two `.quotes` updates, in seconds.
    public static let flushInterval: TimeInterval = 1
    /// The first wait before reconnecting, in seconds; each failure in a row doubles it.
    public static let shortestBackoff: TimeInterval = 5
    /// The longest wait before reconnecting, in seconds, unless the provider asks for longer.
    public static let longestBackoff: TimeInterval = 300

    private let stream: any QuoteStream
    private let clock: MonitorClock
    /// The symbols to stream, as the monitor last asked.
    private var wanted: [String] = []
    private var connection: (any QuoteStreamConnection)?
    /// What the open connection is subscribed to.
    private var subscribed: Set<String> = []
    /// The run loop, waiting for something to stream.
    private var idle: CheckedContinuation<Void, Never>?
    private var failures = 0
    /// What `updates` last said; `nil` before the first, so the first, `.off` included, goes out.
    private var status: StreamStatus?
    /// The latest quote for each symbol since the last `.quotes` update.
    private var pending: [String: Quote] = [:]
    private var lastFlush: Date?
    private var flushing: Task<Void, Never>?

    public init(stream: any QuoteStream, clock: MonitorClock = .system) {
        (updates, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.clock = clock
    }

    deinit {
        flushing?.cancel()
        sink.finish()
    }

    /// Streams for `monitor` until the task running it is cancelled: the symbols the monitor asks
    /// for, and each update handed back to it.
    public func run(for monitor: QuoteMonitor) async {
        await withDiscardingTaskGroup { group in
            group.addTask {
                for await symbols in monitor.streamSymbols { await self.watch(symbols) }
            }
            group.addTask {
                for await update in self.updates { await monitor.receive(update) }
            }
            group.addTask { await self.run() }
        }
    }

    /// Streams `symbols` from now on: subscribes the open connection to the new ones and
    /// unsubscribes it from the rest, opens one if there wasn't one, or closes it when `symbols`
    /// is empty.
    public func watch(_ symbols: [String]) async {
        var seen = Set<String>()
        wanted = symbols.map { $0.uppercased() }.filter { seen.insert($0).inserted }
        pending = pending.filter { seen.contains($0.key) }
        if wanted.isEmpty {
            // The run loop sees the connection close, and waits for symbols.
            connection?.close()
            return
        }
        if let idle {
            self.idle = nil
            idle.resume()
        }
        // While a connection is opening, the run loop subscribes it to the change once it's open.
        guard let connection, !subscribed.isEmpty else { return }
        let added = wanted.filter { !subscribed.contains($0) }
        let removed = subscribed.subtracting(wanted).sorted()
        subscribed = Set(wanted)
        do throws(ProviderError) {
            if !removed.isEmpty { try await connection.unsubscribe(removed) }
            if !added.isEmpty { try await connection.subscribe(added) }
        } catch {
            // The run loop sees the connection fail, and reconnects.
            connection.close()
        }
    }

    /// Connects, streams and reconnects until the task running it is cancelled.
    public func run() async {
        defer { flushing?.cancel() }
        while !Task.isCancelled {
            guard !wanted.isEmpty else {
                publish(.off)
                await waitForSymbols()
                continue
            }
            publish(.connecting)
            let connection = stream.connect()
            self.connection = connection
            var failure = ProviderError.unavailable
            await withTaskCancellationHandler {
                do throws(ProviderError) {
                    let symbols = wanted
                    try await connection.subscribe(symbols)
                    subscribed = Set(symbols)
                    // The symbols may have changed while the subscribe was on its way.
                    if subscribed != Set(wanted) { await watch(wanted) }
                    publish(.live(since: clock.now()))
                    while true {
                        received(try await connection.next())
                        failures = 0
                    }
                } catch {
                    failure = error
                }
            } onCancel: {
                connection.close()
            }
            connection.close()
            self.connection = nil
            subscribed = []
            if Task.isCancelled { return }
            // Closed because there's nothing to stream: no failure, nothing to wait for.
            if wanted.isEmpty { continue }
            failures += 1
            var wait = min(Self.shortestBackoff * pow(2, Double(min(failures - 1, 30))), Self.longestBackoff)
            if case .rateLimited(let retryAfter?) = failure { wait = max(wait, retryAfter) }
            publish(.reconnecting(failure, retryAt: clock.now().addingTimeInterval(wait)))
            do {
                try await clock.sleep(wait)
            } catch {
                return
            }
        }
    }

    /// Waits until `watch` asks for symbols, or the task is cancelled.
    private func waitForSymbols() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !wanted.isEmpty { continuation.resume() } else { idle = continuation }
            }
        } onCancel: {
            Task { await self.stopWaiting() }
        }
    }

    private func stopWaiting() {
        idle?.resume()
        idle = nil
    }

    /// Keeps `quote` for the next `.quotes` update, which goes now if the last went at least a
    /// second ago, and otherwise once it's been a second.
    private func received(_ quote: Quote) {
        let symbol = quote.symbol.uppercased()
        guard wanted.contains(symbol) else { return }
        if let kept = pending[symbol], kept.timestamp > quote.timestamp { return }
        pending[symbol] = quote
        guard flushing == nil else { return }
        let wait = lastFlush.map { Self.flushInterval - clock.now().timeIntervalSince($0) } ?? 0
        guard wait > 0 else { return flush() }
        flushing = Task { [clock] in
            do {
                try await clock.sleep(wait)
            } catch {
                return
            }
            self.flush()
        }
    }

    private func flush() {
        flushing = nil
        guard !pending.isEmpty else { return }
        lastFlush = clock.now()
        sink.yield(.quotes(pending.values.sorted { $0.symbol < $1.symbol }))
        pending = [:]
    }

    private func publish(_ status: StreamStatus) {
        guard status != self.status else { return }
        self.status = status
        sink.yield(.status(status))
    }
}

/// How the streaming connection is doing.
public enum StreamStatus: Equatable, Sendable {
    /// No connection, since there's nothing to stream: outside regular hours, or no symbol on.
    case off
    /// Opening the connection.
    case connecting
    /// Connected, and streaming the symbols since `since`.
    case live(since: Date)
    /// The connection failed with the error, and opens again at `retryAt`; updates poll meanwhile.
    case reconnecting(ProviderError, retryAt: Date)

    public var isLive: Bool {
        if case .live = self { true } else { false }
    }
}
