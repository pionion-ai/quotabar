# Re-login affordance — design

Date: 2026-07-26
Status: approved

## Problem

The dashboard reads credentials that other CLIs own. For Claude and Codex it
takes the access token as-is and never renews it, so when the short-lived token
lapses the usage endpoint returns 401 and the popover shows an error. Recovery
requires the user to leave the app, find a terminal, and remember the right
command.

Two things make this worse than it needs to be:

1. `GaugesView.errorView` hardcodes "run `claude` once to refresh" for every
   provider, so a Codex or Gemini 401 tells the user to run the wrong tool.
2. Once a provider has loaded data, a later auth failure only produces
   "Couldn't refresh — showing last update". The gauges keep rendering stale
   numbers and nothing says the session died.

## Goal

Turn an auth failure into a single click that starts the correct login flow,
without the dashboard ever writing to a credential store it does not own.

Non-goals: refreshing or persisting tokens ourselves, proactive expiry
warnings, changing the retry cadence.

## Decisions

| Question | Decision |
|---|---|
| What the button does | Opens Terminal running the provider's CLI |
| How the dashboard notices the new token | Refresh when the popover opens (plus the existing 60s timer) |
| Where the button appears | Both the blank error view and the stale hint, whenever the error is auth-related |
| Gemini | Included, worded for its case (a dead refresh token genuinely needs re-auth) |
| Proactive `expiresAt` warning | Out of scope — separate feature |

Rejected: clipboard-copy fallback (YAGNI; add if Terminal.app proves wrong for
the user's setup), faster retry while 401-ing (more chatter against an endpoint
that is already failing, for little gain over refresh-on-open).

## Architecture

The interesting decision — *which errors get a button, and what does it say* —
is pure and unit-tested. The OS interaction is a single injected seam, matching
the `tokenReader` / `transport` pattern already used by every provider client.

### `AuthRecovery.swift` (new)

```swift
struct ReloginPrompt: Equatable {
    let message: String       // "Token expired — Claude Code sign-in needed."
    let buttonTitle: String   // "Re-login to Claude Code…"
    let command: String       // "claude"
}

enum AuthRecovery {
    /// Non-nil only for auth failures the user can fix by re-running a CLI.
    static func prompt(for error: FetchError, provider: String) -> ReloginPrompt?
    /// The quiet hint shown under still-visible gauges after a failed refresh.
    static func staleMessage(for error: FetchError) -> String
}
```

- `prompt` returns non-nil for `.authExpired` and `.notLoggedIn` only; `nil` for
  `.rateLimited`, `.network`, `.decode`.
- Commands by provider id: `claude` → `claude`, `codex` → `codex login`,
  `gemini` → `gemini`.
- An unrecognised provider id returns `nil`. Failing closed is correct here:
  showing no button beats offering a wrong command.
- `staleMessage` keeps today's wording for non-auth errors and returns the auth
  message when the failure is auth-related.

### `TerminalLauncher.swift` (new)

```swift
struct TerminalLauncher {
    let baseDirectory: URL              // injected so tests write to a temp dir
    let open: (URL) -> Void             // injected; real one is NSWorkspace.open

    func launch(command: String, providerID: String)

    static let live: TerminalLauncher   // caches dir + NSWorkspace
}
```

`launch`:

1. Writes `<baseDirectory>/relogin-<providerID>.command` containing `#!/bin/sh`
   and `exec <command>`.
2. `chmod 0755`.
3. Calls `open(url)` — Terminal.app runs it in a new window.

`live.baseDirectory` is
`~/Library/Caches/com.claudeusage.dashboard/`, created on demand.

A fixed per-provider filename means repeat clicks overwrite rather than litter.
AppleScript / `do script` is deliberately avoided: it would require
`NSAppleEventsUsageDescription` and an Automation consent dialog. The app is not
sandboxed (ad-hoc signed, only `get-task-allow`), so `NSWorkspace.open` needs no
entitlement.

The command string is a compile-time constant chosen by `AuthRecovery`. Nothing
external is interpolated into the script.

### `GaugesView.swift` (modified)

`ProviderSection` gains `providerID: String` and
`launch: (_ command: String, _ providerID: String) -> Void`.

- `errorView(_:)` calls `AuthRecovery.prompt`. Non-nil → message + button.
  Nil → today's text for that error case. This removes the Claude-specific
  wording currently shown to all providers.
- The stale hint calls the same function. Non-nil → auth message + button
  instead of "Couldn't refresh". Nil → unchanged.

`GaugesView` passes `entry.id` through and defaults `launch` to
`TerminalLauncher.live.launch(command:providerID:)`, so a spy can be substituted.

### `DashboardCoordinator.swift` (modified)

Add `func refreshAll() async`, mirroring `startAll()`. `DashboardApp` calls it
from a `.task` on the popover content, so opening the menu triggers a refresh.

`UsageStore.refresh()` already guards re-entrancy via `isRefreshing` and honours
the rate-limit backoff, so repeated popover opens cannot stampede the endpoint.

### Unchanged

`ProviderEntry` needs no new field — the `id` it already carries ("claude",
"codex", "gemini") is the key `AuthRecovery` switches on. No provider client,
decoder, or model type changes.

## Data flow

```
UsageClient.fetch() → 401
  → FetchError.authExpired
    → UsageStore.lastError / loadState
      → ProviderSection reads AuthRecovery.prompt(for:provider:)
        → renders message + button
          → click → TerminalLauncher.launch → Terminal runs `claude`
            → user completes OAuth; CLI rewrites the credential store
              → next popover open (or 60s tick) → refresh succeeds
```

## Error handling

Launch failures — cache directory unwritable, `NSWorkspace.open` returning
false — are swallowed. The button is a convenience; a failed launch leaves the
existing error message on screen. No new `FetchError` case, no alert, no state.

## Testing

XCTest, matching the existing suite's style (pure functions tested directly, no
view tests — the codebase has none).

- **`AuthRecoveryTests`**
  - Each `FetchError` case × each provider id → prompt present/absent.
  - Correct command per provider (`claude`, `codex login`, `gemini`).
  - Unknown provider id → `nil` for an auth error.
  - `staleMessage` unchanged for `.rateLimited` / `.network` / `.decode`;
    auth-specific for `.authExpired` / `.notLoggedIn`.
- **`TerminalLauncherTests`**
  - Generated script contents and `0755` mode, written to a temp directory via
    an injected base path.
- **`DashboardCoordinatorTests`**
  - `refreshAll()` refreshes every store (fake providers, no timers).

## Files

| File | Change |
|---|---|
| `Sources/Dashboard/AuthRecovery.swift` | new |
| `Sources/Dashboard/TerminalLauncher.swift` | new |
| `Sources/Dashboard/GaugesView.swift` | error view + stale hint + plumbing |
| `Sources/Dashboard/DashboardCoordinator.swift` | `refreshAll()` |
| `Sources/Dashboard/DashboardApp.swift` | `.task` refresh on popover open |
| `Tests/DashboardTests/AuthRecoveryTests.swift` | new |
| `Tests/DashboardTests/TerminalLauncherTests.swift` | new |
| `Tests/DashboardTests/DashboardCoordinatorTests.swift` | `refreshAll()` test |
| `dashboard/README.md` | document the affordance and its limits |
