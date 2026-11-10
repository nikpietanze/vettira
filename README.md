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
> settings), the menu bar, notifications, the dashboard with watchlist editing, and Settings are
> built. There's no release to download yet: [build it](#build-and-run) with Xcode.

<p align="center">
  <img src="docs/assets/menu-bar.png" alt="Vettira's menu-bar item: its icon, a small chart of SPY's price today above the dotted line of the previous close, and SPY's price and change from its high" width="201">
</p>

<p align="center">
  <img src="docs/assets/popover.png" alt="Vettira's menu-bar popover: three symbols with today's chart, their price, observed high, change from the high, quote age and the warning this session, the connection's health, two switches, and the Open Dashboard, Settings and Quit buttons" width="360">
</p>

<p align="center">
  <img src="docs/assets/dashboard.png" alt="Vettira's dashboard window: the watchlist as a table of price, high, change from the high, thresholds, quote time and age, and the warning this session, above the connection's health and diagnostics" width="860">
</p>

<p align="center">
  <img src="docs/assets/settings.png" alt="Vettira's Settings window: the update interval, the stale-after time, the default thresholds, the data source with its disclaimer and a link to Yahoo's terms, Test Connection, and the switch for the chart in the menu bar" width="420">
</p>

<p align="center"><sub>The menu-bar item with today's chart, its popover, the dashboard and
Settings, from a demo run: the prices are made up (their source reads "Demo (made-up prices)"),
not Yahoo Finance's, and the times are New York's, the exchange's (EST).</sub></p>

## What it's for, and what it isn't

- **Watching your watchlist** of stocks and ETFs, each with its own thresholds, from the menu bar,
  whether or not its dashboard window is open.
- **Noticing a pullback**: it notifies you when a price falls from its session high by your early
  or stronger threshold (0.25% and 0.40% to start). Each fires once, until the high rises at least
  0.10% above the one it alerted on or a new session starts.
- **Not advice.** An alert is a possible, unconfirmed reversal, never a sell signal or an
  instruction. The thresholds are illustrative, not validated signals. What you do with an alert
  is your own decision.
- **Not a trading app.** It has no brokerage connection, needs no trading account, and places no
  orders.
- **Not real-time.** Quotes come at an interval and may be delayed. Each shows its age, and a
  stale or delayed quote never fires an alert.

## How it works

Vettira asks for each enabled symbol's latest quote, one request at a time. It tracks each
symbol's high for the US regular session (09:30 to 16:00 New York time, with holidays and early
closes), and fires an alert when the drop from that high crosses a threshold. When the data
doesn't include the session's high, Vettira uses the highest price it has seen, in its quotes and
the day's 5-minute bars, and labels it the "observed high". Alerts only fire on fresh quotes in regular hours.

More: [how alerts fire](docs/alerts.md) and [the architecture](docs/architecture.md).

## Where the data comes from

Quotes come from Yahoo Finance's **unofficial, undocumented** JSON endpoints, the ones its own web
pages use. Vettira needs no key and no account for them, and there's nothing to set up. Read this
before you use it:

- **Unofficial.** Yahoo has no public market-data API. It doesn't publish, document, support,
  license or endorse these endpoints, or Vettira's use of them. Vettira isn't affiliated with
  Yahoo, and nothing here gives you any right to Yahoo's data.
