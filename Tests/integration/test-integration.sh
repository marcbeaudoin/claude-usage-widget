#!/bin/bash
#
# Integration tests for the status-line script, installer and uninstaller.
# Everything runs inside a temporary HOME; your real ~/.claude is never touched.
#
# Usage: Tests/integration/test-integration.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATUSLINE="$ROOT/Integration/claude-usage-statusline.sh"
INSTALL="$ROOT/Scripts/install-integration.sh"
UNINSTALL="$ROOT/Scripts/uninstall-integration.sh"
FIXTURE="$ROOT/Integration/fixtures/statusline-payload.sample.json"
EXPECTED="$ROOT/ClaudeUsageWidgetTests/Fixtures/normalized-snapshot.json"
JQ="$(command -v jq)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

new_env() {
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    export CLAUDE_CONFIG_DIR="$TEST_HOME/.claude"
    export CLAUDE_USAGE_DIR="$TEST_HOME/Library/Application Support/ClaudeUsage"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    DATA="$CLAUDE_USAGE_DIR"
    SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
    OUR_CMD="\"$DATA/bin/claude-usage-statusline.sh\""
}
end_env() { rm -rf "$TEST_HOME"; }

payload() { # five_hour seven_day [extra]
    printf '{"version":"2.1.309","session_id":"secret-session","transcript_path":"/secret/path","rate_limits":{"five_hour":%s,"seven_day":%s}%s}' "$1" "$2" "${3:-}"
}

echo "Status-line script"

new_env
OUT="$(bash "$STATUSLINE" < "$FIXTURE")"
check "prints default summary" '[ "$OUT" = "Claude usage: 5h 24% · 7d 41%" ]'
check "writes usage.json" '[ -f "$DATA/usage.json" ]'
check "normalized output matches committed fixture (except observedAt)" \
    '[ "$("$JQ" -S "del(.observedAt)" "$DATA/usage.json")" = "$("$JQ" -S "del(.observedAt)" "$EXPECTED")" ]'
check "observedAt is ISO 8601 UTC" '"$JQ" -e ".observedAt | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$\")" "$DATA/usage.json" >/dev/null'
check "files are owner-only (0600) in a 0700 directory" \
    '[ "$(stat -f %Lp "$DATA/usage.json")" = 600 ] && [ "$(stat -f %Lp "$DATA")" = 700 ]'
check "no payload secrets in output files" \
    '! grep -q -e secret -e transcript -e session_id -e cost -e context "$DATA/usage.json" "$DATA/status.json"'
check "context-window data is never used" '! grep -q context_window "$DATA/usage.json"'
check "heartbeat records written + version" \
    '"$JQ" -e ".result == \"written\" and .claudeCodeVersion == \"2.1.309\"" "$DATA/status.json" >/dev/null'
check "no temp files left" '[ -z "$(find "$DATA" -name ".*" -type f)" ]'
BEFORE="$(cat "$DATA/usage.json")"

echo '{"version":"2.1.309","model":{"id":"x"}}' | bash "$STATUSLINE" >/dev/null
check "payload without rate_limits keeps last snapshot" '[ "$(cat "$DATA/usage.json")" = "$BEFORE" ]'
check "heartbeat says noRateLimits" '"$JQ" -e ".result == \"noRateLimits\"" "$DATA/status.json" >/dev/null'

echo 'this is not json {' | bash "$STATUSLINE" >/dev/null; RC=$?
check "invalid JSON exits 0" '[ $RC -eq 0 ]'
check "invalid JSON keeps last snapshot" '[ "$(cat "$DATA/usage.json")" = "$BEFORE" ]'
check "heartbeat says invalidInput" '"$JQ" -e ".result == \"invalidInput\"" "$DATA/status.json" >/dev/null'

payload '{"used_percentage":150,"resets_at":1792512000}' '{"used_percentage":10}' | bash "$STATUSLINE" >/dev/null
check "out-of-range session is notReported, weekly kept" \
    '"$JQ" -e "(.limits[0].availability == \"notReported\") and (.limits[0] | has(\"usedPercentage\") | not) and .limits[1].usedPercentage == 10" "$DATA/usage.json" >/dev/null'
