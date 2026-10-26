#!/bin/bash
#
# uninstall-integration.sh — remove the Claude Usage status-line integration.
#
# What it does (asks before each change):
#   1. If Claude Code's statusLine still points at the Claude Usage script,
#      restores your previous statusLine block (saved by the installer), or
#      removes statusLine if you had none. Other settings are preserved.
#      A backup of settings.json is made first. If statusLine was changed
#      since installation, settings.json is left untouched.
#   2. Removes the installed script and install records:
#        ClaudeUsage/bin/, wrapped-command, original-statusline.json, integration.json
#   3. Asks whether to also delete the local usage data (usage.json, status.json).
#      Default: keep.
#
# It does not remove the app, installer backups of settings.json, or the
# app's App Group container (~/Library/Group Containers/<APP_GROUP_IDENTIFIER>),
# which macOS removes with the app's data. No background processes or launch
# agents are installed, so none need removing.
#
# Usage: uninstall-integration.sh [--keep-data | --delete-data]

set -euo pipefail
umask 077

DATA_CHOICE="ask"
for arg in "$@"; do
    case "$arg" in
        --keep-data) DATA_CHOICE="keep" ;;
        --delete-data) DATA_CHOICE="delete" ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
DATA_DIR="${CLAUDE_USAGE_DIR:-$HOME/Library/Application Support/ClaudeUsage}"
INSTALLED_SCRIPT="$DATA_DIR/bin/claude-usage-statusline.sh"
ORIGINAL_FILE="$DATA_DIR/original-statusline.json"
OUR_COMMAND="\"$INSTALLED_SCRIPT\""

say()  { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
confirm() {
    local answer=""
    printf '%s [y/N] ' "$1"
    read -r answer || true
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

JQ="${CLAUDE_USAGE_JQ:-}"
if [ -z "$JQ" ]; then
    if [ -x /usr/bin/jq ]; then JQ=/usr/bin/jq; else JQ="$(command -v jq || true)"; fi
fi
[ -n "$JQ" ] && [ -x "$JQ" ] || fail "jq is required."

SETTINGS_TARGET="$SETTINGS"
[ -L "$SETTINGS" ] && SETTINGS_TARGET="$(readlink -f "$SETTINGS")"

# --- 1. Settings ---------------------------------------------------------------

if [ -f "$SETTINGS_TARGET" ] && "$JQ" -e --arg cmd "$OUR_COMMAND" '.statusLine.command == $cmd' "$SETTINGS_TARGET" >/dev/null 2>&1; then
    CURRENT_JSON="$(cat "$SETTINGS_TARGET")"
    if [ -s "$ORIGINAL_FILE" ] && "$JQ" -e 'type == "object"' "$ORIGINAL_FILE" >/dev/null 2>&1; then
        NEW_JSON="$(printf '%s' "$CURRENT_JSON" | "$JQ" --slurpfile orig "$ORIGINAL_FILE" '.statusLine = $orig[0]')"
        say "Your previous status line will be restored."
    else
        NEW_JSON="$(printf '%s' "$CURRENT_JSON" | "$JQ" 'del(.statusLine)')"
        say "statusLine will be removed (there was none before installation)."
    fi
    say ""
    say "Proposed change to $SETTINGS:"
    diff -u <(printf '%s\n' "$CURRENT_JSON" | "$JQ" .) <(printf '%s\n' "$NEW_JSON" | "$JQ" .) \
        --label "current" --label "proposed" || true
    say ""
    if confirm "Apply this change?"; then
        BACKUP="$SETTINGS_TARGET.claude-usage-backup-$(date +%Y%m%d-%H%M%S)"
        cp -p "$SETTINGS_TARGET" "$BACKUP"
        chmod 600 "$BACKUP"
        TMP_SETTINGS="$(mktemp "$(dirname "$SETTINGS_TARGET")/.settings.json.XXXXXX")"
        trap 'rm -f "$TMP_SETTINGS"' EXIT
        printf '%s\n' "$NEW_JSON" | "$JQ" . > "$TMP_SETTINGS"
        "$JQ" -e 'type == "object"' "$TMP_SETTINGS" >/dev/null || fail "Validation failed. Nothing changed."
        chmod "$(stat -f '%Lp' "$SETTINGS_TARGET")" "$TMP_SETTINGS"
        mv -f "$TMP_SETTINGS" "$SETTINGS_TARGET"
        trap - EXIT
        say "Settings updated (backup: $BACKUP)."
    else
        say "Settings left unchanged. The integration files were not removed."
        exit 1
    fi
elif [ -f "$SETTINGS_TARGET" ]; then
    say "statusLine in $SETTINGS does not point to Claude Usage; leaving settings untouched."
else
    say "No $SETTINGS found; nothing to change there."
fi

# --- 2. Integration files --------------------------------------------------------

rm -rf "$DATA_DIR/bin"
rm -f "$DATA_DIR/wrapped-command" "$ORIGINAL_FILE" "$DATA_DIR/integration.json"
say "Removed the integration script and install records from $DATA_DIR."

# --- 3. Usage data -----------------------------------------------------------------

if [ "$DATA_CHOICE" = "ask" ]; then
    if confirm "Also delete the local usage snapshot (usage.json, status.json)?"; then
        DATA_CHOICE="delete"
    else
        DATA_CHOICE="keep"
    fi
fi
if [ "$DATA_CHOICE" = "delete" ]; then
    rm -f "$DATA_DIR/usage.json" "$DATA_DIR/status.json"
    rmdir "$DATA_DIR" 2>/dev/null || true
    say "Deleted local usage data."
else
    say "Kept local usage data in $DATA_DIR."
fi

say ""
say "Done. Settings backups (settings.json.claude-usage-backup-*) were kept in $(dirname "$SETTINGS_TARGET")."
say "To remove the app: quit Claude Usage from its menu, then move it to the Trash."
