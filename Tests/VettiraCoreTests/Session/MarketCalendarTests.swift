import Foundation
import Testing
import VettiraCore

// Expected values come from NYSE's published calendar (https://www.nyse.com/markets/hours-calendars):
// regular hours 09:30 to 16:00 ET, early-trading 04:00 and late-trading 20:00 (NYSE Arca), early
// closes at 13:00 with late trading to 17:00, and the 2026, 2027 and 2028 holidays. Instants carry their
// UTC offset: New York is UTC-5 in winter and UTC-4 from the second Sunday of March to the first
// Sunday of November (March 8 and November 1 in 2026).

private func at(_ iso8601: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso8601)!
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> TradingDay {
    TradingDay(year: year, month: month, day: day)
}

private func status(_ iso8601: String) -> SessionStatus? {
    MarketCalendar.usEquities.status(at: at(iso8601))
}

@Test(arguments: [
    ("2026-11-10T03:59:59-05:00", SessionState.closed, day(2026, 11, 9)),
    ("2026-11-10T04:00:00-05:00", .preMarket, day(2026, 11, 10)),
    ("2026-11-10T09:29:59-05:00", .preMarket, day(2026, 11, 10)),
    ("2026-11-10T09:30:00-05:00", .regular, day(2026, 11, 10)),
    ("2026-11-10T15:59:59-05:00", .regular, day(2026, 11, 10)),
    ("2026-11-10T16:00:00-05:00", .afterHours, day(2026, 11, 10)),
    ("2026-11-10T19:59:59-05:00", .afterHours, day(2026, 11, 10)),
    ("2026-11-10T20:00:00-05:00", .closed, day(2026, 11, 10)),
])
func aNormalDaysEdges(instant: String, state: SessionState, tradingDay: TradingDay) throws {
    let status = try #require(status(instant))
    #expect(status.state == state)
    #expect(status.session.day == tradingDay)
}

@Test func aNormalDaysSessionRunsFrom0930To1600NewYorkTime() throws {
    let session = try #require(status("2026-11-10T12:00:00-05:00")).session
    #expect(session.preMarketOpen == at("2026-11-10T09:00:00Z"))
    #expect(session.open == at("2026-11-10T14:30:00Z"))
    #expect(session.close == at("2026-11-10T21:00:00Z"))
    #expect(session.afterHoursClose == at("2026-11-11T01:00:00Z"))
    #expect(!session.isEarlyClose)
}

@Test(arguments: [
    "2026-01-10T12:00:00-05:00",  // Saturday
    "2026-01-11T23:59:59-05:00",  // Sunday
    "2026-01-12T03:59:59-05:00",  // Monday, before pre-market
])
func aWeekendIsClosedAndBelongsToFridaysSession(instant: String) throws {
    let status = try #require(status(instant))
    #expect(status.state == .closed)
    #expect(status.session.day == day(2026, 1, 9))
    #expect(status.session.close == at("2026-01-09T16:00:00-05:00"))
}

@Test func mondayFromPreMarketBelongsToMondaysSession() throws {
    let status = try #require(status("2026-01-12T04:00:00-05:00"))
    #expect(status.state == .preMarket)
    #expect(status.session.day == day(2026, 1, 12))
}