check "missing resets_at stays missing" '"$JQ" -e ".limits[1] | has(\"resetsAt\") | not" "$DATA/usage.json" >/dev/null'

payload '{"used_percentage":-1}' '"oops"' | bash "$STATUSLINE" >/dev/null
check "no valid window: snapshot untouched" '"$JQ" -e ".limits[1].usedPercentage == 10" "$DATA/usage.json" >/dev/null'

payload 'null' '{"used_percentage":5,"resets_at":1792512000123}' | bash "$STATUSLINE" >/dev/null
check "millisecond-looking resets_at is rejected, not misread" '"$JQ" -e ".limits[1] | has(\"resetsAt\") | not" "$DATA/usage.json" >/dev/null'

"$JQ" '.rate_limits.spend_limit = {"used_percentage":130,"resets_at":1792512000}' "$FIXTURE" | bash "$STATUSLINE" >/dev/null
check "spend limit may exceed 100%" '"$JQ" -e ".limits[2] | .kind == \"spendLimit\" and .usedPercentage == 130" "$DATA/usage.json" >/dev/null'

printf '%s' 'cat > "$HOME/wrapped-input.json"; echo "MY STATUS LINE"' > "$DATA/wrapped-command"
OUT="$(bash "$STATUSLINE" < "$FIXTURE")"
check "wrapped command output is passed through" '[ "$OUT" = "MY STATUS LINE" ]'
check "wrapped command receives identical stdin" 'cmp -s "$HOME/wrapped-input.json" <(printf "%s" "$(cat "$FIXTURE")")'
end_env

echo "Installer"

new_env
printf 'y\n' | bash "$INSTALL" >/dev/null 2>&1
check "fresh install creates settings with our command" '"$JQ" -e --arg c "$OUR_CMD" ".statusLine == {type: \"command\", command: \$c}" "$SETTINGS" >/dev/null'
check "script installed as 0700" '[ "$(stat -f %Lp "$DATA/bin/claude-usage-statusline.sh")" = 700 ]'
check "marker written" '"$JQ" -e ".schemaVersion == 1 and .createdSettingsFile == true" "$DATA/integration.json" >/dev/null'
check "no wrapped command when none existed" '[ ! -e "$DATA/wrapped-command" ]'
OUT="$(printf 'y\n' | bash "$INSTALL" 2>&1)"
check "re-running is idempotent" 'echo "$OUT" | grep -q "already installed"'
printf 'y\n' | bash "$UNINSTALL" --keep-data >/dev/null 2>&1
check "uninstall removes statusLine it created" '"$JQ" -e "has(\"statusLine\") | not" "$SETTINGS" >/dev/null'
check "uninstall removes script and marker" '[ ! -e "$DATA/bin" ] && [ ! -e "$DATA/integration.json" ]'
end_env

new_env
cat > "$SETTINGS" <<'JSON'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(git status)"] },
  "statusLine": { "type": "command", "command": "~/.claude/my-statusline.sh --fancy", "padding": 2, "refreshInterval": 30 },
  "env": { "FOO": "bar" }
}
JSON
chmod 644 "$SETTINGS"
ORIGINAL="$(cat "$SETTINGS")"

printf 'n\n' | bash "$INSTALL" >/dev/null 2>&1; RC=$?
check "declining changes nothing" '[ $RC -ne 0 ] && [ "$(cat "$SETTINGS")" = "$ORIGINAL" ] && [ ! -e "$DATA/bin" ]'

bash "$INSTALL" --dry-run >/dev/null 2>&1 </dev/null
check "dry run changes nothing" '[ "$(cat "$SETTINGS")" = "$ORIGINAL" ] && [ ! -e "$DATA/integration.json" ]'

