# App Review notes (paste into "Notes" in App Store Connect)

QuotaBar is a menu-bar utility (LSUIElement — no Dock icon, no windows) for
developers who use the Claude Code and/or Codex command-line tools. It shows
how much of their subscription usage limits they have consumed.

HOW TO TEST
1. Install a CLI and log in with a Claude Pro/Max or ChatGPT Plus/Pro account:
     npm install -g @anthropic-ai/claude-code && claude     (log in)
     npm install -g @openai/codex && codex login
2. Launch QuotaBar. Click the "◔ N%" item in the menu bar to see the gauges.
3. Claude Code: macOS asks whether QuotaBar may read "Claude Code-credentials"
   from the Keychain. Choose "Always Allow".
A demo video is attached / available at: <link>
Without a logged-in CLI the popover shows "Not signed in." and a
"Copy login command" button — that is the expected empty state.

WHY THE ENTITLEMENTS ARE NEEDED
- Keychain: the Claude Code CLI stores its login in the user's login
  Keychain. QuotaBar reads that item (with the standard macOS consent
  prompt) — read-only, never modified.
- com.apple.security.temporary-exception.files.home-relative-path.read-only
  (/.codex/): the Codex CLI keeps its login in ~/.codex/auth.json. QuotaBar
  reads only that file, read-only, so users need no manual setup. It never
  writes anywhere outside its container.
- network.client: to request usage from api.anthropic.com and chatgpt.com.

PRIVACY
Credentials never leave the Mac except to their own provider. No analytics,
no third-party servers. The app does not run other executables or download
code; the "Copy login command" button only places text on the pasteboard.

QuotaBar is not affiliated with Anthropic or OpenAI; the listing says so.
