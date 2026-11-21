# QuotaBar Privacy Policy

_Last updated: 2026-11-22_

QuotaBar does not collect, store, sell, or share any personal data.

**What the app reads, on your Mac only**
- The login the Claude Code command-line tool saved in your macOS Keychain
  (item "Claude Code-credentials"), read with your permission.
- The login the Codex command-line tool saved in `~/.codex/auth.json`,
  read-only.

QuotaBar never writes, refreshes, copies, or deletes these credentials.

**Where data goes**
Each credential is sent only to its own provider's usage endpoint, over HTTPS:
the Claude Code login to Anthropic (`api.anthropic.com`), the Codex login to
OpenAI (`chatgpt.com`). The response — your usage percentages and reset
times — is shown in the menu bar and kept in memory only.

**What is stored**
Only your own settings (the alert threshold), in the app's local preferences.

**No tracking.** No analytics, no crash reporting, no advertising
identifiers, no servers operated by us.

**Third parties.** Anthropic and OpenAI process requests under their own
privacy policies.

**Contact:** https://github.com/pionion-ai/quotabar/issues
