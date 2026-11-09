import Foundation
import VettiraCore

// Shared by the display and notification tests. New York is UTC-5 in November 2026, and
// Tuesday, November 10, 2026 is a full trading day.

let newYork = TimeZone(identifier: "America/New_York")!

func nyTime(_ time: String, on day: String = "2026-11-10") -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: "\(day)T\(time)-05:00")!
}

func displayTicker(_ raw: String) -> TickerSymbol { try! TickerSymbol(raw) }

func displayWatchlist(_ symbols: [String], disabled: Set<String> = [], pinned: Set<String> = []) -> Watchlist {
    var list = Watchlist()
    for raw in symbols {
        try! list.add(displayTicker(raw))
        if disabled.contains(raw) { try! list.setEnabled(false, for: displayTicker(raw)) }
        if pinned.contains(raw) { try! list.setPinned(true, for: displayTicker(raw)) }
    }
    return list
}

func regularQuote(_ price: Double, at time: Date, symbol: String = "SPY", high: Double? = nil) -> Quote {
    Quote(symbol: symbol, price: price, timestamp: time, source: "Test provider", sessionHigh: high, session: .regular)
}

/// An early warning for SPY: an observed high of 100.50 at 10:00, then 100.20 (0.30% below it)
/// at 10:00:15, evaluated 5 s after its time.
func earlyWarning() -> ReversalAlert {
    var engine = ReversalAlertEngine()
    _ = engine.evaluate(regularQuote(100.5, at: nyTime("10:00:00")), thresholds: .standard, now: nyTime("10:00:05"))
    guard case .accepted(_, _, let alert?) = engine.evaluate(
        regularQuote(100.2, at: nyTime("10:00:15")), thresholds: .standard, now: nyTime("10:00:20"))
    else { fatalError("expected an early warning") }
    return alert
}

/// A stronger warning for SPY: an observed high of 100.50 at 10:00, then 100.00 (0.50% below it,
/// past both thresholds, so one alert) at 10:00:15.
func strongerWarning() -> ReversalAlert {
    var engine = ReversalAlertEngine()
    _ = engine.evaluate(regularQuote(100.5, at: nyTime("10:00:00")), thresholds: .standard, now: nyTime("10:00:05"))
    guard case .accepted(_, _, let alert?) = engine.evaluate(
        regularQuote(100.0, at: nyTime("10:00:15")), thresholds: .standard, now: nyTime("10:00:20")),
        alert.signal == .strong
    else { fatalError("expected a stronger warning") }
    return alert
}

/// A snapshot with SPY's state as given, and a poll that finished at `polled` in `market`.
func displaySnapshot(
    _ symbols: [SymbolSnapshot], market: SessionState? = .regular, polled: Date? = nyTime("10:00:20")
) -> MonitorSnapshot {
    var diagnostics = MonitorDiagnostics(source: "Test provider")
    diagnostics.marketState = market
    diagnostics.lastPoll = polled
    diagnostics.lastReceived = polled
    return MonitorSnapshot(symbols: Dictionary(uniqueKeysWithValues: symbols.map { ($0.symbol, $0) }), diagnostics: diagnostics)
}

/// SPY with a fresh quote at `price`, its high and pullback, as the monitor publishes it.
func spy(
    _ price: Double, at time: Date = nyTime("10:00:15"), high: SessionHigh? = SessionHigh(price: 100.5, kind: .observed),
    alert: ReversalAlert? = nil, stale: Bool = false
) -> SymbolSnapshot {
    var state = SymbolSnapshot(symbol: displayTicker("SPY"))
    state.quote = regularQuote(price, at: time)
    state.isStale = stale
    state.high = high
    state.pullbackPercent = high.map { ($0.price - price) / $0.price * 100 }
    state.lastAlert = alert
    return state
}
