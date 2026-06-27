# claude-usage

A tiny, dependency-free tool that reports how much of your **Claude Code
subscription** rate limits you've used and when each window resets.

It reads your local Claude Code OAuth token and queries Anthropic's usage
endpoint (the same data behind the `/usage` command), then prints it as a
human-readable summary or structured JSON — ideal for a quick check or a
scheduled task / cron alert.

## Requirements

- Python 3.9+ (standard library only — no `pip install` needed)
- A logged-in Claude Code session (Pro/Max subscription)
- macOS (token read from Keychain) or Linux (`~/.claude/.credentials.json`)

## Usage

```bash
./claude_usage.py              # human-readable summary
./claude_usage.py --json       # structured JSON for scripts/schedulers
./claude_usage.py --raw        # complete, unmodified API response
./claude_usage.py --threshold 90   # exit code 1 if any window is >= 90% used
```

### Example

```
Claude Code usage  —  checked 2026-06-27T12:00:50+00:00
----------------------------------------------------------
5-hour session         ██░░░░░░░░░░░░░░░░░░  12.0% used  (88.0% left, resets in 2h 49m)
7-day (all models)     █░░░░░░░░░░░░░░░░░░░   4.0% used  (96.0% left, resets in 3d 13h 59m)
7-day (Sonnet)         ░░░░░░░░░░░░░░░░░░░░   1.0% used  (99.0% left, resets in 3d 13h 59m)
```

### JSON shape

```json
{
  "checked_at": "2026-06-27T12:00:50+00:00",
  "windows": [
    {
      "key": "five_hour",
      "label": "5-hour session",
      "used_percent": 12.0,
      "remaining_percent": 88.0,
      "resets_at": "2026-06-27T14:50:00+00:00",
      "resets_in": "2h 49m"
    }
  ],
  "extra_usage": null
}
```

`extra_usage` is populated only if your account has pay-as-you-go extra
usage credits enabled.

## Scheduling

Run it as a cron job and alert when you're close to a limit. The
`--threshold` flag makes the command exit non-zero so any scheduler can act
on it:

```cron
# Every 30 minutes, log a warning line if any window is >= 85% used
*/30 * * * * /path/to/claude-usage/claude_usage.py --threshold 85 >> ~/claude-usage.log 2>&1
```

macOS `launchd` and any CI scheduler work the same way — call the script,
read its stdout (`--json` for parsing) and its exit code.

## How it works

1. Reads the OAuth access token from the macOS Keychain
   (`security find-generic-password -s "Claude Code-credentials"`) or from
   `~/.claude/.credentials.json` on Linux.
2. `GET https://api.anthropic.com/api/oauth/usage` with that bearer token.
3. Normalizes the response into per-window `used` / `remaining` percentages
   and reset times.

The token never leaves your machine except in the request to Anthropic's own
API. The tool only reads — it never writes credentials or makes changes.

## Exit codes

| Code | Meaning                                             |
|------|-----------------------------------------------------|
| 0    | OK                                                  |
| 1    | A window is at/over `--threshold` (only with flag)  |
| 2    | Error (not logged in, token expired, network, etc.) |

## Limitations

- Reset timestamps and percentages come straight from Anthropic; if they
  change the endpoint shape, the tool degrades gracefully (skips unknown
  windows) but may need an update.
- Token refresh is not handled — if you get a 401, run `claude` once
  interactively to refresh, then retry.