OUT="$(printf 'y\n' | bash "$INSTALL" 2>&1)"
check "installer shows a diff" 'echo "$OUT" | grep -q "^+.*claude-usage-statusline.sh"'
check "existing command is wrapped, not lost" '[ "$(cat "$DATA/wrapped-command")" = "~/.claude/my-statusline.sh --fancy" ]'
check "unrelated settings preserved" \
    '[ "$("$JQ" -S "del(.statusLine)" "$SETTINGS")" = "$(printf "%s" "$ORIGINAL" | "$JQ" -S "del(.statusLine)")" ]'
check "padding and refreshInterval preserved" '"$JQ" -e ".statusLine.padding == 2 and .statusLine.refreshInterval == 30" "$SETTINGS" >/dev/null'
check "settings file mode preserved" '[ "$(stat -f %Lp "$SETTINGS")" = 644 ]'
BACKUP="$(ls "$CLAUDE_CONFIG_DIR"/settings.json.claude-usage-backup-* 2>/dev/null | head -1)"
check "backup created and identical to original" '[ -n "$BACKUP" ] && [ "$(cat "$BACKUP")" = "$ORIGINAL" ]'

printf 'y\nn\n' | bash "$UNINSTALL" >/dev/null 2>&1
check "uninstall restores the original statusLine exactly" \
    '[ "$("$JQ" -S . "$SETTINGS")" = "$(printf "%s" "$ORIGINAL" | "$JQ" -S .)" ]'
check "uninstall removes wrapped-command" '[ ! -e "$DATA/wrapped-command" ]'
end_env

new_env
printf 'y\n' | bash "$INSTALL" >/dev/null 2>&1
bash "$STATUSLINE" < "$FIXTURE" >/dev/null
printf 'y\ny\n' | bash "$UNINSTALL" >/dev/null 2>&1
check "uninstall can delete usage data on request" '[ ! -e "$DATA/usage.json" ] && [ ! -e "$DATA/status.json" ]'
end_env

new_env
printf 'y\n' | bash "$INSTALL" >/dev/null 2>&1
bash "$STATUSLINE" < "$FIXTURE" >/dev/null
printf 'y\nn\n' | bash "$UNINSTALL" >/dev/null 2>&1
check "uninstall keeps usage data by default" '[ -f "$DATA/usage.json" ]'
end_env

new_env
printf 'y\n' | bash "$INSTALL" >/dev/null 2>&1
"$JQ" '.statusLine.command = "something-else"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
CHANGED="$(cat "$SETTINGS")"
printf 'n\n' | bash "$UNINSTALL" >/dev/null 2>&1
check "uninstall leaves a status line changed by the user untouched" '[ "$(cat "$SETTINGS")" = "$CHANGED" ]'
end_env

new_env
printf '{ "model": "opus", ' > "$SETTINGS"
BROKEN="$(cat "$SETTINGS")"
printf 'y\n' | bash "$INSTALL" >/dev/null 2>&1; RC=$?
check "invalid settings JSON aborts without changes" '[ $RC -ne 0 ] && [ "$(cat "$SETTINGS")" = "$BROKEN" ] && [ ! -e "$DATA/bin" ]'
end_env

new_env
mkdir -p "$TEST_HOME/dotfiles"
echo '{"model":"opus"}' > "$TEST_HOME/dotfiles/settings.json"
ln -s "$TEST_HOME/dotfiles/settings.json" "$SETTINGS"
printf 'y\n' | bash "$INSTALL" >/dev/null 2>&1
check "symlinked settings: link kept, target updated" \
    '[ -L "$SETTINGS" ] && "$JQ" -e ".statusLine.command != null and .model == \"opus\"" "$TEST_HOME/dotfiles/settings.json" >/dev/null'
end_env

new_env
echo '{"statusLine":{"type":"static","text":"hi"}}' > "$SETTINGS"
printf 'y\n' | bash "$INSTALL" >/dev/null 2>&1; RC=$?
check "unknown statusLine type is not overwritten" '[ $RC -ne 0 ] && "$JQ" -e ".statusLine.type == \"static\"" "$SETTINGS" >/dev/null'
end_env

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