/// Each full holiday NYSE publishes for 2026, 2027 and 2028, and the trading day before it (but New
/// Year's Day 2026, whose trading day before is in 2025: outsideItsYearsTheCalendarDoesNotGuess).
@Test(arguments: [
    (day(2026, 1, 19), day(2026, 1, 16)),   // Martin Luther King, Jr. Day
    (day(2026, 2, 16), day(2026, 2, 13)),   // Washington's Birthday
    (day(2026, 4, 3), day(2026, 4, 2)),     // Good Friday
    (day(2026, 5, 25), day(2026, 5, 22)),   // Memorial Day
    (day(2026, 6, 19), day(2026, 6, 18)),   // Juneteenth
    (day(2026, 7, 3), day(2026, 7, 2)),     // Independence Day, observed
    (day(2026, 9, 7), day(2026, 9, 4)),     // Labor Day
    (day(2026, 11, 26), day(2026, 11, 25)), // Thanksgiving Day
    (day(2026, 12, 25), day(2026, 12, 24)), // Christmas Day
    (day(2027, 1, 1), day(2026, 12, 31)),   // New Year's Day
    (day(2027, 1, 18), day(2027, 1, 15)),   // Martin Luther King, Jr. Day
    (day(2027, 2, 15), day(2027, 2, 12)),   // Washington's Birthday
    (day(2027, 3, 26), day(2027, 3, 25)),   // Good Friday
    (day(2027, 5, 31), day(2027, 5, 28)),   // Memorial Day
    (day(2027, 6, 18), day(2027, 6, 17)),   // Juneteenth, observed
    (day(2027, 7, 5), day(2027, 7, 2)),     // Independence Day, observed
    (day(2027, 9, 6), day(2027, 9, 3)),     // Labor Day
    (day(2027, 11, 25), day(2027, 11, 24)), // Thanksgiving Day
    (day(2027, 12, 24), day(2027, 12, 23)), // Christmas Day, observed
    (day(2028, 1, 17), day(2028, 1, 14)),   // Martin Luther King, Jr. Day
    (day(2028, 2, 21), day(2028, 2, 18)),   // Washington's Birthday
    (day(2028, 4, 14), day(2028, 4, 13)),   // Good Friday
    (day(2028, 5, 29), day(2028, 5, 26)),   // Memorial Day
    (day(2028, 6, 19), day(2028, 6, 16)),   // Juneteenth
    (day(2028, 7, 4), day(2028, 7, 3)),     // Independence Day
    (day(2028, 9, 4), day(2028, 9, 1)),     // Labor Day
    (day(2028, 11, 23), day(2028, 11, 22)), // Thanksgiving Day
    (day(2028, 12, 25), day(2028, 12, 22)), // Christmas Day
])
func aFullHolidayIsClosedAllDay(holiday: TradingDay, tradingDayBefore: TradingDay) throws {
    for time in ["T04:00:00", "T10:00:00", "T16:30:00"] {
        let instant = String(describing: holiday) + time + "-05:00"
        let status = try #require(status(instant), "\(instant)")
        #expect(status.state == .closed, "\(instant)")
        #expect(status.session.day == tradingDayBefore, "\(instant)")
    }
}

@Test func theDayAfterAHolidayWeekendBelongsToTheLastTradingDayUntilPreMarket() throws {
    // Martin Luther King, Jr. Day is Monday, January 19, 2026.
    let early = try #require(status("2026-01-20T03:00:00-05:00"))
    #expect(early.state == .closed)
    #expect(early.session.day == day(2026, 1, 16))
    let open = try #require(status("2026-01-20T09:30:00-05:00"))
    #expect(open.state == .regular)
    #expect(open.session.day == day(2026, 1, 20))
}

@Test(arguments: [
    ("2026-11-27T12:59:59-05:00", SessionState.regular),
    ("2026-11-27T13:00:00-05:00", .afterHours),
    ("2026-11-27T16:59:59-05:00", .afterHours),
    ("2026-11-27T17:00:00-05:00", .closed),
])
func aHalfDayClosesAt1300(instant: String, state: SessionState) throws {
    let status = try #require(status(instant))
    #expect(status.state == state)
    #expect(status.session.day == day(2026, 11, 27))
    #expect(status.session.isEarlyClose)
    #expect(status.session.close == at("2026-11-27T18:00:00Z"))
    #expect(status.session.afterHoursClose == at("2026-11-27T22:00:00Z"))
}

/// Each early close NYSE publishes for 2026, 2027 and 2028, and its 13:00 close in New York.
@Test(arguments: [
    (day(2026, 11, 27), "2026-11-27T13:00:00-05:00"),
    (day(2026, 12, 24), "2026-12-24T13:00:00-05:00"),
    (day(2027, 11, 26), "2027-11-26T13:00:00-05:00"),
    (day(2028, 7, 3), "2028-07-03T13:00:00-04:00"),
    (day(2028, 11, 24), "2028-11-24T13:00:00-05:00"),
])
func everyPublishedEarlyCloseIsAt1300(earlyClose: TradingDay, close: String) throws {
    let session = try #require(status(String(describing: earlyClose) + "T15:00:00Z")).session
    #expect(session.day == earlyClose)
    #expect(session.isEarlyClose)
    #expect(session.close == at(close))
}

/// NYSE publishes no early close before these holidays, so they trade a full day.
@Test(arguments: [
    (day(2026, 7, 2), "2026-07-02T16:00:00-04:00"),
    (day(2027, 7, 2), "2027-07-02T16:00:00-04:00"),
    (day(2027, 12, 23), "2027-12-23T16:00:00-05:00"),
    (day(2026, 12, 31), "2026-12-31T16:00:00-05:00"),
])
func aDayBeforeAHolidayWithNoPublishedEarlyCloseClosesAt1600(tradingDay: TradingDay, close: String) throws {
    let status = try #require(status(String(describing: tradingDay) + "T15:00:00Z"))
    #expect(status.state == .regular)
    #expect(status.session.day == tradingDay)
    #expect(!status.session.isEarlyClose)
    #expect(status.session.close == at(close))
}

