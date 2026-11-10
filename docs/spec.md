# Vettira: engineering handoff (MVP spec)

The product spec the MVP is built to. Written as "Market Peak Monitor" before the app was named Vettira. Revised in November 2026: quotes come from Yahoo Finance's unofficial endpoints, with no key, instead of a paid third-party reseller that needed one, and in regular hours prices also stream from Yahoo's unofficial streaming quote feed between polls.

**Product:** Free, open-source, local-first macOS app for monitoring stocks and ETFs for potential intraday reversals. **No brokerage integration or order placement.**

## Product experience

- **Menu bar + dashboard:** Native SwiftUI macOS application. The menu-bar item shows a ticker and its latest price only, like a ticker tape (`SPY 741.12`), cycling through the enabled watchlist symbols every 5 seconds by default (off, 3, 5 or 10 s in Settings; off shows only the selected symbol). On each new price, the characters from the first one that differs from the symbol's previous displayed price to the end are coloured, green if it rose and red if it fell (all of it when the number of digits changes), until that symbol's next change. The colours mean up or down since the last price, never buy or sell. A stale or closed-market price is dimmed, never green or red; its tooltip and accessibility value say the symbol, price, direction and data age in words. Cycling only rotates prices already fetched: it makes no requests. Clicking it opens a compact multi-symbol popover. A separate dashboard window shows the full watchlist, prices, session highs, pullbacks, alert thresholds, timestamps, and connection health.
- **Window-independent monitoring:** Closing the dashboard **must not quit the app or stop market-data updates/alerts**. The menu-bar process continues until the user explicitly selects **Quit**. Reopen the dashboard from the menu bar; optional Launch at Login.
- **User-managed watchlist:** Add, remove, reorder, search, and pin **multiple stock and ETF symbols** (SPY is only an example). Persist the watchlist locally. Per-symbol enable/disable and independent alert settings; sensible global defaults.
- **Local notifications:** macOS notification + optional sound; show ticker, price, current session high, drop from high, signal type, and **quote timestamp**. Never describe an alert as an instruction to sell.

## Market-data integration (important caveat)

