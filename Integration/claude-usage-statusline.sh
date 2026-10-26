#!/bin/bash
#
# claude-usage-statusline.sh — Claude Code status-line integration for Claude Usage.
#
# Claude Code runs this command and passes its status-line JSON on stdin
# (https://code.claude.com/docs/en/statusline). This script:
#
#   1. Extracts ONLY the documented subscription usage windows:
#        rate_limits.five_hour.{used_percentage,resets_at}
#        rate_limits.seven_day.{used_percentage,resets_at}
#        rate_limits.spend_limit.{used_percentage,resets_at}   (Claude apps gateway only)
#      Nothing else from the payload (prompts, paths, session ids, costs,
#      context-window data) is written or logged.
#   2. Validates them, converts epoch-second reset times to ISO 8601 UTC, and
#      atomically writes ~/Library/Application Support/ClaudeUsage/usage.json
#      (schema version 1). If the payload has no valid window, usage.json is
#      left untouched so the last known-good snapshot survives.
#   3. Writes a small heartbeat (status.json): when it ran, whether usage was
#      present, and the Claude Code version.
#   4. Prints the status line. If a previous status-line command was saved in
#      ClaudeUsage/wrapped-command (by the installer, or by you), the same
#      stdin is piped to it and its output is printed unchanged. Otherwise a
#      short usage summary is printed.
#
# Requirements: bash and jq (/usr/bin/jq ships with macOS 15 and later).
# No network access. Always exits 0 so the status line never breaks.
# Permissions: install as 0700 (owner read/write/execute).

set -u
umask 077

SCRIPT_VERSION="1"
DATA_DIR="${CLAUDE_USAGE_DIR:-$HOME/Library/Application Support/ClaudeUsage}"
SNAPSHOT_FILE="$DATA_DIR/usage.json"
STATUS_FILE="$DATA_DIR/status.json"
WRAPPED_FILE="$DATA_DIR/wrapped-command"

find_jq() {
    if [ -n "${CLAUDE_USAGE_JQ:-}" ] && [ -x "$CLAUDE_USAGE_JQ" ]; then
        printf '%s' "$CLAUDE_USAGE_JQ"
    elif [ -x /usr/bin/jq ]; then
        printf '%s' /usr/bin/jq
    else
        command -v jq 2>/dev/null
    fi
}

TMP_FILES=()
cleanup() {
    local f
    for f in "${TMP_FILES[@]+"${TMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT
trap 'exit 0' TERM INT

# Atomically replace "$1" with stdin: temp file in the same directory, then
# rename(2) via mv. Readers see either the old or the new complete file.
atomic_write() {
    local target="$1" tmp
    tmp="$(mktemp "$DATA_DIR/.$(basename "$target").XXXXXX")" || return 1
    TMP_FILES+=("$tmp")
    cat > "$tmp" || return 1
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$target"
}

# The payload is kept in memory only; it is never written to disk.
INPUT="$(cat)"
JQ="$(find_jq)"
NOW_EPOCH="$(date -u +%s)"

record_usage() {
    [ -n "$JQ" ] || return 0
    mkdir -p "$DATA_DIR" 2>/dev/null || return 0
    chmod 700 "$DATA_DIR" 2>/dev/null

    local snapshot result
    # Parse with jq (no regex extraction). Output is empty when there is no
    # usable window; jq exits non-zero when the input is not JSON.
    if snapshot="$(printf '%s' "$INPUT" | "$JQ" -c --argjson now "$NOW_EPOCH" '
        # Reported only if used_percentage is a number in range. Values above
        # 100 are accepted only for the gateway spend limit (documented).
        def window($id; $title; $kind; $w; $allowOver):
          if ($w | type) == "object"
             and ($w.used_percentage | type) == "number"
             and $w.used_percentage >= 0
             and ($allowOver or $w.used_percentage <= 100)
          then
            { id: $id, title: $title, kind: $kind,
              usedPercentage: $w.used_percentage, availability: "reported" }
            + ( if ($w.resets_at | type) == "number"
                   and $w.resets_at > 0 and $w.resets_at < 100000000000
                then { resetsAt: ($w.resets_at | floor | todate) }
                else {} end )
          else
            { id: $id, title: $title, kind: $kind, availability: "notReported" }
          end;

        (if type == "object" then .rate_limits else null end) as $r
        | if ($r | type) != "object" then empty else
            ( [ window("session"; "Current session"; "fiveHour"; $r.five_hour; false),
                window("weekly";  "Weekly limit";    "sevenDay"; $r.seven_day; false) ]
              + ( if ($r.spend_limit | type) == "object"
                  then [ window("spendLimit"; "Spend limit"; "spendLimit"; $r.spend_limit; true) ]
                  else [] end ) )
            | select(any(.[]; .availability == "reported"))
            | { schemaVersion: 1,
                observedAt: ($now | todate),
                source: "claude-code-status-line",
                limits: . }
          end
      ' 2>/dev/null)"; then
        if [ -n "$snapshot" ]; then
            if printf '%s\n' "$snapshot" | atomic_write "$SNAPSHOT_FILE"; then
                result="written"
            else
                result="writeFailed"
            fi
        else
            result="noRateLimits"
        fi
    else
        result="invalidInput"
    fi

    # Heartbeat. claudeCodeVersion is kept only if it looks like a version string.
    local version
    version="$(printf '%s' "$INPUT" | "$JQ" -r '
        if type == "object" and (.version | type) == "string"
           and (.version | test("^[0-9A-Za-z.+-]{1,32}$"))
        then .version else empty end' 2>/dev/null)" || version=""
    "$JQ" -n -c --argjson now "$NOW_EPOCH" --arg result "$result" --arg version "$version" --arg sv "$SCRIPT_VERSION" '
        { schemaVersion: 1, invokedAt: ($now | todate), result: $result, scriptVersion: $sv }
        + (if $version != "" then { claudeCodeVersion: $version } else {} end)
    ' 2>/dev/null | atomic_write "$STATUS_FILE"
}

render_status_line() {
    # Delegate to the user's previous status-line command, if one was saved.
    # The command comes from the user's own settings, never from the payload.
    if [ -s "$WRAPPED_FILE" ]; then
        local wrapped
        wrapped="$(cat "$WRAPPED_FILE")"
        printf '%s' "$INPUT" | /bin/sh -c "$wrapped"
        return 0
    fi
    [ -n "$JQ" ] || return 0
    printf '%s' "$INPUT" | "$JQ" -r '
        def pct: (round | tostring) + "%";
        if type == "object" and (.rate_limits | type) == "object" then
          [ (if (.rate_limits.five_hour.used_percentage | type) == "number"
             then "5h " + (.rate_limits.five_hour.used_percentage | pct) else empty end),
            (if (.rate_limits.seven_day.used_percentage | type) == "number"
             then "7d " + (.rate_limits.seven_day.used_percentage | pct) else empty end) ]
          | if length > 0 then "Claude usage: " + join(" · ") else empty end
        else empty end' 2>/dev/null
}

record_usage
render_status_line
exit 0
