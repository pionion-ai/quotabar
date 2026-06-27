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
import json
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

USAGE_ENDPOINT = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
CREDENTIALS_FILE = Path.home() / ".claude" / ".credentials.json"

# Friendly labels for the windows we care about, in display order.
WINDOWS = [
    ("five_hour", "5-hour session"),
    ("seven_day", "7-day (all models)"),
    ("seven_day_opus", "7-day (Opus)"),
    ("seven_day_sonnet", "7-day (Sonnet)"),
]


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
    args = parser.parse_args(argv)

    try:
        token = read_token()
        data = fetch_usage(token)
    except UsageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.raw:
        print(json.dumps(data, indent=2))
        return 0

    now = datetime.now(timezone.utc)
    report = build_report(data, now)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_human(report)

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
