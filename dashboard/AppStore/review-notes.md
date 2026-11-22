# App Review notes (paste into "Notes" in App Store Connect)

QuotaBar is a menu-bar utility (LSUIElement — no Dock icon, no windows) for
developers who use Claude Code and/or the Codex command-line tool. It shows
how much of their subscription usage limits they have consumed.

HOW TO TEST
1. Install the tools and log in with a Claude Pro/Max or ChatGPT Plus/Pro
   account:
     npm install -g @anthropic-ai/claude-code && claude     (log in)
     npm install -g @openai/codex && codex login
2. Launch QuotaBar. A welcome window explains what the app reads and how
   it is used; nothing is read until you click Continue.
3. Claude Code: in the popover's Claude section click "Copy setup command",
   paste it into Terminal and run it. Then send any message in Claude Code;
   the Claude gauges appear within a minute.
4. Click the "◔ N%" item in the menu bar to see the gauges.
A demo video is attached / available at: <link>
Without setup the Claude section shows "Claude Code isn't connected yet." and
"Copy setup command"; without a Codex login the Codex section is hidden.
Both are expected empty states.

HOW CLAUDE DATA IS OBTAINED (no credentials)
QuotaBar never reads Claude credentials and makes no Claude network requests.
Claude Code supports a user-configured "status line" command and passes it a
documented JSON payload that includes `rate_limits` (5-hour and weekly usage
percentages). The setup command (run by the user in Terminal, outside the
app) installs a small shell script bundled in the app's Resources as that
status line; it writes only `rate_limits` and a timestamp to
~/.quotabar/claude-status.json. The app itself never runs any executable.

WHY THE ENTITLEMENTS ARE NEEDED
- com.apple.security.temporary-exception.files.home-relative-path.read-only,
  two single files (not folders), read-only:
  - /.quotabar/claude-status.json — the Claude usage numbers described above.
  - /.codex/auth.json — the Codex CLI keeps its login there; QuotaBar reads
    that one file so Codex users need no manual setup. Other files in
    ~/.codex stay inaccessible.
  The app never writes anywhere outside its container.
- network.client: to request Codex usage from chatgpt.com.

PRIVACY
The Codex login never leaves the Mac except to OpenAI. No analytics, no
third-party servers. The app does not run other executables or download
code; the "Copy setup command" / "Copy login command" buttons only place
text on the pasteboard.

QuotaBar is not affiliated with Anthropic or OpenAI; the listing says so.
