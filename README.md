# QuotaBar

See how much of your **AI coding subscriptions** you've used — and when each
rate-limit window resets — for Claude Code, OpenAI Codex, and Gemini CLI.

The repo contains:

- **[`dashboard/`](dashboard/) — QuotaBar.app**, a native macOS menu bar app
  showing live circular gauges per usage window, with Codex (ChatGPT plan)
  and Gemini sections appearing automatically when those CLIs are logged in.
  See its README for install and build instructions.
- **`claude_usage.py`** — a tiny, dependency-free CLI that reports Claude
  Code usage as a human-readable summary or JSON (documented below) — ideal
  for a quick check or a scheduled task / cron alert. It reads your local
  Claude Code OAuth token and queries Anthropic's usage endpoint (the same
  data behind the `/usage` command).
- **`codex_usage.py`** — the same CLI idea for OpenAI Codex: reads
  `~/.codex/auth.json` and reports the 5-hour and weekly windows.

## Disclaimer — unofficial tool, private endpoints

This project is **not affiliated with or endorsed by Anthropic, OpenAI, or
Google**. It queries the same private, undocumented endpoints the official
CLIs use (`/api/oauth/usage`, ChatGPT's `/wham/usage`, Gemini's quota RPC),
authenticated with the tokens those CLIs already store on your machine. To be
served from the correct rate-limit bucket, requests identify themselves with
the same `User-Agent` the official CLIs send.

Consequences to be aware of:

- Any of these endpoints can change shape, move, or disappear **without
  notice**, breaking the tool until it's updated.
- Reported percentages and reset times come straight from the providers;
  this tool adds no interpretation beyond formatting.
- Use at your own risk and within each provider's terms of service.

## Security: what this tool does with your tokens

- It **reads** credentials from where the official CLIs store them (macOS
  Keychain / `~/.claude/.credentials.json` / `~/.codex/auth.json`). It never
  writes, refreshes, or deletes them.
- Each token is sent **only to its own provider's API** (Anthropic token →
  `api.anthropic.com`, and so on). No telemetry, no third-party servers, no
  analytics.
- Everything is plain, dependency-free source in this repo — a few small
  Python files and Swift files you can audit yourself.

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
./claude_usage.py --estimate           # per-model token headroom per window
./claude_usage.py --api-credits        # also show API spend (needs Admin key)
./claude_usage.py --api-credits --days 7   # API spend over the last 7 days
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

## Token headroom estimate (`--estimate`)

`--estimate` answers "how many more tokens can I use this window, per model."
The usage endpoint only gives a cost-weighted *utilization %*, so the budget is
recovered empirically:

1. Measure cost actually spent in each window from local session logs.
2. That spend is `utilization%` of the budget, so `budget = spent / (util/100)`.
3. `remaining = budget - spent`, converted to tokens at each model's price.

Because the subscription discount scales both the measured spend and the
per-token price, it cancels — estimates are discount-independent (API
list-price terms). They are **rough**: at low utilization the back-out
amplifies measurement noise.

- **Model list is read live** from the `/v1/models` API (newest model per price
  tier), falling back to the families in `pricing.json` if the API is
  unreachable. `models_source` in the output says which was used.
- **Prices live in `pricing.json`** (editable data, not hardcoded in the
  script) — keyed by a case-insensitive substring of the model id. The API
  exposes no pricing field, so prices must be configured here; update this file
  when prices change.

## API spend (`--api-credits`)

`--api-credits` additionally reports your **Anthropic API** consumption (the
separate `console.anthropic.com` billing account, distinct from the Claude
Code subscription). It queries the Admin `cost_report` endpoint and sums spend
over the last `--days` (default 30), broken down by model.

This needs an **Admin API key** (`sk-ant-admin…`), which the subscription
OAuth token cannot provide. Supply it either way:

- environment variable: `export ANTHROPIC_ADMIN_KEY=sk-ant-admin...`
- or a local `.secrets` file next to the script (gitignored):
  `ANTHROPIC_ADMIN_KEY=sk-ant-admin...`

> Note: this reports **consumed spend**, not a remaining prepaid-credit
> balance — Anthropic exposes no public endpoint for the credit balance
> itself; that figure lives only in the console Billing page.

## Scheduling

Run it as a cron job and alert when you're close to a limit. The
`--threshold` flag makes the command exit non-zero so any scheduler can act
on it:

```cron
# Every 30 minutes, log a warning line if any window is >= 85% used
*/30 * * * * /path/to/quotabar/claude_usage.py --threshold 85 >> ~/claude-usage.log 2>&1
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

## License

MIT — see [LICENSE](LICENSE).
