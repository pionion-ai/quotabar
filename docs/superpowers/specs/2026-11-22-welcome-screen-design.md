# QuotaBar — first-run welcome screen (short design)

Status: approved 2026-11-22.

## Intent
On first launch, explain what QuotaBar is, why macOS will ask for the login
password (Keychain consent for the Claude Code item), and how credentials are
used — **before** any credential is read or any system prompt appears. Also
supports App Review's expectation of a consent step (guideline 5.1.1).

## Goals
- First launch shows a welcome window; no credential read, no notification
  prompt, no polling until the user clicks **Continue**.
- Copy is flavor-aware: App Store build names Claude Code + Codex; the direct
  build names all four providers and what each one reads.
- "How QuotaBar works" link in the popover footer reopens the window.
- Seen-state persisted in UserDefaults; later launches start immediately.
- Providers refresh in parallel, so Codex gauges appear while the Claude
  Keychain prompt is still open.

## Non-goals / anti-goals
- No multi-page onboarding, no settings in the window.
- Must not trigger any Keychain/notification prompt before Continue.

## Approaches
1. **AppKit `NSWindow` hosting a SwiftUI view, opened from code (chosen)** —
   full control over when it appears; works on macOS 13 in an LSUIElement app.
2. SwiftUI `Window` scene — opens on every launch by default; suppressing it
   needs `.defaultLaunchBehavior` (macOS 15+). Rejected for the macOS 13 floor.
3. Show the text inside the popover — the user must find the menu bar item
   first, and the Keychain prompt would already be up. Rejected.

## Design
- `WelcomeState` — `hasSeen(_ defaults:) -> Bool`, `markSeen(_ defaults:)`;
  key `welcomeSeenVersion` (Int, current 1) so a future copy change can re-show.
- `WelcomeContent.make(appStore: Bool) -> WelcomeContent` — pure model:
  title, subtitle, password section, usage bullets, provider list.
- `LaunchGate` — `launch()` calls `start` if seen, else `showWelcome`;
  `confirm()` marks seen then calls `start` (once). Both injected closures.
- `WelcomeWindow` — AppKit controller: centered, non-resizable window with
  `WelcomeView`; activates the app; Continue → `gate.confirm()` and close;
  Quit → terminate. Reopen-from-footer shows the same view with a single
  "Close" button (already started).
- `DashboardApp.init` no longer calls `Notifier.requestAuthorization()` /
  `startAll()` directly; `start` does both.
- `DashboardCoordinator.refreshAll()` uses a task group.