Vettira reads quotes from **Yahoo Finance's unofficial JSON quote endpoints**, and in regular hours from its **unofficial streaming quote feed** (the WebSocket Yahoo's own pages get prices from), the ones the open-source [yfinance](https://github.com/ranaroussi/yfinance) library uses. There is no official public Yahoo Finance stock-data API, and these need no API key and no account.

What that data source is, stated plainly here, in the README and in the provider guide:

- **Unofficial.** Yahoo doesn't document, support, license or endorse these endpoints or the feed, or Vettira's use of them, and Vettira isn't affiliated with Yahoo. Nothing in the app or its docs calls them official, documented, supported, licensed or endorsed, or implies a licence to the data.
- **It can stop working.** Yahoo can change, break, rate-limit or block the endpoints at any time, without notice. When that happens Vettira gets no quotes, says so, and fires no price alerts until it's fixed.
- **Yahoo's terms govern its use.** Yahoo's [Terms of Service](https://legal.yahoo.com/us/en/yahoo/terms/otos/index.html) (last updated 1 November 2026) say users may not "access or collect data, or attempt to access or collect data, from our Services using any automated means, devices, programs, algorithms or methodologies, including but not limited to robots, spiders, scrapers, data mining tools, or data gathering or extraction tools, for any purpose without our express, prior permission", must not "try to access them using a method other than the interface and the instructions that we provide", may not use the Services "for any commercial purpose" unless expressly stated, and may not engage in "high volume activity" without Yahoo's prior written consent. Vettira doesn't have that permission. Each user's use of the data is between them and Yahoo, under those terms. Vettira is for personal, non-commercial use: it shows the data only to the user on their own Mac, and never redistributes or republishes it.
- **Not real-time, not complete.** Quotes may be delayed, and neither the chart endpoint nor the streaming feed says by how much: the app shows each quote's own time and its age, so a delay shows as an older quote. The data isn't consolidated across all exchanges, isn't tick-by-tick (streamed prices reach the app at most once a second), and isn't guaranteed real-time.

How the app uses it:

- MVP: one provider, Yahoo Finance's unofficial `v8/finance/chart` endpoint, one symbol per request, with no cookie or crumb. `v7/finance/quote` batches symbols but refuses non-browser clients at its crumb step, and Vettira doesn't impersonate a browser. The session state comes from Vettira's own market calendar and the chart's `currentTradingPeriod`. In regular hours, prices also stream between polls from Yahoo's unofficial streaming quote feed: one WebSocket for the whole watchlist, with the same honest User-Agent, decoding only each message's symbol, price, time and market hours, and keeping only regular-session prices. The chart endpoint still brings each symbol's first quote, the day's bars, the previous close and the session high, and takes over whenever the stream is down. The JSON endpoints and the streaming feed only: never scrape Yahoo's web pages. Settings have no key or account fields. A **Test Connection** button checks that the endpoint answers, with clear errors for rate limiting or blocking, a response the app can't read (the endpoint changed), missing symbols, and stale quotes.
- Implement a `MarketDataProvider` protocol, and a `QuoteStream` beside it for pushed prices, so a licensed provider can be added later without modifying alert logic or UI. Any key such a provider needs lives in the macOS Keychain, and no app-developer key is ever bundled.
- **Be a light client.** As few requests as the endpoint allows. The chart endpoint takes one symbol, so it's one request per enabled symbol per poll, sent one at a time, never in parallel, no more often than a visible, configurable update interval, and at most one request a second overall. The streaming feed is one long-lived connection, open only in regular hours while a symbol is enabled, its subscriptions changed on that connection as the watchlist changes; while it's live, polls slow to once a minute, since they only refresh the day's bars, previous close and high. Back off on rate limiting (HTTP 429), errors and dropped connections, and slow down automatically rather than retrying hard. No bulk or historical downloads. Send a plain, honest User-Agent that names Vettira, never one impersonating a browser to get around a block. Never promise 1-second updates or real-time data.
- Normalize incoming data: symbol, price, quote timestamp, source/provider, regular-session high when legitimately supplied, session state, and delay/staleness indication. Display **data age** prominently and suspend price-sensitive alerts when quotes are stale or delayed beyond a user-configurable tolerance.
- The README and the provider guide state all of the above and link Yahoo's terms. Yahoo and Yahoo Finance are named only to say where the data comes from; no Yahoo logos or branding.

## Reversal detection — MVP

Scope: **US regular trading hours (09:30–16:00 America/New_York)**, with a new session reset each trading day, including holiday/half-day handling via a market calendar or exchange-session API.

1. For each ticker, track the session's running high and calculate `pullbackPct = (sessionHigh - latestPrice) / sessionHigh * 100`.
2. Default **early warning: 0.25%** from high; **stronger warning: 0.40%**. Both configurable per ticker. These are **illustrative thresholds, not validated trading signals**.
3. Fire promptly when the threshold is crossed on **fresh market data**; do **not** require 30–60 minutes of confirmation. Optionally show a separate 1–5-minute momentum indicator based on sufficiently frequent data, clearly labeled as early/unconfirmed.
4. Distinguish **provider-reported session high** from **observed high**: the highest price in the quotes Vettira received and, when the provider supplies no session high, in the day's bars that came with them, which go back before monitoring began. If an authoritative session high is unavailable, label it “observed high”; do not misrepresent it as the day's actual high.
5. Send each threshold once per ticker per high-water-mark cycle, with cooldown/hysteresis to prevent spam. Rearm only on a meaningful new high (configurable) or a new session. Persist enough state to avoid duplicate alerts after closing/reopening the dashboard.
6. Prevent alerts on out-of-order timestamps, stale/delayed quotes, extended-hours trades, and obviously invalid spikes; show a clear disconnected/stale state.

## Architecture / implementation

- **Swift 6 + SwiftUI**, in an `NSStatusItem` with an `NSPopover` for menu-bar presentation (a window-style `MenuBarExtra` opens only on a real mouse event, so accessibility and UI tests can't open it); a separately controlled window for the dashboard. Shared `@Observable`/actor-backed application state; monitoring owned by the app/service layer, **not the dashboard view lifecycle**.
- `MarketDataProvider` → normalized quote stream/poller → per-symbol `SessionHighTracker` → `ReversalAlertEngine` → `UNUserNotificationCenter` + sound → menu bar/dashboard.
- The MVP's data source needs no API key. Any key a later provider needs is stored in the **macOS Keychain** only, never in plaintext preferences, logs, crash reports, or the repo. Save watchlist, thresholds, and UI preferences in local app storage. No telemetry or cloud dependency by default. No trading credentials required.
- Make provider calls light across the watchlist (one request per enabled symbol per poll, one at a time), implement reconnect/retry, rate-limit handling, and basic diagnostics (last received time, polling cadence, errors, source).

## MVP acceptance criteria

Each criterion is ticked with where it's proven: a test in `Tests/VettiraCoreTests/` (by file and name) or a doc.

- [x] User can test the connection to Yahoo Finance's unofficial endpoints with no key or account, and the app says plainly that the data is unofficial, not endorsed by Yahoo, and governed by Yahoo's terms; no app-developer key is bundled.
  - Proof: Settings' **Test Connection** and its disclaimer with a link to Yahoo's terms ([README](../README.md#where-the-data-comes-from)); `ConnectionTestReportTests`; `YahooFinanceProviderTests.itSaysItsUnofficial` and `asksForEachSymbolOnceInOrderWithAnHonestUserAgent` (no key in any request).
- [x] User can monitor at least **five user-selected stock/ETF symbols** concurrently, with per-symbol thresholds.
  - Proof: `QuoteMonitorTests.fiveSymbolsAtOnceEachAlertOnItsOwnThresholds`, `eachSymbolUsesItsOwnThresholds`; `ReversalAlertEngineTests.thresholdsArePerSymbol`; `WatchlistTests.aSymbolUsesItsOwnThresholdsOrTheDefaults`; a demo run watching five symbols, each on its own thresholds.
- [x] Menu bar stays active and alerts keep running after dashboard is closed; dashboard can reopen without losing state.
  - Proof: the app state and the monitor live outside every window ([architecture](architecture.md#the-app), [Polling](architecture.md#polling)); `DashboardDisplayTests.vettiraShowsInTheDockWhileAWindowIsOpen`, `openingOrClosingAWindowTwiceChangesNothing`.
- [x] Fresh-data threshold crossings trigger correct, de-duplicated notifications; false signals are labeled as possible, not certain, reversals.
  - Proof: `ReversalAlertEngineTests.eachThresholdFiresOncePerCycle`, `aDropPastBothThresholdsAtOnceSendsOneStrongerWarning`, `restoredStateDoesNotAlertAgain`; `QuoteMonitorTests.aPullbackPastAThresholdAlertsOnce`; `DemoProviderTests.aDemoRunWarnsOnceEarlyThenOnceStrongerAndNotifiesEachOnce`; `AlertNotificationTests.aNotificationIsAPossibleReversalWithEverythingTheSpecAsksFor`, `aNotificationNeverReadsAsAdviceOrCertainty`.
- [x] App explicitly identifies stale/delayed data, provider failures, rate limiting or blocking, and whether highs are **session** or **observed**.
  - Proof: `DisplayTests.aStaleQuoteSaysSo`, `aFailingConnectionSaysWhatHappenedAndWhatToDo`, `aSessionHighIsLabelledAsOne`; `ConnectionTestReportTests.aQuoteTheProviderSaysIsDelayedIsStale`; `ProviderErrorTests.eachKindOfFailureReadsDifferently`, `rateLimitedSaysHowLongTheProviderAskedToWait`; `YahooFinanceProviderTests.forbiddenStopsThePollAsBlocked`; `SessionHighTrackerTests.theHighsAreLabelledSessionAndObserved`.
- [x] Tests cover session reset, after-hours/half-days, duplicate alerts, higher highs/rearming, out-of-order quotes, reconnection, and rate-limit behavior using recorded/mock quotes.
  - Proof: `ReversalAlertEngineTests.aNewSessionResetsTheHighAndRearms`, `anExtendedHoursQuoteChangesNothing`, `onAnEarlyCloseDayAlertsStopAt1300`, `eachThresholdFiresOncePerCycle`, `aMeaningfulNewHighRearmsBothThresholds`, `outOfOrderAndDuplicateQuotesAreRejected`, `recordedYahooQuotesAreMeasuredFromTheSessionHigh`; `QuoteStreamerTests.aDroppedConnectionReconnectsAfterABackoffThatDoubles`; `QuoteMonitorTests.failuresBackOffDoublingUpToFifteenMinutesThenRecover`, `aRateLimitWaitsAtLeastAsLongAsTheProviderAsks`.
- [x] Public repository contains build/run instructions, provider setup guide, privacy statement, license (e.g., MIT), and clear **data-source and Yahoo terms** disclaimers.
  - Proof: [README](../README.md#build-and-run) (build and run, and [where the data comes from](../README.md#where-the-data-comes-from)), [providers](providers.md), [PRIVACY.md](../PRIVACY.md), [LICENSE](../LICENSE) (MIT).

## Out of scope for v1

Brokerage order execution, portfolio holdings, predictive peak detection, guaranteed real-time/full-market data, backtesting, and hosted infrastructure. A licensed provider is a future adapter if Yahoo's unofficial endpoints and feed prove too delayed or unreliable.

## Reference links

- [yfinance project disclaimer and unofficial Yahoo endpoints](https://github.com/ranaroussi/yfinance)
- [Yahoo Terms of Service](https://legal.yahoo.com/us/en/yahoo/terms/otos/index.html)