- **Yahoo's terms govern your use.** Yahoo's
  [Terms of Service](https://legal.yahoo.com/us/en/yahoo/terms/otos/index.html) apply to the data
  and to how it's reached. Among other things, they restrict collecting data from Yahoo's services
  by automated means, using the services commercially, and high-volume use, each without Yahoo's
  permission, and Vettira has no permission from Yahoo. Read the terms yourself: whether your use
  follows them is between you and Yahoo, and you're responsible for it. Vettira is for personal,
  non-commercial use on your own Mac; it shows the data only to you, and you shouldn't
  redistribute or republish it.
- **It can break or be blocked without notice.** Yahoo can change the endpoints, rate-limit them,
  or refuse requests from apps like Vettira, from your network or from your region, at any time.
  When it does, Vettira says so, and has no quotes and fires no alerts until they work again.
- **Delayed, not consolidated, not tick-by-tick.** A quote may lag the exchange, and the endpoint
  doesn't say by how much, so Vettira shows each quote's own time and age. It's Yahoo's view of
  the market, not the consolidated tape across every exchange, and Vettira sees the latest price
  each time it asks, not every trade between. Never rely on it as real-time data.

Vettira is a light client: one request per enabled symbol per update, never in parallel, at most
one a second, with a User-Agent that names Vettira (never a browser's), and it backs off when Yahoo
rate-limits it or errs. It reads no web pages and downloads no history. **Test Connection**, in
Settings, asks for one quote and says plainly what came back or what went wrong. The requests,
the fields Vettira reads and each error it can show: [docs/providers.md](docs/providers.md).

## Build and run

There's no download yet, so you build Vettira yourself. You need:

- **macOS 14 (Sonoma) or later** to run it.
- **Xcode 16 or later** to build it (the package needs Swift 6.0), from the App Store or
  [Apple's developer site](https://developer.apple.com/xcode/). Xcode 16 itself needs macOS 14.5
  or later. Open Xcode once after installing it so it finishes setting up, and if `xcodebuild`
  or `swift` complain that they need Xcode rather than the Command Line Tools, point them at it:
  `sudo xcode-select -s /Applications/Xcode.app`.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**, which writes the app's Xcode project from
  `App/project.yml` (the project isn't committed). With [Homebrew](https://brew.sh):
  `brew install xcodegen`.

No Apple developer account is needed: the app is signed to run on your own Mac.

**1. Get the code and generate the project:**

```sh
git clone https://github.com/nikpietanze/vettira.git
cd vettira
(cd App && xcodegen generate)
```

**2. Build and run it,** either way:

- **In Xcode:** `open App/Vettira.xcodeproj`, pick the **Vettira** scheme and **My Mac**, and
  press Run (Cmd-R).
- **From the terminal:**

  ```sh
  xcodebuild build -project App/Vettira.xcodeproj -scheme Vettira -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode
  open .build/xcode/Build/Products/Debug/Vettira.app
  ```

**3. Set it up.** Vettira has no Dock icon: it shows in the menu bar, near the clock. The
watchlist starts empty, so click its menu-bar item, pick **Open Dashboard**, and add a symbol by
its ticker (SPY, say). macOS asks once whether Vettira may send notifications; allow them to get
alerts. Alerts only fire in US regular trading hours; outside them Vettira checks every 10
minutes, and the menu bar shows the last session's price, marked closed.

Run `git pull` and step 1's `xcodegen generate` again after updating, since a change can add files
to the project.

### Try it with made-up prices

A Debug build (like the ones above) can run on made-up prices instead of Yahoo's, at any time of
day, with a settings file of its own, so it leaves your watchlist alone. Quit the copy you started
above first (**Quit Vettira** in its popover): `open` passes these arguments only when it starts
the app, and otherwise just brings the running one forward:

```sh
mkdir -p /tmp/vettira-demo
echo '{"watchlist": {"entries": [{"symbol": "SPY"}, {"symbol": "QQQ"}]}, "updateInterval": 10}' \
  > /tmp/vettira-demo/settings.json
open .build/xcode/Build/Products/Debug/Vettira.app --args --demo --settings-dir /tmp/vettira-demo
```

`--demo` makes up prices that, at this 10-second update interval, warn early and then stronger
about a minute after launch. `--settings-dir` reads and writes `settings.json` in that folder
instead of your own. With either, alerts go only to the app's log, not to Notification Center,
unless you add `--notify`. In Xcode, add the same arguments under Product, Scheme, Edit Scheme…,
Run, Arguments. `--snapshot <folder>` makes a demo run that, once the warnings have come (or
after `--snapshot-after <seconds>`), saves pictures of the menu-bar item, the popover, the
dashboard and Settings, in light and dark, to that folder, offscreen, and quits. A Release build
ignores them. More: [the demo provider](docs/providers.md#the-demo-provider).

### Run the tests

```sh
swift test
```

From the repo's root, they test the logic (quotes, sessions, alerts, the monitor, what the app
shows, storage) on recorded and mock quotes, and never call Yahoo.

## Using it

The menu bar shows one symbol's price and its change from the high, with a small chart of its
price today, updated each poll: green while it's above the previous close, red while it's below
(up or down on the day, not advice; turn it off in Settings for a narrower menu bar). Click it for
every symbol's chart, price, high, pullback and data age, and the connection's health. A pullback past a threshold sends
a notification, worded as a possible reversal, never advice. Closing a window leaves Vettira
running in the menu bar, still monitoring, until you pick **Quit Vettira**.

**Open Dashboard**, in that popover, opens a window with the whole watchlist in a table: each
symbol's price, high (session or observed), change from the high, thresholds, quote time, data age
and last warning, then the connection's health and diagnostics. Add a symbol by its ticker, search
the list, drag rows or use the arrows to reorder it, pin symbols to the top, switch one off to stop
updating it, give one its own thresholds, or pick the one the menu bar shows. **Settings…** (in the
popover and the dashboard, or Cmd-, while a window is open) sets the update interval, how old a
quote can be before it's stale, the default thresholds and whether the menu bar shows its chart,
and has **Test Connection**. Each
change is saved as you make it. While one of its windows is open Vettira shows in the Dock and the
app switcher; closing the last one takes it back to the menu bar only.

## Privacy

No account, no server of its own and no telemetry. Your watchlist and settings stay on your Mac,
and the only requests Vettira makes are for quotes. The details: [PRIVACY.md](PRIVACY.md).

## Contributing

Bug reports, ideas and pull requests are welcome: [CONTRIBUTING.md](https://github.com/nikpietanze/vettira/blob/main/CONTRIBUTING.md).

## License

[MIT](LICENSE). Vettira is provided as is, without warranty of any kind, as the license says. Yahoo
and Yahoo Finance are Yahoo's trademarks, named here only to say where the data comes from.
