# claude-usage-dashboard — native macOS menu bar dashboard

_Design spec · 2026-06-28_

## Purpose

A native macOS menu bar app that shows, in real time, how much of the Claude
Code subscription is left across its rate-limit windows, using the standard
macOS circular gauges. When a window's limit is reached, it shows a live
countdown to when tokens become available again — both in the popover and in
the menu bar title itself.

It is a sub-subproject of `claude-usage`: a presentation surface over the same
`/oauth/usage` data the CLI tool already reads, but fully self-contained (it
does **not** shell out to `claude_usage.py`).

## Scope

**In scope:** the core usage windows (5-hour, 7-day all-models, per-model
weekly) as % left, reset countdowns, a prominent "limit reached" countdown, and
threshold/limit notifications.

**Out of scope** (deliberately, to stay lean): the `--estimate` per-model token
headroom and the `--api-credits` Admin spend report. The dashboard reads exactly
one endpoint.

## Location & layout

Nested inside the existing `claude-usage` git repo as a subdirectory, versioned
alongside the CLI tool but independently buildable:

```
claude-usage/dashboard/
  Package.swift                  SwiftPM executable, macOS 13+ target
  Sources/Dashboard/
    DashboardApp.swift           @main MenuBarExtra, timers, app wiring
    UsageClient.swift            token read + /oauth/usage call + decoding
    UsageModel.swift             value types: UsageWindow, WindowState, colors
    GaugesView.swift             popover UI (native Gauge + countdown views)
  Tests/DashboardTests/
    UsageModelTests.swift        pure-logic tests (no UI, no network)
  Resources/Info.plist           LSUIElement=1, bundle id, version
  build-app.sh                   swift build → Dashboard.app (+ ad-hoc sign)
  README.md
```

Build/run from the CLI: `swift build` / `swift run` for development;
`./build-app.sh` produces `Dashboard.app` (a menu-bar-only agent app, no Dock
icon, via `LSUIElement`).

## Architecture

Three responsibilities, each isolated so it can be understood and tested alone:

1. **UsageClient** — fetches and decodes. Knows nothing about UI.
2. **UsageModel** — pure value types and derivations (state classification,
   color buckets, countdown formatting). No I/O.
3. **GaugesView + DashboardApp** — render state and drive timers. No business
   logic beyond presentation.

### Data flow

```
Timer (60s) ──▶ UsageClient.fetch() ──▶ [UsageWindow] ──▶ @Published store
                                                              │
Timer (1s)  ──────────── recompute countdowns ──────────────▶ GaugesView
                                                              │
                                                       menu bar title
```

- The **60s timer** is the only thing that hits the network. The percentages
  only move when Claude is actually used, so a tighter poll buys nothing.
- The **1s timer** recomputes `resetsAt − now` locally (no network) so
  countdowns tick smoothly and a reached limit visibly counts down to reopening.

## UsageClient

```
protocol UsageProviding { func fetch() async throws -> [UsageWindow] }
struct UsageClient: UsageProviding { ... }
```

- **Token:** shell out to `/usr/bin/security find-generic-password -s
  "Claude Code-credentials" -w` via `Process`, then JSON-decode and read
  `claudeAiOauth.accessToken`. This mirrors the CLI tool and avoids the keychain
  ACL prompt that `SecItemCopyMatching` triggers when reading another app's
  item. (No Linux fallback — this is a macOS app.)
- **Request:** `GET https://api.anthropic.com/api/oauth/usage` via `URLSession`
  with headers `Authorization: Bearer <token>` and
  `anthropic-beta: oauth-2025-04-20`.
- **Decode:** `Codable` into the four known windows (`five_hour`, `seven_day`,
  `seven_day_opus`, `seven_day_sonnet`); unknown/absent windows are skipped, not
  fatal. Each yields a `UsageWindow { key, label, usedPercent, resetsAt }`.
- **Errors** map to a typed `FetchError` (`.notLoggedIn`, `.authExpired` for
  401, `.network`, `.decode`) so the UI can show a precise message — e.g. a 401
  renders "Token expired — run `claude` once to refresh."

`UsageProviding` is a protocol so tests inject a fake provider with canned data.

## UsageModel (pure logic)

