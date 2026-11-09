# Vettira: working notes for agents

Vettira is a free, open-source, local-first macOS menu-bar app that watches a user's stock and
ETF watchlist and notifies them when a price pulls back from its session high by a threshold they
set. It reads quotes from Yahoo Finance's unofficial JSON endpoints, with no key and no account,
never places orders, and never calls an alert advice. The MVP spec is
[docs/spec.md](docs/spec.md); the architecture is [docs/architecture.md](docs/architecture.md).
How to contribute is [CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

- `Package.swift`, `Sources/VettiraCore/`: the app's logic, Foundation only, so it tests
  without a UI: quotes and the `MarketDataProvider` protocol (`Providers/`), the market session
  and session-high tracking (`Session/`), the reversal alert engine (`Alerts/`), the quote monitor
  that polls the watchlist (`Monitor/`), what the menu bar and its popover show (`Display/`),
  notifications' wording and delivery (`Notifications/`), and local storage (`Storage/`). Tests in
  `Tests/VettiraCoreTests/`, with recorded and mock quotes.
- `App/`: the macOS app (`App/Vettira/`): the menu-bar item (`NSStatusItem`) and its `NSPopover`,
  the dashboard window, SwiftUI views in each, settings,
  Keychain, notifications. `App/project.yml` is its XcodeGen project; the `.xcodeproj` is
  generated, never committed.
- `docs/`: the spec, the architecture, and the alerts and providers docs. `PRIVACY.md` and
  `README.md` are at the root.

## Build and test

Vettira needs macOS 14 or later and Xcode 16 or later (Swift 6).

```sh
swift test                    # VettiraCore's tests
swift build                   # the package
brew install xcodegen         # once: the app's Xcode project is generated
cd App && xcodegen generate   # then open App/Vettira.xcodeproj, or:
xcodebuild build -project App/Vettira.xcodeproj -scheme Vettira -destination 'platform=macOS'
```

CI (`.github/workflows/ci.yml`) runs the same on GitHub's macOS runners, in forks.

## Rules

- **Docs are part of the change.** A change updates the docs and diagrams that describe it, in
  the same PR: the README's usage, the architecture, the alerts and providers docs, `PRIVACY.md`.
- **Tests are part of the change.** New behaviour and every bug fix come with a test that fails
  without the change. Fix a bug test-first: see the test fail before the fix, then pass.
- **Diagrams are Mermaid in Markdown**, next to the text they illustrate, so they're diffed,
  reviewed and kept current like the rest of the doc. No images of diagrams.
- **Secrets never touch the repo.** Never print, log or commit a key, token or password.
- **Privacy:** never send a user's email or other personal information to outside services, and
  keep it out of PRs, logs and fixtures.
- **Never advice, never certainty.** No alert, notification, label or doc calls a pullback a
  sell signal, an instruction, or a confirmed reversal. Thresholds are illustrative, not validated
  signals.
- **Say what the data is.** A high the provider didn't supply as the regular-session high is the
  "observed high". Data age is always visible; a stale, delayed, out-of-order or extended-hours
  quote never fires a price alert. Never promise real-time, tick-by-tick or consolidated data.
- **Say where the data comes from.** Quotes come from Yahoo Finance's unofficial, undocumented
  JSON endpoints, which Yahoo's terms govern ([docs/spec.md](docs/spec.md)). Never call them
  official, documented, supported, licensed or endorsed, and never imply a licence to the data.
  JSON quote endpoints only: no scraping of Yahoo's web pages.
- **Be a light client.** As few requests as the endpoint allows. Yahoo's chart endpoint takes
  one symbol, so it's one request per enabled symbol per poll, sent one at a time, never in
  parallel, no faster than the poll interval, and at most one request a second overall. Back off
  on 429s and errors. No bulk or historical downloads. A plain, honest User-Agent, never a
  browser's: never impersonate a browser to get around a block.
- **Keys stay in the Keychain.** No developer key is ever bundled. Any key a future provider
  needs lives in the Keychain only, never in UserDefaults, files, logs, errors, fixtures or crash
  reports.
- **No telemetry**, and no network calls but the quote provider.
- **Live calls cost the user.** Yahoo rate-limits and blocks clients that call too often, and a
  block lands on the user's own IP address. Tests use recorded and mock quotes; never call a live
  provider in tests or CI.

## How we engineer

- **Prove it on the real thing.** Done means you ran it and saw it work: the real command, the
  actual value, the screen. Not "it compiles", and not a proxy like a log line or a file's
  timestamp.
- **Fix the root cause.** Reproduce first, then ask why until you reach the first thing the code
  did wrong, and fix it there. Look for the same mistake elsewhere.
- **Make the smallest change that solves it.** Fewer lines over new layers, and one place for
  each decision. Delete what's dead before building beside it.
- **Guard at the boundaries.** Check input where it comes in (arguments, files, the network) and
  turn it into the code's own types there. Inside, trust them.
- **Test behavior, not implementation.** Assert what the code's users can see: return values,
  errors, state they read back, requests sent. Take expected values from the requirement, not a
  run of the code.

## Pull requests and commits

One change is one PR, with small, descriptive commits with plain imperative subjects (`Add the
export button`), its tests and its docs. Say in the PR how you checked it.
