---
name: claude-usage
description: >-
  Check how much of the Claude Code subscription is left, when limits reset,
  estimated per-model token headroom, and Anthropic API spend — via the local
  claude-usage tool (claude_usage.py). Use this skill whenever the
  user asks "how much usage / quota / credits do I have left", "am I close to my
  limit", "when does my limit reset", "how many tokens can I still use", "what's
  my Claude Code usage", "how much have I spent on the API", or wants this
  reported on a schedule / as a cron job. Trigger even when phrased loosely
  ("am I about to run out?", "check my limits") — prefer running this tool over
  guessing, since the numbers are live.
---

# claude-usage

A small, dependency-free Python tool that reports Claude Code **subscription
usage limits**, **reset times**, **per-model token headroom**, and **Anthropic
API spend**. Prefer running it over answering from memory — the figures are live
and change constantly.

## Where it lives

`claude_usage.py` at the repo root. It's executable and needs only Python 3.9+
(standard library). Run it with an absolute path if the working directory is
elsewhere.

## How to run it

Pick the flag that matches what the user asked. Default (no flags) answers the
common "how much is left / when does it reset" question.

| User wants… | Command |
|---|---|
| Current usage % + reset times | `./claude_usage.py` |
| Machine-readable output (for scripts/cron) | `./claude_usage.py --json` |
| The complete raw API payload | `./claude_usage.py --raw` |
| Per-model token headroom estimate | `./claude_usage.py --estimate` |
| Anthropic API spend (needs Admin key) | `./claude_usage.py --api-credits` |
| Everything together | `./claude_usage.py --estimate --api-credits` |
| Alert when a window crosses a threshold | `./claude_usage.py --threshold 85` |

`--days N` sets the API-spend window for `--api-credits` (default 30).
`--threshold N` makes the tool exit `1` when any window is ≥ N% used — use it
for cron/launchd alerting. Exit codes: `0` ok, `1` threshold breached, `2` error.

## What each number means

Read these distinctions back to the user — they're easy to conflate:

- **Subscription windows** (`five_hour`, `seven_day`, per-model weekly) report
  **% used / % left** and an ISO reset time. The 5-hour window is usually the
  binding one. This is the answer to "how much usage do I have left."
- **Extra-usage credits** = pay-as-you-go overflow *on the subscription*. If
  `extra_usage` is absent/disabled, the user has none — once subscription
  limits are hit, work stops. They enable or buy these with `/usage-credits`
  inside Claude Code (formerly `/extra-usage`).
- **API console credits** (`console.anthropic.com` prepaid balance) are a
  **separate billing account**. `--api-credits` shows *consumed* API spend via
  the Admin API — it is **not** a remaining-balance figure. No public endpoint
  exposes the remaining prepaid balance; that's only in console Billing.

## The token estimate is approximate — say so

`--estimate` recovers each window's budget from local session logs: it measures
what was actually spent in the window, treats that as `utilization%` of the
budget, backs out the total, and converts the remainder to tokens per model at
API list prices (the subscription discount cancels, so the result is
discount-independent). When utilization is low the back-out amplifies noise, so
present these as order-of-magnitude, and note output tokens are the scarce side
(cached input is far cheaper, so real headroom is higher).

The model list is read **live** from `/v1/models`; prices come from
`pricing.json` (edit that file when prices change — don't hardcode
model names in code). The output's `models_source` says `live_api` or
`pricing_config` (the fallback when the API is unreachable).

## Credentials

- **Subscription data** uses the local Claude Code OAuth token (macOS Keychain
  or `~/.claude/.credentials.json`) — no setup. A 401 means the token expired;
  tell the user to run `claude` once to refresh.
- **`--api-credits`** needs an Anthropic **Admin key** (`sk-ant-admin…`), read
  from `ANTHROPIC_ADMIN_KEY` or the gitignored `.secrets` file.
  Never print the key, never commit it, and never paste it into chat output.

## Scheduling

For a recurring check, wire the `--threshold` form into cron or launchd and act
on the exit code / `--json` output. Example cron line:

```cron
*/30 * * * * /path/to/quotabar/claude_usage.py --threshold 85 >> ~/claude-usage.log 2>&1
```

See `README.md` for full details.
