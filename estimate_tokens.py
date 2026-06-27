#!/usr/bin/env python3
"""Estimate how many tokens of each model fit in the remaining usage windows.

The usage endpoint reports cost-weighted *utilization %*, not a token or dollar
budget. This script recovers the budget empirically:

  1. Measure cost actually spent in each window from local session logs.
  2. The API says that spend equals `utilization%` of the window's budget,
     so   budget = spent / (utilization/100).
  3. remaining_budget = budget - spent = spent * (100 - util) / util.
  4. Convert remaining budget into tokens for each model via list pricing.

Because the subscription discount scales the spent-cost numerator and the
per-token-price denominator identically, it cancels — token estimates are
discount-independent. Everything is computed in Anthropic API list-price terms.

Estimates are rough: when utilization is low the denominator is small, so the
back-out amplifies measurement noise. Treat the numbers as order-of-magnitude.
"""

from __future__ import annotations

import glob
import json
import os
from datetime import datetime, timedelta, timezone

import claude_usage  # reuse token reading / fetching

# List price per 1M tokens (input, output), from the claude-api reference.
PRICING = {
    "opus": (5.0, 25.0),
    "sonnet": (3.0, 15.0),
    "haiku": (1.0, 5.0),
    "fable": (10.0, 50.0),
}

# Cache multipliers relative to the input price.
CACHE_READ_MULT = 0.10
CACHE_WRITE_5M_MULT = 1.25
CACHE_WRITE_1H_MULT = 2.0

WINDOWS = {
    "five_hour": ("5-hour session", timedelta(hours=5)),
    "seven_day": ("7-day (all models)", timedelta(days=7)),
}


def model_family(model: str | None) -> str:
    m = (model or "").lower()
    for fam in ("fable", "opus", "sonnet", "haiku"):
        if fam in m:
            return fam
    return "opus"  # default for unknown / Claude Code sessions


def message_cost_usd(model: str, usage: dict) -> float:
    """API list-price cost of a single assistant message."""
    in_price, out_price = PRICING[model_family(model)]
    per = in_price / 1_000_000
    out_per = out_price / 1_000_000

    cache = usage.get("cache_creation") or {}
    write_5m = cache.get("ephemeral_5m_input_tokens", 0)
    write_1h = cache.get("ephemeral_1h_input_tokens", 0)
    if not (write_5m or write_1h):
        write_5m = usage.get("cache_creation_input_tokens", 0)

    return (
        usage.get("input_tokens", 0) * per
        + usage.get("cache_read_input_tokens", 0) * per * CACHE_READ_MULT
        + write_5m * per * CACHE_WRITE_5M_MULT
        + write_1h * per * CACHE_WRITE_1H_MULT
        + usage.get("output_tokens", 0) * out_per
    )


def iter_usage_records():
    """Yield (timestamp, model, usage_dict) for every assistant message logged."""
    home = os.path.expanduser("~/.claude/projects")
    for path in glob.glob(os.path.join(home, "*", "*.jsonl")):
        try:
            with open(path) as fh:
                for line in fh:
                    try:
                        d = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    msg = d.get("message")
                    ts = d.get("timestamp")
                    if not isinstance(msg, dict) or not msg.get("usage") or not ts:
                        continue
                    try:
                        when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    yield when, msg.get("model"), msg["usage"]
        except OSError:
            continue


def main() -> int:
    token = claude_usage.read_token()
    data = claude_usage.fetch_usage(token)
    now = datetime.now(timezone.utc)

    records = list(iter_usage_records())

    print("Token headroom estimate (API list-price equivalent)")
    print("=" * 64)

    for key, (label, length) in WINDOWS.items():
        block = data.get(key) or {}
        util = block.get("utilization")
        reset = claude_usage.parse_reset(block.get("resets_at"))
        if util is None or reset is None:
            continue

        start = reset - length
        spent = sum(
            message_cost_usd(model, usage)
            for when, model, usage in records
            if start <= when <= now
        )

        print(f"\n{label}  —  {util:.0f}% used, resets in "
              f"{claude_usage.humanize_delta(reset, now)}")

        if util <= 0:
            print("  window just reset / 0% used — nothing to extrapolate from")
            continue
        if spent <= 0:
            print("  no local usage found in this window — cannot estimate budget")
            continue

        budget = spent / (util / 100)
        remaining = budget - spent
        print(f"  measured spend: ${spent:.2f}  →  est. budget ${budget:.2f}, "
              f"${remaining:.2f} left ({100 - util:.0f}%)")
        print(f"  {'model':<8}{'as output tokens':>20}{'as input tokens':>20}")
        for fam, (in_price, out_price) in PRICING.items():
            out_tokens = remaining / (out_price / 1_000_000)
            in_tokens = remaining / (in_price / 1_000_000)
            print(f"  {fam:<8}{out_tokens:>20,.0f}{in_tokens:>20,.0f}")

    print("\nRe/output tokens are the scarce resource; real usage mixes in cheaper")
    print("(cached) input, so practical headroom sits between the two columns.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
