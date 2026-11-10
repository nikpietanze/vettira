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

    /// SPY's day of Monday 9 November 2026 (real): a `range=1d&interval=5m&includePrePost=false`
    /// response fetched once by hand after that day's close, cut down to the fields Vettira reads.
    /// 79 regular-session bars from 09:30 to the 16:00 close, none of them `null`.
    static let spyDay = """
        {"chart":{"result":[{"meta":{"symbol":"SPY","regularMarketPrice":752.69,"regularMarketTime":1794258000,"regularMarketDayHigh":755.42,"chartPreviousClose":735.29,"currentTradingPeriod":{"regular":{"timezone":"EST","start":1794234600,"end":1794258000,"gmtoffset":-18000}}},
        "timestamp":[1794234600,1794234900,1794235200,1794235500,1794235800,1794236100,1794236400,1794236700,
                1794237000,1794237300,1794237600,1794237900,1794238200,1794238500,1794238800,1794239100,
                1794239400,1794239700,1794240000,1794240300,1794240600,1794240900,1794241200,1794241500,
                1794241800,1794242100,1794242400,1794242700,1794243000,1794243300,1794243600,1794243900,
                1794244200,1794244500,1794244800,1794245100,1794245400,1794245700,1794246000,1794246300,
                1794246600,1794246900,1794247200,1794247500,1794247800,1794248100,1794248400,1794248700,
                1794249000,1794249300,1794249600,1794249900,1794250200,1794250500,1794250800,1794251100,
                1794251400,1794251700,1794252000,1794252300,1794252600,1794252900,1794253200,1794253500,
                1794253800,1794254100,1794254400,1794254700,1794255000,1794255300,1794255600,1794255900,
                1794256200,1794256500,1794256800,1794257100,1794257400,1794257700,1794258000],
        "indicators":{"quote":[{"close":[743.3699951171875,744.9249877929688,746.6599731445312,747.0650024414062,747.6300048828125,747.72998046875,748.4500122070312,748.14501953125,
                748.7000122070312,749.1300048828125,749.0800170898438,749.1400146484375,749.5,749.4400024414062,749.7301025390625,750.25,
                750.9439697265625,751.6904907226562,750.6900024414062,750.5449829101562,749.97998046875,750.2100219726562,750.0,749.60498046875,
                749.5001220703125,749.75,750.5999755859375,751.030029296875,750.9500122070312,751.1400146484375,751.4299926757812,752.0900268554688,
                752.1900024414062,752.219970703125,752.219970703125,752.52001953125,752.739990234375,752.3499755859375,752.1799926757812,752.5399780273438,
                752.4000244140625,752.4400024414062,752.4089965820312,752.3800048828125,752.655029296875,752.27001953125,751.8800048828125,752.219970703125,
                752.3800048828125,752.4000244140625,752.5800170898438,753.2100219726562,752.969970703125,752.8400268554688,752.8900146484375,752.760009765625,
                752.7550048828125,752.3200073242188,752.3599853515625,751.8735961914062,752.3300170898438,754.3499755859375,753.969970703125,753.6599731445312,
                753.25,753.9400024414062,753.9099731445312,754.1900024414062,754.9515991210938,754.8480224609375,755.0750122070312,755.1849975585938,
                754.5800170898438,754.5,753.9500122070312,754.22998046875,753.260009765625,752.6099853515625,752.6900024414062],
        "high":[743.6400146484375,745.1199951171875,746.7999877929688,747.1400146484375,747.9299926757812,747.97998046875,748.5,748.6500244140625,
                748.9600219726562,749.1400146484375,749.4199829101562,749.469970703125,749.739990234375,749.780029296875,750.2100219726562,750.3099975585938,
                751.1400146484375,751.760009765625,751.7000122070312,751.0499877929688,750.5599975585938,750.5250244140625,750.2999877929688,750.1400146484375,
                749.8499755859375,750.030029296875,750.6500244140625,751.1099853515625,751.1649780273438,751.2000122070312,751.469970703125,752.0999755859375,
                752.3499755859375,752.5399780273438,752.52001953125,752.5599975585938,752.9600219726562,752.8200073242188,752.4099731445312,752.5800170898438,
                752.75,752.5850219726562,752.77001953125,752.5599975585938,752.780029296875,752.8099975585938,752.260009765625,752.3099975585938,
                752.530029296875,752.5800170898438,752.75,753.3800048828125,753.2949829101562,753.1799926757812,753.0499877929688,752.9749755859375,
                752.8599853515625,752.7899780273438,752.4349975585938,752.3800048828125,752.344970703125,754.7000122070312,755.2100219726562,754.0,
                754.0900268554688,754.2999877929688,754.2424926757812,754.3499755859375,755.030029296875,755.4199829101562,755.260009765625,755.3800048828125,
                755.1500244140625,754.8400268554688,754.52001953125,754.5900268554688,754.239990234375,753.35498046875,752.6900024414062]}]}}],"error":null}}
        """

    /// SPY's previous close in `spyWithBars`.
    static let previousClose = 750.1

    /// SPY with four 5-minute bars from the open, the third without trades (`null`), and the
    /// previous close (hand-made, in the shape of a real `interval=5m` response).
    static let spyWithBars = """
        {"chart":{"result":[{"meta":{"symbol":"SPY","regularMarketPrice":752.68,"regularMarketTime":1794248178,
        "regularMarketDayHigh":752.96,"chartPreviousClose":750.1,"currentTradingPeriod":{
        "regular":{"timezone":"EST","start":1794234600,"end":1794258000,"gmtoffset":-18000}}},
        "timestamp":[1794234600,1794234900,1794235200,1794235500],
        "indicators":{"quote":[{"close":[751.2,751.9,null,752.4],"high":[751.5,752.1,null,752.6],
        "open":[750.9,751.2,null,751.9],"low":[750.8,751.1,null,751.8],"volume":[1200,900,null,700]}]}}],
        "error":null}}
        """

    /// SPY whose bars aren't the arrays they should be (hand-made).
    static let spyWithUnreadableBars = """
        {"chart":{"result":[{"meta":{"symbol":"SPY","regularMarketPrice":752.68,"regularMarketTime":1794248178},
        "timestamp":"soon","indicators":{"quote":"none"}}],"error":null}}
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
