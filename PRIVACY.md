# Privacy

Vettira runs on your Mac. It has no account, no API key, no server of its own and no telemetry:
it collects nothing about you and sends nothing about you anywhere.

## What it stores, and where

Everything stays on your Mac, in one file:
`~/Library/Application Support/Vettira/settings.json`, plain JSON. It holds your watchlist (its
symbols and their order, which are pinned or enabled, each symbol's own thresholds, and the
symbol the menu bar shows) and your default thresholds. Nothing else.

If the file isn't valid settings, Vettira moves it to `settings.corrupt.json` in the same folder
and starts from the defaults, so the old file isn't overwritten.

## What it sends

The only network requests Vettira makes are to Yahoo Finance's unofficial, undocumented
`v8/finance/chart` endpoint: one request per enabled symbol on your watchlist, each time it
updates. They carry no account, no key and no cookie, and a User-Agent that names Vettira.
Nothing else goes out: no analytics, no crash reporting, no update checks. Yahoo sees those
requests (the symbols and your IP address) under its own terms and privacy policy.

## Removing it

To remove everything Vettira keeps: quit it and delete `~/Library/Application Support/Vettira/`.