```
struct UsageWindow { let key, label: String; let usedPercent: Double; let resetsAt: Date }

enum WindowState { case ok(remaining: Double)      // usedPercent < 100
                   case reached(reopensAt: Date) } // usedPercent >= 100

extension UsageWindow {
    var state: WindowState
    var remainingPercent: Double          // 100 - usedPercent, clamped 0…100
    func countdown(now: Date) -> String   // "4h 53m" loose, "1:11:48" when reached
    func color(now: Date) -> GaugeColor   // green / amber / red buckets
}
```

- **Color buckets** by % used: `< amberAt` green, `amberAt…<redAt` amber,
  `>= redAt` red. Defaults amber=75, red=90; `reached` is always red.
- **Countdown format** has two modes: the loose `"4h 53m"` style (mirrors the
  CLI's `humanize_delta`) for healthy windows, and a precise `H:MM:SS` for a
  window whose limit is reached — because that's the one you actively watch.
- All of this is deterministic given `(window, now)`, so it is unit-tested
  directly with no UI or network.

## UI (GaugesView)

The popover, top to bottom:

- **Header:** "Claude Code Usage" + last-checked time.
- **Reached windows first** (if any): a bold ⛔ row with the window label and a
  large monospaced `H:MM:SS` "available in" countdown, ticking every second.
  When it hits zero, the next 60s poll confirms reopening and the row reverts to
  a normal gauge.
- **Healthy windows:** one native SwiftUI `Gauge`
  (`.gaugeStyle(.accessoryCircular)`) each, showing **% left**, colored by
  bucket, with the loose reset countdown beneath.
- **Footer:** a threshold control (stepper/toggle, see Alerts) and a quit item.

**States the view must handle**, each its own small subview so none leaks into
another: `loading`, `loaded(windows)`, `error(FetchError)`.

### Menu bar title

The `MenuBarExtra` label reflects the most urgent window without opening the
popover:

- Any window **reached** → `⛔ H:MM:SS` for the **soonest** reopening (the one
  that frees you first).
- Otherwise → `◔ N%` showing the **lowest remaining %** across windows, tinted
  green/amber/red.
- Loading → a neutral glyph; error → a warning glyph.

## Alerts

- A user threshold on **% used**, stored in `UserDefaults`, **off by default**;
  editable from the popover footer.
- **Two transition-triggered notifications**, each fired once on the crossing
  (not repeated every poll), de-duplicated by tracking the previous state per
  window:
  - **Approaching** — window first crosses the threshold: "5-hour window at 85%
    used · resets in 1h 12m".
  - **Limit reached** — window first hits 100%: "5-hour limit reached ·
    available in 1h 12m".
- Delivered via `UNUserNotificationCenter`. This requires the app to be bundled
  and code-signed; `build-app.sh` ad-hoc signs the bundle (`codesign --sign -`).
  If signing is ever undesirable, the documented fallback is
  `osascript -e 'display notification'` via `Process`, which needs no
  entitlements.

## Testing

A SwiftPM test target exercising the pure logic only, with a fake
`UsageProviding`:

- Decoding a representative `/oauth/usage` JSON payload into `[UsageWindow]`,
  including missing-window tolerance.
- `WindowState` classification at the 99.9 / 100 boundary.
- `countdown` formatting in both modes (loose vs `H:MM:SS`, and past-due → "now"
  / reopened).
- Color bucket boundaries (74/75/89/90/100).
- Alert de-dup: a window crossing a threshold once produces exactly one
  "approaching" event; staying over it produces none; reaching 100% produces one
  "reached" event.

No UI snapshot or live-network tests — the network and Keychain sit behind the
protocol and are not unit-tested.

## Refresh & lifecycle summary

| Concern            | Mechanism                                            |
|--------------------|------------------------------------------------------|
| Usage data refresh | 60s repeating timer → `UsageClient.fetch()` (async)  |
| Countdown tick     | 1s repeating timer → recompute from cached `resetsAt`|
| Menu-bar-only app  | `LSUIElement=1` in Info.plist (no Dock icon)         |
| Persistence        | `UserDefaults` for the alert threshold only          |
| Min OS             | macOS 13 (Ventura) — `MenuBarExtra` + `Gauge`        |

## Non-goals / future

Token-headroom estimate, API-spend, configurable poll interval, multiple-account
support, and notarized distribution are explicitly out of this first version.
They can be layered on later without changing the three-responsibility split.
