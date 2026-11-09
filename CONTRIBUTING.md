# Contributing to Vettira

Thanks for helping. Bug reports, ideas and pull requests are all welcome; for anything bigger
than a fix, open an issue first so we can agree on the shape before you build it.

## Building and testing

Vettira needs macOS 14 or later and Xcode 16 or later (Swift 6).

```sh
swift test                    # the logic's tests, on recorded and mock quotes
brew install xcodegen         # once: the app's Xcode project is generated
cd App && xcodegen generate && open Vettira.xcodeproj
```

The tests never call Yahoo Finance's live endpoints, and neither should yours: use recorded or
mock quotes.

## Pull requests

- One change per PR, with the tests that show it works and the docs it changes
  (the README, `docs/`, `PRIVACY.md`). Say in the PR how you checked it.
- Keep to the app's rules in [AGENTS.md](AGENTS.md): no advice or certainty in alerts, honest
  data labels and ages, honesty about where the data comes from, a light client, no telemetry.
- CI runs the tests and builds the app in your fork, on GitHub's macOS runners, when you push.
  Enable Actions in your fork to see it. It doesn't run on this repo itself.

This repo is published from the maintainer's development repo, so a PR isn't merged here with
GitHub's merge button. Once it's accepted, the change lands there, with you as its author, and
arrives here with the next publish; the PR is then closed with a link to the commit.

By contributing, you agree that your work is licensed under the [MIT License](LICENSE).
