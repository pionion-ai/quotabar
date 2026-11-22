# QuotaBar Privacy Policy

_Last updated: 2026-11-22_

QuotaBar does not collect, store, sell, or share any personal data.

**What the app reads, on your Mac only**
- Claude Code: QuotaBar does **not** read your Claude login. After you
  connect it, Claude Code's own status line saves your usage percentages and
  reset times to `~/.quotabar/claude-status.json`, which QuotaBar reads.
- The login the Codex command-line tool saved in `~/.codex/auth.json`,
  read-only.

QuotaBar never writes, refreshes, copies, or deletes these credentials.

**Where data goes**
QuotaBar makes no network requests for Claude. The Codex login is sent only
to OpenAI's usage endpoint (`chatgpt.com`), over HTTPS. Usage percentages and
reset times are shown in the menu bar and kept in memory only.

**What is stored**
Only your own settings (the alert threshold), in the app's local preferences.
The status line you install into Claude Code writes your Claude usage
percentages and reset times — nothing else — to `~/.quotabar/claude-status.json`
on your Mac.

**No tracking.** No analytics, no crash reporting, no advertising
identifiers, no servers operated by us.

**Third parties.** OpenAI processes Codex usage requests under its own
privacy policy. QuotaBar sends nothing to Anthropic.

**Contact:** TODO — support page or address on our own site
