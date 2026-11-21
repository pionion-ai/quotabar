# Welcome Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** First-run welcome window that explains the app and the Keychain prompt before any credential is read; parallel provider refresh.

**Architecture:** Pure pieces (`WelcomeState`, `WelcomeContent`, `LaunchGate`) are unit-tested; `WelcomeWindow` (AppKit + SwiftUI view) and `DashboardApp` wiring are verified by build + manual run.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-22-welcome-screen-design.md`

## Global Constraints
- macOS 13 floor; no API newer than macOS 13 without `#available`.
- Nothing may read credentials or request notification permission before Continue on first launch.
- Tests pass in both flavors: `arch -arm64 swift test` and `arch -arm64 swift test -Xswiftc -DAPPSTORE`.
- UserDefaults key `welcomeSeenVersion`, current version `1`.

## Review Focus
1. User closes the welcome window with the red close button (not Continue/Quit) → app must not sit idle forever; treat as Continue? → **Ruling in design: closing = Continue is wrong (no consent); closing quits?** Decision: the window has no close button (`.titled` without `.closable`); only Continue/Quit.
2. Welcome reopened from the footer after start → no second `start()` (gate starts once).
3. App launched again after Continue → no window, starts immediately.
4. Keychain prompt pending → Codex section still loads (parallel refresh).
5. Window appears in front despite LSUIElement (activate app).

---

### Task 1: WelcomeState + LaunchGate
**Files:** Create `Sources/Dashboard/Welcome.swift`; Test `Tests/DashboardTests/WelcomeTests.swift`.
**Produces:** `enum WelcomeState { static let currentVersion = 1; static func hasSeen(_ d: UserDefaults = .standard) -> Bool; static func markSeen(_ d: UserDefaults = .standard) }`; `final class LaunchGate { init(hasSeen: Bool, start: @escaping () -> Void, showWelcome: @escaping () -> Void, markSeen: @escaping () -> Void); func launch(); func confirm() }`.
- [ ] Tests: fresh defaults → `hasSeen == false`; after `markSeen` → true; stored version 0 → false. Gate: unseen `launch()` → showWelcome once, start 0; `confirm()` → markSeen 1, start 1; second `confirm()` → start still 1; seen `launch()` → start 1, showWelcome 0.
- [ ] RED, implement, GREEN both flavors, commit.

### Task 2: WelcomeContent
**Produces:** `struct WelcomeContent: Equatable { let title, subtitle, passwordHeading, passwordBody, usageHeading: String; let usageBullets: [String]; static func make(appStore: Bool) -> WelcomeContent }`.
- [ ] Tests: title "Welcome to QuotaBar"; appStore body mentions "Claude Code", "Always Allow", "~/.codex/auth.json", not "Gemini"/"Cursor"; direct body mentions "Gemini" and "Cursor"; bullets include read-only, sent only to its own provider, Deny is fine.
- [ ] RED, implement, GREEN, commit.

### Task 3: Parallel refreshAll
- [ ] Test in `DashboardCoordinatorTests`: provider A awaits a gate that provider B's fetch opens; `refreshAll()` completes within 2 s (sequential would hang). RED (times out), implement with `withTaskGroup`, GREEN, commit.

### Task 4: WelcomeWindow + wiring
**Files:** Create `Sources/Dashboard/WelcomeWindow.swift`; Modify `DashboardApp.swift`, `GaugesView.swift` footer.
- [ ] `WelcomeView(content:, primaryTitle:, onPrimary:, onQuit: (() -> Void)?)`; `WelcomeWindow.show(content:, firstRun: Bool, onContinue:)` — `NSWindow` styleMask `[.titled]` (+ `.closable` when not first run), centered, `NSApp.activate(ignoringOtherApps: true)`, level normal.
- [ ] `DashboardApp.init`: build `LaunchGate` with `start = { Notifier.requestAuthorization(); coordinator.startAll() }`; call `gate.launch()` on next main-loop turn. Footer gets "How it works" button → `WelcomeWindow.show(firstRun: false)`.
- [ ] Build both flavors; ADHOC package; manual run with fresh defaults (`defaults delete ai.pionion.quotabar welcomeSeenVersion` in container) → window first, Keychain prompt only after Continue. Commit; README "First run" updated.
