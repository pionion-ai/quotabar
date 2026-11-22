# Claude Status-Line Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Checkbox steps.

**Goal:** Claude usage comes only from Claude Code's status line JSON via a bridge file; all Claude credential/endpoint code is removed.

**Architecture:** shell bridge (`Resources/quotabar-statusline`) writes `~/.quotabar/claude-status.json`; pure `ClaudeStatusDecoder` + `ClaudeStatusProvider` (UsageProviding) read it; setup goes through the existing re-login button machinery (`AuthRecovery` + launch closure).

**Spec:** `docs/superpowers/specs/2026-11-22-claude-statusline-bridge-design.md`

## Global Constraints
- Bridge uses only stock macOS tools (`/bin/sh`, `plutil`, `osascript`, `mkdir`, `mv`, `date`); never writes anything but `rate_limits` + `written_at`.
- File: `~/.quotabar/claude-status.json`; script installed to `~/.quotabar/quotabar-statusline`; previous status line saved in `~/.quotabar/previous-statusline.json`; settings backup `~/.claude/settings.json.quotabar-backup`.
- No Keychain, `security`, or `api.anthropic.com` access anywhere for Claude.
- Tests pass in both flavors (`arch -arm64 swift test [-Xswiftc -DAPPSTORE]`) plus `Tests/bridge/test-statusline.sh`.

## Review Focus
1. settings.json missing / malformed / already has our statusLine / has another statusLine → create / abort unchanged / idempotent / chain + restore.
2. Payload without `rate_limits` (API-key user, first message pending) → file untouched, status line still prints.
3. File with all windows past reset → "waiting for Claude Code", not stale gauges.
4. Corrupt or partially written status file → treated as not-yet-data, no crash.
5. Previous status line command fails → our capture still happened; its exit status passed through.

---

### Task 1: ClaudeStatusDecoder + ClaudeStatusProvider
**Files:** Create `Sources/Dashboard/ClaudeStatus.swift`; Test `Tests/DashboardTests/ClaudeStatusTests.swift`; Modify `Sources/Dashboard/UsageClient.swift` (add `FetchError.notConnected`).
**Produces:** `enum ClaudeStatusDecoder { static func windows(from: Data, now: Date) throws -> [UsageWindow] }` (keys `five_hour` "5-hour", `seven_day` "7-day"; drops windows with `resets_at <= now`; note = `ClaudeStatusDecoder.freshness(writtenAt:now:)` e.g. "updated 3 min ago · updates while Claude Code runs"); `struct ClaudeStatusProvider: UsageProviding { init(path: String, now: @escaping () -> Date); static func live() -> Self; static func statusPath(home:) -> String }` — missing file → `.notConnected`; undecodable → `.decode`.
- [ ] Tests: both windows decoded with exact percents/dates; past-reset window dropped; empty `rate_limits` → `[]`; garbage → throws; freshness strings ("just now" <60 s, "updated 3 min ago", "updated 2 h ago"); provider missing file → `.notConnected`.

### Task 2: Bridge script
**Files:** Create `Resources/quotabar-statusline`, `Tests/bridge/test-statusline.sh`.
- [ ] Shell tests with a temp `HOME`: normal run writes only rate_limits + written_at and prints `5h 11% · 7d 10%`; payload without rate_limits leaves file untouched; `--install` on missing settings creates it; on existing settings preserves other keys + order, writes backup, saves previous statusLine; second `--install` idempotent; previous status line is chained (its output printed, gets same stdin); `--uninstall` restores previous / removes ours; malformed settings → non-zero exit, file unchanged.

### Task 3: Wire in, remove credential code
**Files:** Modify `DashboardApp.swift`, `AuthRecovery.swift`, `GaugesView.swift`, `UsageStore.swift`, `package.sh`, `package-appstore.sh`, `build-app.sh`, `Package.swift`, entitlements; Delete `UsageDecoder.swift`, `UsageClientTests.swift`, `UsageDecoderTests.swift`, fixture `oauth-usage-real.json`.
- [ ] AuthRecovery: `.notConnected` for "claude" → message "Claude Code isn't connected yet.", button "Connect Claude Code…" (launch mode, runs install command in Terminal) / "Copy setup command" (copy mode); command = `"<bundle>/Contents/Resources/quotabar-statusline" --install`. Tests first.
- [ ] Remove `UsageClient` struct (keep `FetchError`/`UsageProviding`), `FetchError.accessDenied`, `UsageStore.retry`/pause, retry button; tests updated.
- [ ] GaugesView: quota note caption; Claude empty state "Waiting for Claude Code — usage appears after your next message."
- [ ] Scripts copy + chmod the bridge into Resources; App Store entitlement adds `/.quotabar/claude-status.json`.

### Task 4: Welcome v3 + docs
- [ ] Welcome copy tests first (no "Keychain"/"password"; mentions status line and `~/.quotabar`), bump version 3.
- [ ] README, AppStore/*.md, spec status. Manual: ADHOC build, run installer in temp HOME, launch app.
