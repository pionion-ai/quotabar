#!/bin/sh
# Tests for Resources/quotabar-statusline. Runs entirely in a temp HOME.
# Usage: Tests/bridge/test-statusline.sh   (exit 0 = all passed)
set -u
here=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$here/../../Resources/quotabar-statusline"
fails=0; n=0
ok()   { n=$((n+1)); }
fail() { n=$((n+1)); fails=$((fails+1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else fail "$1"; fi; }

fresh() {
  export HOME=$(mktemp -d)
  unset CLAUDE_CONFIG_DIR
  QB="$HOME/.quotabar"; SETTINGS="$HOME/.claude/settings.json"
}
PAYLOAD='{"session_id":"s1","cwd":"/secret/project","model":{"id":"m"},"transcript_path":"/t.jsonl",
 "rate_limits":{"five_hour":{"used_percentage":11.4,"resets_at":1795571999},
                "seven_day":{"used_percentage":10,"resets_at":1795600000}}}'
NOLIMITS='{"session_id":"s1","cwd":"/x"}'
get() { /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null; }

# --- normal run: writes only rate_limits + written_at, prints compact summary
fresh
out=$(printf '%s' "$PAYLOAD" | "$SCRIPT")
check "summary printed"            '[ "$out" = "5h 11% · 7d 10%" ]'
check "status file written"        '[ -f "$QB/claude-status.json" ]'
check "five_hour percent saved"    '[ "$(get rate_limits.five_hour.used_percentage "$QB/claude-status.json")" = "11.4" ] || [ "$(get rate_limits.five_hour.used_percentage "$QB/claude-status.json")" = "11.400000" ]'
check "written_at saved"           '[ -n "$(get written_at "$QB/claude-status.json")" ]'
check "no cwd leaked"              '! grep -q secret "$QB/claude-status.json"'
check "no session leaked"          '! grep -q session_id "$QB/claude-status.json"'

# --- payload without rate_limits leaves the file alone
before=$(cat "$QB/claude-status.json")
out=$(printf '%s' "$NOLIMITS" | "$SCRIPT"); rc=$?
check "no-limits run succeeds"     '[ $rc -eq 0 ]'
check "file untouched"             '[ "$(cat "$QB/claude-status.json")" = "$before" ]'

# --- install with no settings.json creates it
fresh
"$SCRIPT" --install >/dev/null; rc=$?
check "install ok (no settings)"   '[ $rc -eq 0 ]'
check "settings created"           '[ "$(get statusLine.command "$SETTINGS")" = "$QB/quotabar-statusline" ]'
check "script copied + executable" '[ -x "$QB/quotabar-statusline" ]'

# --- install preserves other keys and order, backs up, saves previous status line
fresh
mkdir -p "$HOME/.claude"
printf '{\n  "model": "opus",\n  "statusLine": {"type": "command", "command": "echo PREV-$(cat | wc -c | tr -d \\" \\")"},\n  "permissions": {"allow": ["Bash(ls)"]}\n}\n' > "$SETTINGS"
orig=$(cat "$SETTINGS")
"$SCRIPT" --install >/dev/null; rc=$?
check "install ok (existing)"      '[ $rc -eq 0 ]'
check "model kept"                 '[ "$(get model "$SETTINGS")" = "opus" ]'
check "permissions kept"           '[ "$(get permissions.allow.0 "$SETTINGS")" = "Bash(ls)" ]'
check "key order kept"             '[ "$(grep -o "\"[a-zA-Z]*\": " "$SETTINGS" | head -1)" = "\"model\": " ]'
check "backup written"             '[ "$(cat "$SETTINGS.quotabar-backup")" = "$orig" ]'
check "previous saved"             'grep -q "echo PREV" "$QB/previous-statusline.json"'
check "ours installed"             '[ "$(get statusLine.command "$SETTINGS")" = "$QB/quotabar-statusline" ]'

# --- second install is idempotent (does not save ours as "previous")
"$SCRIPT" --install >/dev/null
check "idempotent previous"        'grep -q "echo PREV" "$QB/previous-statusline.json"'

# --- chained: previous status line gets the same stdin and its output is shown
out=$(printf '%s' "$PAYLOAD" | "$QB/quotabar-statusline")
check "previous output passed"     'case "$out" in PREV-*) true;; *) false;; esac'
check "previous got stdin"         '[ "${out#PREV-}" -gt 100 ]'
check "capture still happened"     '[ -f "$QB/claude-status.json" ]'

# --- uninstall restores the previous status line
"$SCRIPT" --uninstall >/dev/null; rc=$?
check "uninstall ok"               '[ $rc -eq 0 ]'
check "previous restored"          'get statusLine.command "$SETTINGS" | grep -q "echo PREV"'
check "previous file removed"      '[ ! -f "$QB/previous-statusline.json" ]'

# --- uninstall with no previous removes statusLine entirely
fresh
"$SCRIPT" --install >/dev/null; "$SCRIPT" --uninstall >/dev/null
check "statusLine removed"         '! grep -q statusLine "$SETTINGS"'

# --- malformed settings: abort, unchanged
fresh
mkdir -p "$HOME/.claude"; printf '{ "model": "opus", ' > "$SETTINGS"
"$SCRIPT" --install >/dev/null 2>&1; rc=$?
check "malformed -> non-zero"      '[ $rc -ne 0 ]'
check "malformed unchanged"        '[ "$(cat "$SETTINGS")" = "{ \"model\": \"opus\", " ]'

# --- CLAUDE_CONFIG_DIR honoured
fresh
export CLAUDE_CONFIG_DIR="$HOME/altcfg"
"$SCRIPT" --install >/dev/null
check "CLAUDE_CONFIG_DIR used"     '[ -f "$HOME/altcfg/settings.json" ]'

echo "$((n-fails))/$n passed"
[ $fails -eq 0 ]
