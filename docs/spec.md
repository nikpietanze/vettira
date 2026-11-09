# Vettira: engineering handoff (MVP spec)

The product spec the MVP is built to. Written as "Market Peak Monitor" before the app was named Vettira.

**Product:** Free, open-source, local-first macOS app for monitoring stocks and ETFs for potential intraday reversals. **No brokerage integration or order placement.**

## Product experience

- **Menu bar + dashboard:** Native SwiftUI macOS application. The menu-bar item always shows the currently selected ticker and latest price/change or alert status. Clicking it opens a compact multi-symbol popover. A separate dashboard window shows the full watchlist, prices, session highs, pullbacks, alert thresholds, timestamps, and connection health.
- **Window-independent monitoring:** Closing the dashboard **must not quit the app or stop market-data updates/alerts**. The menu-bar process continues until the user explicitly selects **Quit**. Reopen the dashboard from the menu bar; optional Launch at Login.
- **User-managed watchlist:** Add, remove, reorder, search, and pin **multiple stock and ETF symbols** (SPY is only an example). Persist the watchlist locally. Per-symbol enable/disable and independent alert settings; sensible global defaults.
- **Local notifications:** macOS notification + optional sound; show ticker, price, current session high, drop from high, signal type, and **quote timestamp**. Never describe an alert as an instruction to sell.

## Market-data integration (important caveat)

There is **no official public Yahoo Finance stock-data API key**. Treat the proposed “Yahoo Finance API key” as a **user-owned key for a Yahoo Finance-compatible *third-party provider***, such as a specific RapidAPI marketplace API, not a key issued by Yahoo Finance. Provider endpoints, quotas, latency, terms, and availability vary; do not imply that data is consolidated, tick-by-tick, or guaranteed real-time.

- MVP: support **one documented, named RapidAPI/Yahoo Finance-compatible quote provider**, with setup fields for **provider, API key**, and any required API host. Use `X-RapidAPI-Key` / `X-RapidAPI-Host` where applicable. Add a **Test Connection** button and clear errors for bad credentials, entitlement, rate limiting, missing symbols, or stale quotes.
- Implement a `MarketDataProvider` protocol so a licensed streaming provider can be added later without modifying alert logic or UI.
- Prefer streaming **only if the selected provider actually supports it**. Otherwise use configurable, quota-aware **batched polling**, adaptive backoff, and a visible update interval. Never promise 1-second updates if the plan cannot sustain them. Throttle automatically when approaching limits.
- Normalize incoming data: symbol, price, quote timestamp, source/provider, regular-session high when legitimately supplied, session state, and delay/staleness indication. Display **data age** prominently and suspend price-sensitive alerts when quotes are stale or delayed beyond a user-configurable tolerance.
- Make source restrictions and any Yahoo/third-party licensing or redistribution obligations explicit in README; **do not ship scraping-based Yahoo endpoints as a purported official/keyed API**.

## Reversal detection — MVP

Scope: **US regular trading hours (09:30–16:00 America/New_York)**, with a new session reset each trading day, including holiday/half-day handling via a market calendar or exchange-session API.

1. For each ticker, track the session's running high and calculate `pullbackPct = (sessionHigh - latestPrice) / sessionHigh * 100`.
2. Default **early warning: 0.25%** from high; **stronger warning: 0.40%**. Both configurable per ticker. These are **illustrative thresholds, not validated trading signals**.
3. Fire promptly when the threshold is crossed on **fresh market data**; do **not** require 30–60 minutes of confirmation. Optionally show a separate 1–5-minute momentum indicator based on sufficiently frequent data, clearly labeled as early/unconfirmed.
4. Distinguish **provider-reported session high** from **high observed since monitoring began**. If an authoritative session high is unavailable, label it “observed high”; do not misrepresent it as the day's actual high.
5. Send each threshold once per ticker per high-water-mark cycle, with cooldown/hysteresis to prevent spam. Rearm only on a meaningful new high (configurable) or a new session. Persist enough state to avoid duplicate alerts after closing/reopening the dashboard.
6. Prevent alerts on out-of-order timestamps, stale/delayed quotes, extended-hours trades, and obviously invalid spikes; show a clear disconnected/stale state.

## Architecture / implementation

- **Swift 6 + SwiftUI**, `MenuBarExtra` for menu-bar presentation; a separately controlled `Window`/`WindowGroup` for dashboard. Shared `@Observable`/actor-backed application state; monitoring owned by the app/service layer, **not the dashboard view lifecycle**.
- `MarketDataProvider` → normalized quote stream/poller → per-symbol `SessionHighTracker` → `ReversalAlertEngine` → `UNUserNotificationCenter` + sound → menu bar/dashboard.
- Store **API keys in macOS Keychain**, never plaintext preferences, logs, crash reports, or repo. Save watchlist, thresholds, and UI preferences in local app storage. No telemetry or cloud dependency by default. No trading credentials required.
- Make provider calls efficient across the watchlist (batch where supported), implement reconnect/retry, rate-limit handling, and basic diagnostics (last received time, polling cadence, errors, source).

## MVP acceptance criteria

- [ ] User can enter/test their own **third-party Yahoo Finance-compatible provider API key**; no app-developer key is bundled.
- [ ] User can monitor at least **five user-selected stock/ETF symbols** concurrently, with per-symbol thresholds.
- [ ] Menu bar stays active and alerts keep running after dashboard is closed; dashboard can reopen without losing state.
- [ ] Fresh-data threshold crossings trigger correct, de-duplicated notifications; false signals are labeled as possible, not certain, reversals.
- [ ] App explicitly identifies stale/delayed data, provider failures, quota exhaustion, and whether highs are **session** or **observed**.
- [ ] Tests cover session reset, after-hours/half-days, duplicate alerts, higher highs/rearming, out-of-order quotes, reconnection, and rate-limit behavior using recorded/mock quotes.
- [ ] Public repository contains build/run instructions, provider setup guide, privacy statement, license (e.g., MIT), and clear **third-party data-source and terms** disclaimers.

## Out of scope for v1

Brokerage order execution, portfolio holdings, predictive peak detection, guaranteed real-time/full-market data, backtesting, and hosted infrastructure. A true low-latency streaming provider is a future adapter if the keyed Yahoo-compatible provider's latency is insufficient.

## Reference links

- [yfinance project disclaimer and unofficial Yahoo endpoints](https://github.com/ranaroussi/yfinance)
- [RapidAPI authentication headers](https://docs.rapidapi.com/docs/configuring-api-security)
- [Example third-party Yahoo Finance Data API on RapidAPI](https://rapidapi.com/otterapi-otterapi-default/api/yahoo-finance-data-api3)
