import Foundation
import Testing

/// SPY's history for each timeframe (real): one `v8/finance/chart/SPY` response per timeframe,
/// with its range and interval and `includePrePost=false`, fetched once by hand on the evening of
/// Monday 9 November 2026, after the close, at least a second apart and with Vettira's
/// User-Agent, cut down to the fields Vettira reads. No cookie, token or personal data. Every
/// response ends with Monday's close, 752.69.
///
/// `spy-1d.json` is the polls' request, the day at 5 minutes. The chart's are `spy-1d-1m.json`
/// (1D at a minute), `spy-5d-5m.json` (5D at 5 minutes), `spy-1mo-30m.json` (1M at 30 minutes),
/// and `spy-6mo.json`, `spy-ytd.json`, `spy-1y.json` (a day) and `spy-5y.json` (a week).
enum HistoryFixtures {
    /// The response in `spy-<name>.json`: `1d` for the polls', or a chart's, like `1d-1m` or `1y`.
    static func spy(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "spy-\(name)", withExtension: "json", subdirectory: "Fixtures/History"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Monday 9 November 2026's close in New York, 16:00, the last bar of the intraday ranges.
    static let close = Date(timeIntervalSince1970: 1_794_258_000)
    /// Its open, 09:30.
    static let open = Date(timeIntervalSince1970: 1_794_234_600)

    /// Three 15-minute bars, the second without trades (`null`), hand-made in the shape of the
    /// real ones.
    static let withGap = """
        {"chart":{"result":[{"meta":{"symbol":"SPY","regularMarketPrice":752.69,"regularMarketTime":1794258000,"chartPreviousClose":752.1},
        "timestamp":[1794234600,1794235500,1794236400],
        "indicators":{"quote":[{"open":[752.73,null,750.2],"high":[753.1,null,751.0],"low":[752.0,null,749.9],
        "close":[752.4,null,750.8],"volume":[1200000,null,900000]}]}}],"error":null}}
        """
}
