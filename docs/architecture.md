# Architecture

**Code:** `Package.swift`, `Sources/VettiraCore/`, `App/`.

Vettira is a Swift package, `VettiraCore`, holding the app's logic, and a macOS app, `Vettira`,
that shows it in the menu bar and a dashboard window. The logic uses Foundation only, so its tests
run with `swift test` and need no UI, no network and no provider key: they use recorded and mock
quotes.

## Targets

```mermaid
flowchart LR
    app["<b>Vettira</b><br/>macOS app (App/project.yml)<br/>menu bar, dashboard, settings,<br/>Keychain, notifications"]
    core["<b>VettiraCore</b><br/>library (Package.swift)<br/>Foundation only"]
    tests["<b>VettiraCoreTests</b><br/>Swift Testing"]
    app -- depends on --> core
    tests -- tests --> core
```

| Target | Where | What it is |
|---|---|---|
| `VettiraCore` | `Sources/VettiraCore/` | The logic: quotes and the market-data provider protocol (`Providers/`), the market session and session-high tracking (`Session/`), the reversal alert engine (`Alerts/`), local storage (`Storage/`) |
| `VettiraCoreTests` | `Tests/VettiraCoreTests/` | Its tests, on recorded and mock quotes |
| `Vettira` | `App/Vettira/` | The app, from `App/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen): a `MenuBarExtra` and a dashboard `Window`. Bundle ID `com.andiamosoftware.vettira`, macOS 14 and later, menu bar only (`LSUIElement`), so it has no Dock icon |

The Xcode project is generated, never committed: `cd App && xcodegen`, then open
`App/Vettira.xcodeproj`.

## The app

The menu-bar item is the app: it runs until the user picks **Quit** from its menu. The dashboard is
a separate `Window` scene the menu opens (**Open Dashboard**); closing it leaves the menu-bar item,
and monitoring, running. Monitoring will belong to the app's shared state, not to the dashboard's
views, so it doesn't stop or restart when the window closes or opens.

So far the app is the shell: a menu with Open Dashboard and Quit, and an empty dashboard.

## The pipeline (planned)

How a quote becomes an alert, once the parts are built. Each box is a part of `VettiraCore`
except the last, which is the app.

```mermaid
flowchart LR
    provider["<b>MarketDataProvider</b><br/>the user's keyed provider<br/>(Providers/)"]
    poller["<b>Poller</b><br/>batched, quota-aware polling;<br/>normalized quotes"]
    tracker["<b>SessionHighTracker</b><br/>per symbol: session or<br/>observed high, pullback<br/>(Session/)"]
    engine["<b>ReversalAlertEngine</b><br/>thresholds, once per high,<br/>rearming; never on stale,<br/>out-of-order or extended-hours<br/>quotes (Alerts/)"]
    ui["<b>App</b><br/>notifications, menu bar,<br/>dashboard"]
    calendar["<b>MarketCalendar</b><br/>session state, trading day,<br/>open and close; NYSE<br/>holidays (Session/)"]
    provider --> poller --> tracker --> engine --> ui
    calendar -. session .-> tracker
    calendar -. session .-> engine
    poller -. data age, errors, quota .-> ui
```

The market calendar is built: for any instant it gives the US regular session's state, the
trading day it belongs to and that session's open and close, from NYSE's published holidays and
early closes. [alerts.md](alerts.md) describes the session rules and the years it covers.

An alert is a possible, unconfirmed reversal, never advice or an instruction to sell, and its
thresholds are illustrative. The spec is [spec.md](spec.md).
