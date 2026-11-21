# App Review notes (paste into "Notes" in App Store Connect)

QuotaBar is a menu-bar utility (LSUIElement — no Dock icon, no windows) for
developers who use the Claude Code and/or Codex command-line tools. It shows
how much of their subscription usage limits they have consumed.

HOW TO TEST
1. Install a CLI and log in with a Claude Pro/Max or ChatGPT Plus/Pro account:
     npm install -g @anthropic-ai/claude-code && claude     (log in)
     npm install -g @openai/codex && codex login
2. Launch QuotaBar. A welcome window explains what the app reads and how
   it is used; nothing is read until you click Continue.
3. Click the "◔ N%" item in the menu bar to see the gauges.
A demo video is attached / available at: <link>
Without a logged-in CLI the popover shows "Not signed in." and a
"Copy login command" button — that is the expected empty state.

WHY THE ENTITLEMENTS ARE NEEDED
- Keychain: the Claude Code CLI stores its login in the user's login
  Keychain, writing it with Apple's /usr/bin/security tool. QuotaBar reads
  that item read-only by running the same system tool
  (`security find-generic-password -s "Claude Code-credentials" -w`), only
  after the user has read the welcome screen and pressed Continue. If that
  fails, it falls back to SecItemCopyMatching, which shows the standard
  macOS consent prompt. The item is never modified. No other executable is
  run and no code is downloaded.
- com.apple.security.temporary-exception.files.home-relative-path.read-only
  (/.codex/auth.json — a single file, not the folder): the Codex CLI keeps
  its login there. QuotaBar reads that one file, read-only, so users need no
  manual setup; other files in ~/.codex stay inaccessible. It never writes
  anywhere outside its container.
- network.client: to request usage from api.anthropic.com and chatgpt.com.

PRIVACY
Credentials never leave the Mac except to their own provider. No analytics,
no third-party servers. Apart from Apple's /usr/bin/security (above), the
app does not run other executables or download code; the "Copy login command" button only places text on the pasteboard.

QuotaBar is not affiliated with Anthropic or OpenAI; the listing says so.
