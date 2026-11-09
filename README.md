# Vettira

A free, open-source, local-first macOS menu-bar app that watches your stock and ETF watchlist and
notifies you when a price pulls back from its session high by a threshold you set.

Vettira is a monitoring tool, not trading advice. It never places orders, and its alerts are
possible, unconfirmed reversals, not instructions to buy or sell.

Work in progress.

## Building

Vettira needs macOS 14 or later and Xcode 16 or later (Swift 6).

```sh
swift test                                 # the logic's tests
brew install xcodegen                      # once: the app's Xcode project is generated
cd App && xcodegen && open Vettira.xcodeproj
```

The app runs in the menu bar; closing its dashboard leaves it running until you pick Quit. How
it's put together: [docs/architecture.md](docs/architecture.md).

What Vettira stores and sends: [PRIVACY.md](PRIVACY.md).