@Test func theOpenFollowsNewYorkWhenDaylightSavingTimeStarts() throws {
    // Daylight saving time starts Sunday, March 8, 2026.
    let friday = try #require(status("2026-03-06T12:00:00-05:00")).session
    #expect(friday.open == at("2026-03-06T14:30:00Z"))
    #expect(friday.close == at("2026-03-06T21:00:00Z"))
    let monday = try #require(status("2026-03-09T12:00:00-04:00")).session
    #expect(monday.open == at("2026-03-09T13:30:00Z"))
    #expect(monday.close == at("2026-03-09T20:00:00Z"))
    // 03:30 on the Sunday, just after the clocks skip 02:00 to 03:00.
    let sunday = try #require(status("2026-03-08T07:30:00Z"))
    #expect(sunday.state == .closed)
    #expect(sunday.session.day == day(2026, 3, 6))
}

@Test func theOpenFollowsNewYorkWhenDaylightSavingTimeEnds() throws {
    // Daylight saving time ends Sunday, November 1, 2026.
    let friday = try #require(status("2026-10-30T12:00:00-04:00")).session
    #expect(friday.open == at("2026-10-30T13:30:00Z"))
    #expect(friday.close == at("2026-10-30T20:00:00Z"))
    let monday = try #require(status("2026-11-02T12:00:00-05:00")).session
    #expect(monday.open == at("2026-11-02T14:30:00Z"))
    #expect(monday.close == at("2026-11-02T21:00:00Z"))
    // 13:29:59 UTC on the Monday is 08:29:59 in New York, not 09:29:59.
    #expect(try #require(status("2026-11-02T13:29:59Z")).state == .preMarket)
    #expect(try #require(status("2026-11-02T14:29:59Z")).state == .preMarket)
    #expect(try #require(status("2026-11-02T14:30:00Z")).state == .regular)
}

@Test func anInstantInAnotherTimeZoneIsPlacedByNewYorkTime() throws {
    // Midnight on March 11 in Tokyo is 11:00 on March 10 in New York.
    let tokyo = try #require(status("2026-03-11T00:00:00+09:00"))
    #expect(tokyo.state == .regular)
    #expect(tokyo.session.day == day(2026, 3, 10))
    // 19:30 in Paris on the 2026 day after Thanksgiving is 13:30 in New York, after its early close.
    let paris = try #require(status("2026-11-27T19:30:00+01:00"))
    #expect(paris.state == .afterHours)
    #expect(paris.session.day == day(2026, 11, 27))
}

@Test func theCalendarCovers2026To2028() {
    #expect(MarketCalendar.usEquities.coveredYears == [2026, 2027, 2028])
}

@Test func newYearsDay2028IsNotObservedSoMondayJanuary3Trades() throws {
    // January 1, 2028 is a Saturday, and NYSE observes no New Year's Day holiday that year.
    let weekend = try #require(status("2028-01-01T12:00:00-05:00"))
    #expect(weekend.state == .closed)
    #expect(weekend.session.day == day(2027, 12, 31))
    let monday = try #require(status("2028-01-03T10:00:00-05:00"))
    #expect(monday.state == .regular)
    #expect(monday.session.day == day(2028, 1, 3))
    let friday = try #require(status("2027-12-31T10:00:00-05:00"))
    #expect(friday.state == .regular)
    #expect(!friday.session.isEarlyClose)
}

@Test func outsideItsYearsTheCalendarDoesNotGuess() throws {
    #expect(status("2025-12-31T10:00:00-05:00") == nil)
    #expect(status("2029-01-02T10:00:00-05:00") == nil)
    // New Year's Day 2026, and the hours before pre-market on January 2, belong to December 31,
    // 2025's session.
    #expect(status("2026-01-01T12:00:00-05:00") == nil)
    #expect(status("2026-01-02T03:59:59-05:00") == nil)
    #expect(try #require(status("2026-01-02T04:00:00-05:00")).session.day == day(2026, 1, 2))
    // The last covered weekend belongs to Friday, December 29, 2028; Monday, January 1, 2029 is
    // a weekday in a year the calendar doesn't hold.
    let weekend = try #require(status("2028-12-31T12:00:00-05:00"))
    #expect(weekend.state == .closed)
    #expect(weekend.session.day == day(2028, 12, 29))
    #expect(status("2029-01-01T12:00:00-05:00") == nil)
}

@Test func tradingDaysOrderByDate() {
    #expect(day(2026, 12, 31) < day(2027, 1, 1))
    #expect(day(2027, 1, 2) < day(2027, 2, 1))
    #expect(String(describing: day(2026, 3, 9)) == "2026-03-09")
}
