# QuotaBar — Claude usage via the Claude Code status line (design)

Status: approved and implemented 2026-11-22.

## Intent
Stop reading Claude subscription credentials. Anthropic's Claude Code legal
page: "developers may not collect, store, or intermediate Claude.ai
credentials or session tokens" (verified 2026-11-22). The documented,
sanctioned source is the status line JSON Claude Code passes to a
user-configured script: `rate_limits.five_hour` / `rate_limits.seven_day`
(`used_percentage` 0–100, `resets_at` Unix seconds), Pro/Max only, present
after the first API response of a session.

## Goals
- Both flavors (DMG and App Store) get Claude usage only from the status line.
- No Keychain access, no `security` process, no Claude endpoint calls, no token.
- One-step setup; a user's existing status line keeps working.
- Clear freshness: "updated N min ago · updates while Claude Code runs".

## Non-goals
- Per-model weekly gauges (Fable): not in the documented payload — dropped.
- Live data while Claude Code is closed (impossible by design).
- Claude desktop-app-only users (no documented feed).
- Codex/Gemini/Cursor sources (separate review), the Python CLI `claude_usage.py`.

## Design
**Bridge script** `quotabar-statusline` (POSIX sh, stock macOS tools only),
shipped in `Contents/Resources`; `--install` copies it to
`~/.quotabar/quotabar-statusline` so it survives app moves/deletion.
- Normal run (stdin = Claude Code's JSON): extract `rate_limits` with
  `plutil -extract rate_limits json`; if present, atomically write
  `~/.quotabar/claude-status.json` = `{"rate_limits": …, "written_at": <epoch>}`
  — nothing else from the payload (no cwd, transcript, model, cost).
  Then: if `~/.quotabar/previous-statusline.json` holds a prior command, run it
  with the original stdin and pass its output through; else print a compact
  `5h 11% · 7d 10%`.
- `--install`: back up `~/.claude/settings.json` (`.quotabar-backup`), save any
  existing `statusLine` to `previous-statusline.json`, set
  `statusLine = {type: command, command: ~/.quotabar/quotabar-statusline}`
  via `osascript -l JavaScript` (keeps key order and indentation).
  Idempotent. `--uninstall` restores the previous `statusLine` (or removes it).

**App**
- `ClaudeStatusProvider: UsageProviding` reads the file each refresh (60 s
  timer + popover open). Windows: `five_hour` "5-hour", `seven_day` "7-day";
  a window whose `resets_at` has passed is dropped (as Claude Code does).
  File missing → `.notConnected`; no live windows → `.waitingForClaudeCode`.
- Freshness: `written_at` shown as "updated N min ago".
- Setup UI in the Claude section when not connected:
  DMG — **Connect Claude Code…** runs the bundled `--install` (after a
  confirmation sheet saying exactly what changes); App Store — sandbox can't
  write `~/.claude`, so **Copy setup command** puts the `--install` command on
  the pasteboard ("paste it in Terminal").
- App Store entitlement: read-only home-relative exception
  `/.quotabar/claude-status.json` (atomic rewrites verified to work).
- Removed: Claude Keychain readers (`security`, SecItemCopyMatching), the
  `/api/oauth/usage` client and decoder (+ fixture/tests), `FetchError.accessDenied`
  pause/retry machinery, the spoofed `claude-code/` User-Agent for Claude.
- Welcome copy v3: no password/Keychain; explains the status-line connection.
- Docs: README, App Store description/privacy/review notes updated.

## Risks
- Status line runs after each assistant message: numbers lag between sessions.
- Undocumented edge: several concurrent sessions write the same file (same
  account → same numbers; last write wins).
- `osascript` JSON editing of a malformed settings.json: installer aborts
  without changes and says so.
