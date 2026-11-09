<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <img src="docs/assets/logo-light.svg" alt="Vettira" width="340">
  </picture>
</p>

<p align="center">
  A macOS menu-bar app that tells you when a stock or ETF pulls back from its session high.
</p>

Vettira is free, open source and local-first. It watches your stock and ETF watchlist from the
menu bar and notifies you when a price falls from its session high by a threshold you set.

> **Status: in progress.** The logic (quotes, market sessions, session highs, alerts and
> settings), the menu bar and notifications are built. The dashboard's table and watchlist editing
> are next, so for now the watchlist is set in its settings file.

## What it's for, and what it isn't

- **Watching your watchlist** of stocks and ETFs, each with its own thresholds, from the menu bar,
  whether or not its dashboard window is open.
- **Noticing a pullback**: it notifies you when a price falls from its session high by your early
  or stronger threshold (0.25% and 0.40% to start). Each fires once, until the high rises at least
  0.10% above the one it alerted on or a new session starts.
- **Not advice.** An alert is a possible, unconfirmed reversal, never a sell signal or an
  instruction. The thresholds are illustrative, not validated signals.
- **Not a trading app.** It has no brokerage connection and places no orders.
- **Not real-time.** Quotes come at an interval and may be delayed. Each shows its age, and a
  stale or delayed quote never fires an alert.

## How it works

Vettira asks for each enabled symbol's latest quote, one request at a time. It tracks each
symbol's high for the US regular session (09:30 to 16:00 New York time, with holidays and early
closes), and fires an alert when the drop from that high crosses a threshold. When the data
doesn't include the session's high, Vettira uses the highest price it has seen and labels it the
"observed high". Alerts only fire on fresh quotes in regular hours.

More: [how alerts fire](docs/alerts.md) and [the architecture](docs/architecture.md).

## Where the data comes from

Quotes come from Yahoo Finance's **unofficial, undocumented** JSON endpoints, the ones its own web
pages use. Vettira needs no key and no account for them, but:

- Yahoo doesn't document, support or endorse them, or Vettira's use of them, and Vettira isn't
  affiliated with Yahoo.
- Yahoo's [terms of service](https://legal.yahoo.com/us/en/yahoo/terms/otos/index.html) govern
  your use of the data. Vettira is for personal use on your own Mac; don't redistribute the data.
- Yahoo can change, rate-limit or block them at any time. When it does, Vettira says so and has no
  quotes until they work again.

Vettira is a light client: one request per enabled symbol per update, never in parallel, at most
one a second. The details: [docs/providers.md](docs/providers.md).

## Building

Vettira needs macOS 14 or later and Xcode 16 or later (Swift 6).

```sh
swift test                    # the logic's tests, on recorded and mock quotes
brew install xcodegen         # once: the app's Xcode project is generated
cd App && xcodegen generate && open Vettira.xcodeproj
```

Run the `Vettira` scheme. The app lives in the menu bar; closing its dashboard leaves it running
until you pick Quit. The menu bar shows one symbol's price and its change from the high; click it
for every symbol's price, high, pullback and data age, and the connection's health. A pullback
past a threshold sends a notification, worded as a possible reversal, never advice.
Contributing: [CONTRIBUTING.md](https://github.com/nikpietanze/vettira/blob/main/CONTRIBUTING.md).

To try it without calling Yahoo, run a Debug build with `--demo` (made-up prices) and
`--settings-dir <folder>` (a settings file other than your own). Its alerts then go only to the
app's log, not to Notification Center, unless you add `--notify`:
`open Vettira.app --args --demo --settings-dir /tmp/vettira-demo`.

## Privacy

No account, no server of its own and no telemetry. Your watchlist and settings stay on your Mac,
and the only requests Vettira makes are for quotes. The details: [PRIVACY.md](PRIVACY.md).

## License

[MIT](LICENSE).
