# claude-usage-dashboard

A native macOS menu bar app showing live Claude Code subscription usage as
circular gauges, with a countdown to reopening when a limit is reached. A
self-contained companion to the `claude-usage` CLI tool (no Python needed).

## Requirements
- macOS 13 (Ventura) or later
- A logged-in Claude Code session (the token is read from the Keychain)
- Swift toolchain (Xcode or Command Line Tools) to build

## Build & run
```bash
swift build           # compile
swift run             # run from the terminal (dev)
./build-app.sh        # produce Dashboard.app (menu-bar-only, ad-hoc signed)
open Dashboard.app    # launch the bundled app
```

> Note: threshold/limit notifications only fire from the built `Dashboard.app`
> (run `./build-app.sh` then `open Dashboard.app`). Under bare `swift run` the
> process has no bundle identifier, so notifications are silently skipped.

After running `./build-app.sh`, confirm the app works with a quick visual
smoke test (this step is performed by you, the user): run `open Dashboard.app`
and check that a menu bar item appears showing `◔ N%` (or `…` briefly while
loading); clicking it opens the popover with circular gauges and reset
countdowns, and no Dock icon appears. Quit from the popover's Quit button.
If you are not logged in, the popover correctly shows "Not signed in." /
"Session expired." with a re-login button — that is the expected error state,
not a failure.

## Re-login

When a provider's session dies, its section shows a **Re-login to …** button.
Clicking it opens Terminal running that provider's CLI — `claude`, `codex
login`, or `gemini`. Finish the login there, then reopen the popover: it
refreshes on open, so the gauges heal immediately.

The dashboard never refreshes or writes tokens itself. It only reads the
credential store each CLI owns, so the button is a shortcut for typing the
command — it cannot verify that the login succeeded. If the session is still
dead afterwards, the same button reappears.

Gemini is the exception that proves the rule: it mints a short-lived access
token from a long-lived refresh token on every fetch, so it rarely asks. When
it does, the refresh token itself has expired.

## What it shows
- A circular gauge per usage window (5-hour, 7-day, per-model) showing **% left**,
  colored green → amber → red as it fills.
- The menu bar title shows the lowest remaining % (`◔ 92%`), or — when a limit is
  reached — a live `⛔ H:MM:SS` countdown to the soonest reopening.
- Optional notifications when a window crosses your threshold or hits its limit
  (set the threshold in the popover; off by default).

## How it works
Reads the OAuth token via `security find-generic-password -s "Claude Code-credentials"`,
calls `GET /api/oauth/usage`, and renders the windows. It polls every 60s; the
countdown ticks locally every second. Only reads — never writes credentials.

## Tests
```bash
swift test            # pure-logic unit tests (model, decoder, alerts, store)
```
The suite is 83 tests (model, decoder, alerts, store, coordinator, auth
recovery, launcher). Network and Keychain access sit behind a protocol and are
not unit-tested.
