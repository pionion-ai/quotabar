#!/usr/bin/env python3
"""claude-usage — report Claude Code subscription usage limits and reset times.

Reads the local Claude Code OAuth token and queries Anthropic's usage endpoint,
then prints how much of each rate-limit window is consumed and when it resets.

No third-party dependencies — standard library only.

Usage:
    ./claude_usage.py            # human-readable summary
    ./claude_usage.py --json     # machine-readable JSON (for scheduled tasks)
    ./claude_usage.py --raw      # the complete, unmodified API response
    ./claude_usage.py --threshold 90   # exit 1 if any active window is >= 90% used
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

USAGE_ENDPOINT = "https://api.anthropic.com/api/oauth/usage"
MODELS_ENDPOINT = "https://api.anthropic.com/v1/models"
COST_REPORT_ENDPOINT = "https://api.anthropic.com/v1/organizations/cost_report"
# The /oauth/usage (and /v1/models via OAuth) endpoint gates the generous
# rate-limit bucket on a `claude-code/<version>` User-Agent. Without it,
# requests land in an aggressively throttled bucket and get persistent 429s.
CLAUDE_CODE_USER_AGENT = "claude-code/2.1.195"
KEYCHAIN_SERVICE = "Claude Code-credentials"
CREDENTIALS_FILE = Path.home() / ".claude" / ".credentials.json"
SECRETS_FILE = Path(__file__).resolve().parent / ".secrets"
ADMIN_KEY_VAR = "ANTHROPIC_ADMIN_KEY"

# Friendly labels for the windows we care about, in display order.
WINDOWS = [
    ("five_hour", "5-hour session"),
    ("seven_day", "7-day (all models)"),
    ("seven_day_opus", "7-day (Opus)"),
    ("seven_day_sonnet", "7-day (Sonnet)"),
]

# Local session logs, and the two windows we can estimate token headroom for.
SESSIONS_GLOB = str(Path.home() / ".claude" / "projects" / "*" / "*.jsonl")
ESTIMATE_WINDOWS = [
    ("five_hour", "5-hour session", timedelta(hours=5)),
    ("seven_day", "7-day (all models)", timedelta(days=7)),
]

# Model list and per-1M-token prices live in pricing.json (data, not code), so
# adding or repricing a model needs no source edit. Cache multipliers are fixed
# ratios defined by the API and apply to every model.
PRICING_FILE = Path(__file__).resolve().parent / "pricing.json"
CACHE_READ_MULT = 0.10
CACHE_WRITE_5M_MULT = 1.25
CACHE_WRITE_1H_MULT = 2.0


class UsageError(Exception):
    """A user-facing error with a clear message."""


def read_token() -> str:
    """Return the Claude Code OAuth access token.

    Tries the macOS keychain first, then ~/.claude/.credentials.json (Linux).
    """
    raw = None

    # macOS keychain
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        raw = None

    # Linux / fallback file
    if not raw and CREDENTIALS_FILE.exists():
        raw = CREDENTIALS_FILE.read_text()

    if not raw:
        raise UsageError(
            "Could not find Claude Code credentials.\n"
            "Make sure you are logged in (run `claude` once interactively)."
        )

    try:
        token = json.loads(raw).get("claudeAiOauth", {}).get("accessToken")
    except json.JSONDecodeError as exc:
        raise UsageError(f"Credentials are not valid JSON: {exc}") from exc

    if not token:
        raise UsageError("No OAuth access token in credentials (are you on an API-key login?).")

    return token


def fetch_usage(token: str) -> dict:
    """Query the usage endpoint and return the parsed JSON body."""
    req = urllib.request.Request(
        USAGE_ENDPOINT,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": CLAUDE_CODE_USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise UsageError(
                "Authentication failed (401). Your token may have expired — "
                "run `claude` once to refresh it."
            ) from exc
        raise UsageError(f"Usage endpoint returned HTTP {exc.code}.") from exc
    except urllib.error.URLError as exc:
        raise UsageError(f"Could not reach the usage endpoint: {exc.reason}") from exc


def fetch_models(token: str) -> list[dict]:
    """Return the live list of available models (id, display_name) from the API.

    Returns [] on any failure so callers can fall back to the pricing config.
    """
    req = urllib.request.Request(
        f"{MODELS_ENDPOINT}?limit=100",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": CLAUDE_CODE_USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode()).get("data", [])
    except (urllib.error.URLError, json.JSONDecodeError):
        return []


def read_admin_key() -> str:
    """Return the Anthropic Admin API key (sk-ant-admin...).

    Prefers the ANTHROPIC_ADMIN_KEY environment variable, then falls back to
    the local .secrets file next to this script.
    """
    key = os.environ.get(ADMIN_KEY_VAR)
    if key:
        return key.strip()

    if SECRETS_FILE.exists():
        for line in SECRETS_FILE.read_text().splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            name, _, value = line.partition("=")
            if name.strip() == ADMIN_KEY_VAR:
                return value.strip()

    raise UsageError(
        f"No admin key found. Set {ADMIN_KEY_VAR} or add it to {SECRETS_FILE.name}.\n"
        "An Admin API key (sk-ant-admin...) is required for --api-credits."
    )


def fetch_cost_report(key: str, start: datetime) -> list[dict]:
    """Return daily cost buckets from the Admin cost_report endpoint.

    Follows pagination until all buckets in the window are collected.
    """
    buckets: list[dict] = []
    page: str | None = None
    starting_at = start.strftime("%Y-%m-%dT00:00:00Z")

    while True:
        params = {
            "starting_at": starting_at,
            "group_by[]": "description",
            "limit": "31",
        }
        if page:
            params["page"] = page
        url = f"{COST_REPORT_ENDPOINT}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(
            url,
            headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise UsageError(
                    f"Admin API rejected the key (HTTP {exc.code}). "
                    "Check that it is a valid Admin key (sk-ant-admin...)."
                ) from exc
            raise UsageError(f"cost_report returned HTTP {exc.code}.") from exc
        except urllib.error.URLError as exc:
            raise UsageError(f"Could not reach the cost_report endpoint: {exc.reason}") from exc

        buckets.extend(body.get("data", []))
        if body.get("has_more") and body.get("next_page"):
            page = body["next_page"]
        else:
            break

    return buckets


def build_cost_report(buckets: list[dict], start: datetime, now: datetime) -> dict:
    """Aggregate cost buckets into a total plus per-model breakdown."""
    total = 0.0
    by_model: dict[str, float] = {}
    for bucket in buckets:
        for row in bucket.get("results", []):
            amount = float(row.get("amount", 0))
            total += amount
            model = row.get("model") or "other"
            by_model[model] = by_model.get(model, 0.0) + amount

    return {
        "period_start": start.isoformat(),
        "period_end": now.isoformat(),
        "currency": "USD",
        "total_spend": round(total, 2),
        "by_model": {m: round(v, 2) for m, v in sorted(by_model.items(), key=lambda x: -x[1])},
    }


def print_cost_report(report: dict, days: int) -> None:
    print(f"\nAPI spend (Admin API)  —  last {days} days")
    print("-" * 58)
    print(f"Total: ${report['total_spend']:.2f} {report['currency']}")
    if report["by_model"]:
        for model, amount in report["by_model"].items():
            print(f"  {model:<28} ${amount:>10.2f}")
    print("note: this is consumed API spend, not a remaining credit balance —")
    print("      prepaid credit balance is only visible in console Billing.")


def load_pricing() -> dict:
    """Load {family: (input_price, output_price)} from pricing.json."""
    try:
        raw = json.loads(PRICING_FILE.read_text())["prices"]
    except (OSError, KeyError, json.JSONDecodeError) as exc:
        raise UsageError(f"Could not read pricing from {PRICING_FILE.name}: {exc}") from exc
    return {fam: (p["input"], p["output"]) for fam, p in raw.items()}


def model_family(model: str | None, pricing: dict) -> str:
    """Match a model id to a configured family by substring.

    Unmatched models fall back to the most expensive family (conservative).
    """
    m = (model or "").lower()
    for fam in pricing:
        if fam.lower() in m:
            return fam
    return max(pricing, key=lambda f: pricing[f][1])


def message_cost_usd(model: str, usage: dict, pricing: dict) -> float:
    """API list-price cost of a single assistant message."""
    in_price, out_price = pricing[model_family(model, pricing)]
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
    for path in glob.glob(SESSIONS_GLOB):
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


def model_tiers(models: list[dict], pricing: dict) -> list[tuple[str, float, float]]:
    """Pick one representative live model per price tier.

    Returns [(model_id, input_price, output_price)] ordered most→least
    expensive. Uses the live model list (newest id per family wins) when
    available, else falls back to the family names from pricing.json.
    """
    tiers: dict[str, str] = {}
    for m in models:  # API returns newest first, so first id per family wins
        fam = model_family(m.get("id"), pricing)
        tiers.setdefault(fam, m.get("id"))

    if not tiers:  # API unavailable — fall back to config families
        tiers = {fam: fam for fam in pricing}

    rows = [(label, *pricing[fam]) for fam, label in tiers.items()]
    return sorted(rows, key=lambda r: r[2], reverse=True)


def build_estimate(data: dict, now: datetime, token: str) -> dict:
    """Estimate per-model token headroom for each window.

    Recovers each window's budget from measured local spend vs. the reported
    utilization %, then converts the remaining budget into tokens per model.
    The subscription discount cancels (it scales spend and price alike), so
    everything is in API list-price terms. Rough — noisy at low utilization.
    The model list is read live from the API; prices come from pricing.json.
    """
    pricing = load_pricing()
    models = fetch_models(token)
    tiers = model_tiers(models, pricing)
    records = list(iter_usage_records())

    windows = []
    for key, label, length in ESTIMATE_WINDOWS:
        block = data.get(key) or {}
        util = block.get("utilization")
        reset = parse_reset(block.get("resets_at"))
        if util is None or reset is None:
            continue

        start = reset - length
        spent = sum(
            message_cost_usd(model, usage, pricing)
            for when, model, usage in records
            if start <= when <= now
        )

        entry = {
            "label": label,
            "used_percent": round(float(util), 1),
            "resets_in": humanize_delta(reset, now),
            "measured_spend": round(spent, 2),
        }
        if util > 0 and spent > 0:
            budget = spent / (util / 100)
            remaining = budget - spent
            entry["est_budget"] = round(budget, 2)
            entry["est_remaining"] = round(remaining, 2)
            entry["tokens"] = {
                model_id: {
                    "as_output": round(remaining / (out_price / 1_000_000)),
                    "as_input": round(remaining / (in_price / 1_000_000)),
                }
                for model_id, in_price, out_price in tiers
            }
        else:
            entry["note"] = (
                "window just reset" if util <= 0 else "no local usage in window"
            )
        windows.append(entry)

    return {
        "basis": "api_list_price_equivalent",
        "models_source": "live_api" if models else "pricing_config",
        "windows": windows,
    }


def print_estimate(estimate: dict) -> None:
    print("\nToken headroom estimate (API list-price equivalent)")
    print(f"models: {estimate['models_source']}")
    print("-" * 58)
    for w in estimate["windows"]:
        print(f"\n{w['label']}  —  {w['used_percent']:.0f}% used, "
              f"resets in {w['resets_in']}")
        if "tokens" not in w:
            print(f"  {w.get('note', 'cannot estimate')}")
            continue
        print(f"  measured spend ${w['measured_spend']:.2f}  →  "
              f"est. budget ${w['est_budget']:.2f}, ${w['est_remaining']:.2f} left")
        print(f"  {'model':<28}{'as output tokens':>16}{'as input tokens':>16}")
        for model_id, toks in w["tokens"].items():
            print(f"  {model_id:<28}{toks['as_output']:>16,}{toks['as_input']:>16,}")
    print("\noutput tokens are the scarce side; real usage mixes in cheaper cached")
    print("input, so practical headroom sits between the two columns.")


def parse_reset(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def humanize_delta(target: datetime, now: datetime) -> str:
    """Return e.g. '2h 14m' until target, or 'now' if it has passed."""
    seconds = int((target - now).total_seconds())
    if seconds <= 0:
        return "now"
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if minutes or not parts:
        parts.append(f"{minutes}m")
    return " ".join(parts)


def build_report(data: dict, now: datetime) -> dict:
    """Normalize the raw API response into a compact, structured report."""
    windows = []
    for key, label in WINDOWS:
        block = data.get(key)
        if not block:
            continue
        utilization = block.get("utilization")
        if utilization is None:
            continue
        reset_dt = parse_reset(block.get("resets_at"))
        windows.append(
            {
                "key": key,
                "label": label,
                "used_percent": round(float(utilization), 1),
                "remaining_percent": round(100 - float(utilization), 1),
                "resets_at": block.get("resets_at"),
                "resets_in": humanize_delta(reset_dt, now) if reset_dt else None,
            }
        )

    # Extra (paid) usage credits, if the account has them enabled.
    extra = data.get("extra_usage") or {}
    extra_report = None
    if extra.get("is_enabled"):
        extra_report = {
            "used_credits": extra.get("used_credits"),
            "monthly_limit": extra.get("monthly_limit"),
            "utilization": extra.get("utilization"),
            "currency": extra.get("currency"),
        }

    return {
        "checked_at": now.isoformat(),
        "windows": windows,
        "extra_usage": extra_report,
    }


def print_human(report: dict) -> None:
    print(f"Claude Code usage  —  checked {report['checked_at']}")
    print("-" * 58)
    if not report["windows"]:
        print("No usage windows reported.")
    for w in report["windows"]:
        bar_len = 20
        filled = int(round(w["used_percent"] / 100 * bar_len))
        bar = "█" * filled + "░" * (bar_len - filled)
        resets = f"resets in {w['resets_in']}" if w["resets_in"] else "n/a"
        print(
            f"{w['label']:<22} {bar} "
            f"{w['used_percent']:>5.1f}% used  "
            f"({w['remaining_percent']:.1f}% left, {resets})"
        )

    extra = report["extra_usage"]
    if extra:
        print("-" * 58)
        used = extra.get("used_credits")
        limit = extra.get("monthly_limit")
        cur = extra.get("currency") or ""
        print(f"Extra usage:           {used} / {limit} {cur} used this month")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="output structured JSON")
    parser.add_argument(
        "--raw",
        action="store_true",
        help="print the complete, unmodified API response",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=None,
        metavar="PCT",
        help="exit 1 if any active window is at or above PCT%% used (for alerts)",
    )
    parser.add_argument(
        "--estimate",
        action="store_true",
        help="estimate per-model token headroom in each window (uses local logs)",
    )
    parser.add_argument(
        "--api-credits",
        action="store_true",
        help="also report Anthropic API spend (needs an Admin key; see .secrets)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=30,
        metavar="N",
        help="window for --api-credits spend, in days (default 30)",
    )
    args = parser.parse_args(argv)

    try:
        token = read_token()
        data = fetch_usage(token)
    except UsageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    now = datetime.now(timezone.utc)

    cost_report = None
    if args.api_credits:
        try:
            admin_key = read_admin_key()
            start = (now - timedelta(days=args.days)).replace(
                hour=0, minute=0, second=0, microsecond=0
            )
            buckets = fetch_cost_report(admin_key, start)
            cost_report = build_cost_report(buckets, start, now)
        except UsageError as exc:
            print(f"error (--api-credits): {exc}", file=sys.stderr)
            return 2

    if args.raw:
        print(json.dumps(data, indent=2))
        return 0

    report = build_report(data, now)

    estimate = None
    if args.estimate:
        try:
            estimate = build_estimate(data, now, token)
        except UsageError as exc:
            print(f"error (--estimate): {exc}", file=sys.stderr)
            return 2
        report["estimate"] = estimate

    if cost_report is not None:
        report["api_spend"] = cost_report

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_human(report)
        if estimate is not None:
            print_estimate(estimate)
        if cost_report is not None:
            print_cost_report(cost_report, args.days)

    if args.threshold is not None:
        breached = [w for w in report["windows"] if w["used_percent"] >= args.threshold]
        if breached:
            names = ", ".join(w["label"] for w in breached)
            if not args.json:
                print(f"\n⚠️  at/over {args.threshold:.0f}%: {names}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
