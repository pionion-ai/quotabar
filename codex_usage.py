#!/usr/bin/env python3
"""codex_usage — report OpenAI Codex (ChatGPT-plan) usage limits and reset times.

Prototype companion to claude_usage.py. Reads the local Codex CLI OAuth token
(~/.codex/auth.json) and queries the same usage endpoint the Codex CLI uses,
then prints how much of each rate-limit window is consumed and when it resets.

Codex uses the same shape as Claude Code: a 5-hour (primary) window and a
weekly (secondary) window, reported as an integer "used_percent" plus a reset
time. No third-party dependencies — standard library only.

Usage:
    ./codex_usage.py           # human-readable summary
    ./codex_usage.py --json    # machine-readable JSON
    ./codex_usage.py --raw     # the complete, unmodified API response
    ./codex_usage.py --threshold 90   # exit 1 if any window is >= 90% used
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

USAGE_ENDPOINT = "https://chatgpt.com/backend-api/wham/usage"
AUTH_FILE = Path.home() / ".codex" / "auth.json"
DEFAULT_VERSION = "0.136.0"

# Windows are distinguished by their length in seconds (defensive: don't rely on
# key order). 5h = 18000s, 7d = 604800s.
WINDOW_LABELS = {
    18000: "5-hour",
    604800: "7-day (weekly)",
}


class UsageError(Exception):
    """A user-facing error with a clear message."""


def codex_version() -> str:
    """Best-effort Codex CLI version for the User-Agent (falls back to a constant)."""
    try:
        out = subprocess.run(
            ["codex", "--version"], capture_output=True, text=True, timeout=5
        ).stdout
        for tok in out.split():
            if tok[:1].isdigit() and "." in tok:
                return tok
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        pass
    return DEFAULT_VERSION


def read_auth() -> tuple[str, str]:
    """Return (access_token, account_id) from ~/.codex/auth.json.

    Re-read on every run so we pick up tokens the Codex CLI itself refreshed.
    """
    if not AUTH_FILE.exists():
        raise UsageError(
            f"No Codex credentials at {AUTH_FILE}.\n"
            "Log in once with `codex` (ChatGPT plan) and retry."
        )
    try:
        tokens = json.loads(AUTH_FILE.read_text()).get("tokens") or {}
    except json.JSONDecodeError as exc:
        raise UsageError(f"Codex auth.json is not valid JSON: {exc}") from exc

    token = tokens.get("access_token")
    if not token:
        raise UsageError(
            "No access_token in auth.json (are you on API-key mode, not a ChatGPT plan?)."
        )
    return token, tokens.get("account_id", "")


def fetch_usage(token: str, account_id: str) -> dict:
    """GET the Codex usage endpoint and return the parsed JSON body."""
    req = urllib.request.Request(
        USAGE_ENDPOINT,
        headers={
            "Authorization": f"Bearer {token}",
            "ChatGPT-Account-Id": account_id,
            "User-Agent": f"codex_cli_rs/{codex_version()}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise UsageError(
                "Authentication failed (401). Your Codex token may have expired — "
                "run `codex` once to refresh it."
            ) from exc
        raise UsageError(f"Usage endpoint returned HTTP {exc.code}.") from exc
    except urllib.error.URLError as exc:
        raise UsageError(f"Could not reach the usage endpoint: {exc.reason}") from exc


def humanize_delta(seconds: int) -> str:
    """Return e.g. '2h 14m' for a positive seconds count, or 'now'."""
    if seconds <= 0:
        return "now"
    days, rem = divmod(int(seconds), 86400)
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
    """Normalize the raw response into per-window used/remaining percentages."""
    rl = data.get("rate_limit") or {}
    windows = []
    for key in ("primary_window", "secondary_window"):
        block = rl.get(key)
        if not isinstance(block, dict):
            continue
        used = block.get("used_percent")
        if used is None:
            continue
        length = block.get("limit_window_seconds")
        reset_at = block.get("reset_at")
        reset_dt = (
            datetime.fromtimestamp(reset_at, tz=timezone.utc) if reset_at else None
        )
        resets_in = block.get("reset_after_seconds")
        windows.append(
            {
                "key": key,
                "label": WINDOW_LABELS.get(length, f"{length}s window"),
                "used_percent": round(float(used), 1),
                "remaining_percent": round(100 - float(used), 1),
                "resets_at": reset_dt.isoformat() if reset_dt else None,
                "resets_in": humanize_delta(resets_in) if resets_in is not None else None,
            }
        )

    credits = data.get("credits") or {}
    return {
        "checked_at": now.isoformat(),
        "plan_type": data.get("plan_type"),
        "limit_reached": rl.get("limit_reached"),
        "windows": windows,
        "credits": {
            "has_credits": credits.get("has_credits"),
            "balance": credits.get("balance"),
        },
        "reset_credits_available": (data.get("rate_limit_reset_credits") or {}).get(
            "available_count"
        ),
    }


def print_human(report: dict) -> None:
    plan = report.get("plan_type") or "?"
    print(f"Codex usage ({plan})  —  checked {report['checked_at']}")
    print("-" * 58)
    if not report["windows"]:
        print("No usage windows reported.")
    for w in report["windows"]:
        bar_len = 20
        filled = int(round(w["used_percent"] / 100 * bar_len))
        bar = "█" * filled + "░" * (bar_len - filled)
        resets = f"resets in {w['resets_in']}" if w["resets_in"] else "n/a"
        print(
            f"{w['label']:<16} {bar} "
            f"{w['used_percent']:>5.1f}% used  "
            f"({w['remaining_percent']:.1f}% left, {resets})"
        )
    rc = report.get("reset_credits_available")
    if rc:
        print(f"\nlimit-reset credits available: {rc}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="output structured JSON")
    parser.add_argument(
        "--raw", action="store_true", help="print the complete, unmodified API response"
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=None,
        metavar="PCT",
        help="exit 1 if any window is at or above PCT%% used (for alerts)",
    )
    args = parser.parse_args(argv)

    try:
        token, account_id = read_auth()
        data = fetch_usage(token, account_id)
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
