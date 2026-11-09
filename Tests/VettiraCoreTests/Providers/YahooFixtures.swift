import Foundation

/// Yahoo Finance chart responses for the provider's tests.
///
/// Shaped after real `v8/finance/chart/<symbol>?range=1d&interval=1d` responses for SPY, AAPL and a
/// made-up symbol, fetched once by hand on 9 November 2026, cut down to the fields Vettira reads.
/// Everything else was stripped. The variants below them (other times, missing fields) are
/// hand-made from that shape. No cookie, token or personal data.
enum YahooFixtures {
    /// SPY's and AAPL's `regularMarketTime`: Monday 9 November 2026, 13:16:18 in New York.
    static let quoteTime = Date(timeIntervalSince1970: 1_794_248_178)

    /// The day's regular period: 09:30 to 16:00 in New York.
    static let regularStart: TimeInterval = 1_794_234_600
    static let regularEnd: TimeInterval = 1_794_258_000

    /// SPY during the regular session (real).
    static let spy = """
        {"chart":{"result":[{"meta":{"symbol":"SPY","regularMarketPrice":752.68,"regularMarketTime":1794248178,
        "regularMarketDayHigh":752.96,"currentTradingPeriod":{
        "pre":{"timezone":"EST","start":1794214800,"end":1794234600,"gmtoffset":-18000},
        "regular":{"timezone":"EST","start":1794234600,"end":1794258000,"gmtoffset":-18000},
        "post":{"timezone":"EST","start":1794258000,"end":1794272400,"gmtoffset":-18000}}}}],"error":null}}
        """

    /// AAPL during the regular session (real).
    static let aapl = """
        {"chart":{"result":[{"meta":{"symbol":"AAPL","regularMarketPrice":349.35,"regularMarketTime":1794248178,
        "regularMarketDayHigh":351.42,"currentTradingPeriod":{
        "pre":{"timezone":"EST","start":1794214800,"end":1794234600,"gmtoffset":-18000},
        "regular":{"timezone":"EST","start":1794234600,"end":1794258000,"gmtoffset":-18000},
        "post":{"timezone":"EST","start":1794258000,"end":1794272400,"gmtoffset":-18000}}}}],"error":null}}
        """

    /// The 404 body for a symbol Yahoo doesn't know (real).
    static let unknownSymbol = #"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found, symbol may be delisted"}}}"#

    /// SPY with `regularMarketTime` at `time`, in the same day's periods.
    static func spy(at time: TimeInterval) -> String {
        spy(editingMeta: { $0["regularMarketTime"] = Int(time) })
    }

    /// SPY without one of its `meta` fields.
    static func spy(without field: String) -> String {
        spy(editingMeta: { $0.removeValue(forKey: field) })
    }

    /// SPY with a price of 0.
    static let spyWithZeroPrice = spy(editingMeta: { $0["regularMarketPrice"] = 0 })

    /// SPY's response with its `meta` edited.
    private static func spy(editingMeta edit: (inout [String: Any]) -> Void) -> String {
        var document = try! JSONSerialization.jsonObject(with: Data(spy.utf8)) as! [String: Any]
        var chart = document["chart"] as! [String: Any]
        var results = chart["result"] as! [[String: Any]]
        var meta = results[0]["meta"] as! [String: Any]
        edit(&meta)
        results[0]["meta"] = meta
        chart["result"] = results
        document["chart"] = chart
        return String(decoding: try! JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    /// A 200 with no result and no error.
    static let noResult = #"{"chart":{"result":[],"error":null}}"#

    /// The plain-text 429 body.
    static let tooManyRequests = "Too Many Requests\r\n"

    /// The page a consent redirect ends on, cut down to what matters (hand-made).
    static let consentPage = """
        <!DOCTYPE html><html lang="en"><head><title>Before you continue</title></head>
        <body><form method="post" action="https://consent.yahoo.com/v2/collectConsent"></form></body></html>
        """
}
