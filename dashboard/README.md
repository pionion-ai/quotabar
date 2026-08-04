# QuotaBar

A native macOS menu bar app showing live AI-subscription usage (Claude Code,
plus Codex and Gemini when present) as circular gauges, with a countdown to
reopening when a limit is reached. A self-contained companion to the repo's
CLI scripts (no Python needed).

<img src="../docs/img/popover.png" alt="QuotaBar popover showing usage gauges for Claude Code, Codex and Gemini" width="360">

> **Unofficial tool.** Not affiliated with Anthropic, OpenAI, or Google; it
> reads the usage data through the same private endpoints the official CLIs
> use, and those can change without notice. See the
> [disclaimer in the root README](../README.md#disclaimer--unofficial-tool-private-endpoints).

## Requirements
- macOS 13 (Ventura) or later
- A logged-in Claude Code session (the token is read from the Keychain).
  Codex and Gemini sections appear automatically if those CLIs are logged in.

## Install (prebuilt)

Download `QuotaBar.dmg` from the GitHub Releases page, open it,
and drag `QuotaBar.app` to Applications. Release dmgs are Developer ID
signed **and notarized**, so Gatekeeper opens them without warnings.

The app is menu-bar-only: look for `◔ N%` in the menu bar, not the Dock.

## First run — what to expect

1. **A Keychain dialog** ("security wants to access …Claude Code-credentials")
   appears the first time the app reads the Claude Code token. This is
   QuotaBar reading — never writing — the token the Claude CLI stored; see
   the security section below. Click **Always Allow**, or you'll be asked
   again on every 60-second refresh.
2. **Gauges appear** for every provider whose CLI is logged in. Codex and
   Gemini sections show up automatically when `~/.codex/auth.json` /
   `~/.gemini/oauth_creds.json` exist — nothing to configure.
3. **"Not signed in."** with a re-login button is the normal state for a
   provider whose CLI has no session yet. The button opens Terminal running
   that CLI (`claude`, `codex login`, `gemini`); if you've never installed
   the CLI, the popover shows the `npm install -g …` command to run first.
4. **Notifications** are optional and off by default — enabling the
   threshold alert triggers the standard permission prompt.

QuotaBar needs at least one logged-in CLI to show anything useful. There is
no account, no sign-up, and no configuration of its own.

## Security: what the app does with your tokens

- It **reads** each provider's credentials from the store its own CLI uses
  (Claude: Keychain, Codex: `~/.codex/auth.json`, Gemini: its OAuth cache).
  It never writes, refreshes, or deletes credentials.
- Each token is sent **only to its own provider's usage endpoint** — no
  telemetry, no third-party servers, no analytics.
- The full source is in `Sources/Dashboard/` — a handful of small Swift
  files you can audit, and `swift build` reproduces the app.

## Build & run (from source)

Requires a Swift toolchain (Xcode or Command Line Tools).
```bash
swift build           # compile
swift run             # run from the terminal (dev)
./build-app.sh        # produce QuotaBar.app (menu-bar-only, ad-hoc signed)
open QuotaBar.app     # launch the bundled app
```

> Note: threshold/limit notifications only fire from the built `QuotaBar.app`
> (run `./build-app.sh` then `open QuotaBar.app`). Under bare `swift run` the
> process has no bundle identifier, so notifications are silently skipped.

After running `./build-app.sh`, confirm the app works with a quick visual
smoke test (this step is performed by you, the user): run `open QuotaBar.app`
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
The suite covers the model, decoders, alerts, store, coordinator, auth
recovery, and launcher. Network and Keychain access sit behind a protocol and
are not unit-tested.
