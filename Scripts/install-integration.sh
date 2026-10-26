#!/bin/bash
#
# install-integration.sh — install the Claude Usage status-line integration.
#
# What it does (nothing is changed before you confirm):
#   1. Checks for Claude Code and jq.
#   2. Copies claude-usage-statusline.sh to
#        ~/Library/Application Support/ClaudeUsage/bin/   (mode 0700)
#   3. Backs up your Claude Code user settings
#        ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json
#      to settings.json.claude-usage-backup-<timestamp> (mode 0600).
#   4. Shows a diff of the proposed change to "statusLine" and asks for
#      confirmation. Only statusLine.type and statusLine.command change;
#      every other setting (including statusLine.padding / refreshInterval)
#      is preserved.
#   5. If you already have a status-line command, it is NOT replaced: it is
#      saved to ClaudeUsage/wrapped-command and the integration runs it with
#      the same input and prints its output unchanged.
#   6. Writes ClaudeUsage/integration.json (install record used by the app and
#      the uninstaller).
#
# Usage: install-integration.sh [--dry-run]
#   --dry-run   show what would change and exit without writing anything.
#
# Environment (mainly for tests): CLAUDE_CONFIG_DIR, CLAUDE_USAGE_DIR, CLAUDE_USAGE_JQ.

set -euo pipefail
umask 077

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
DATA_DIR="${CLAUDE_USAGE_DIR:-$HOME/Library/Application Support/ClaudeUsage}"
BIN_DIR="$DATA_DIR/bin"
INSTALLED_SCRIPT="$BIN_DIR/claude-usage-statusline.sh"
WRAPPED_FILE="$DATA_DIR/wrapped-command"
ORIGINAL_FILE="$DATA_DIR/original-statusline.json"
MARKER_FILE="$DATA_DIR/integration.json"

say()  { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

confirm() {
    local answer=""
    printf '%s [y/N] ' "$1"
    read -r answer || true
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- 1. Prerequisites --------------------------------------------------------

JQ="${CLAUDE_USAGE_JQ:-}"
if [ -z "$JQ" ]; then
    if [ -x /usr/bin/jq ]; then JQ=/usr/bin/jq; else JQ="$(command -v jq || true)"; fi
fi
[ -n "$JQ" ] && [ -x "$JQ" ] || fail "jq is required (macOS 15+ includes /usr/bin/jq; otherwise: brew install jq)."

if ! command -v claude >/dev/null 2>&1 && [ ! -d "$CONFIG_DIR" ]; then
    say "Claude Code does not appear to be installed (no 'claude' command and no $CONFIG_DIR)."
    confirm "Continue anyway?" || { say "Nothing changed."; exit 1; }
fi

SOURCE_SCRIPT=""
for candidate in "$SCRIPT_DIR/../Integration/claude-usage-statusline.sh" "$SCRIPT_DIR/claude-usage-statusline.sh"; do
    if [ -f "$candidate" ]; then SOURCE_SCRIPT="$candidate"; break; fi
done
[ -n "$SOURCE_SCRIPT" ] || fail "claude-usage-statusline.sh not found next to the installer."

# The command Claude Code will run. Quoted because the path contains a space.
NEW_COMMAND="\"$INSTALLED_SCRIPT\""

# --- 2. Read current settings ------------------------------------------------

# Follow a symlinked settings file (e.g. dotfiles) so the link is preserved.
SETTINGS_TARGET="$SETTINGS"
if [ -L "$SETTINGS" ]; then
    SETTINGS_TARGET="$(readlink -f "$SETTINGS")"
fi

if [ -f "$SETTINGS_TARGET" ]; then
    "$JQ" -e 'type == "object"' "$SETTINGS_TARGET" >/dev/null 2>&1 \
        || fail "$SETTINGS is not a valid JSON object. Fix it or configure manually (see README, 'Manual setup'). Nothing changed."
    CURRENT_JSON="$(cat "$SETTINGS_TARGET")"
    SETTINGS_EXISTS=1
else
    CURRENT_JSON='{}'
    SETTINGS_EXISTS=0
fi

EXISTING_TYPE="$(printf '%s' "$CURRENT_JSON" | "$JQ" -r '.statusLine.type // empty')"
EXISTING_COMMAND="$(printf '%s' "$CURRENT_JSON" | "$JQ" -r '.statusLine.command // empty')"

if [ "$EXISTING_COMMAND" = "$NEW_COMMAND" ]; then
    say "The Claude Usage integration is already installed in $SETTINGS."
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$BIN_DIR"
        install -m 700 "$SOURCE_SCRIPT" "$INSTALLED_SCRIPT"
        say "Updated the script at $INSTALLED_SCRIPT."
    fi
    exit 0
fi

if [ -n "$EXISTING_TYPE" ] && [ "$EXISTING_TYPE" != "command" ]; then
    fail "statusLine.type is \"$EXISTING_TYPE\", which this installer does not know how to wrap. Configure manually (README, 'Manual setup'). Nothing changed."
fi
if [ -z "$EXISTING_COMMAND" ] && printf '%s' "$CURRENT_JSON" | "$JQ" -e 'has("statusLine")' >/dev/null; then
    fail "statusLine exists but has no command. Configure manually (README, 'Manual setup'). Nothing changed."
fi

# --- 3. Proposed change -------------------------------------------------------

NEW_JSON="$(printf '%s' "$CURRENT_JSON" | "$JQ" --arg cmd "$NEW_COMMAND" \
    '.statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})')"
printf '%s' "$NEW_JSON" | "$JQ" -e 'type == "object"' >/dev/null || fail "Could not build valid settings JSON. Nothing changed."

say "Claude Usage integration installer"
say ""
say "Files that will be created or updated:"
say "  $INSTALLED_SCRIPT"
say "  $MARKER_FILE"
[ -n "$EXISTING_COMMAND" ] && say "  $WRAPPED_FILE   (your current status-line command, kept and still displayed)"
[ -n "$EXISTING_COMMAND" ] && say "  $ORIGINAL_FILE   (your current statusLine block, restored on uninstall)"
if [ "$SETTINGS_EXISTS" -eq 1 ]; then
    say "  $SETTINGS   (backup first: $SETTINGS.claude-usage-backup-<timestamp>)"
else
    say "  $SETTINGS   (new file)"
fi
say ""
say "Proposed change to $SETTINGS:"
diff -u <(printf '%s\n' "$CURRENT_JSON" | "$JQ" .) <(printf '%s\n' "$NEW_JSON" | "$JQ" .) \
    --label "current" --label "proposed" || true
say ""
if [ -n "$EXISTING_COMMAND" ]; then
    say "Your existing status line will keep working: Claude Usage records usage, then runs"
    say "  $EXISTING_COMMAND"
    say "with the same input and prints its output."
    say ""
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run: nothing changed."
    exit 0
fi

confirm "Apply this change?" || { say "Nothing changed."; exit 1; }

# --- 4. Apply -----------------------------------------------------------------

mkdir -p "$BIN_DIR"
chmod 700 "$DATA_DIR" "$BIN_DIR"
install -m 700 "$SOURCE_SCRIPT" "$INSTALLED_SCRIPT"

BACKUP=""
if [ "$SETTINGS_EXISTS" -eq 1 ]; then
    BACKUP="$SETTINGS_TARGET.claude-usage-backup-$(date +%Y%m%d-%H%M%S)"
    cp -p "$SETTINGS_TARGET" "$BACKUP"
    chmod 600 "$BACKUP"
    say "Backed up settings to $BACKUP"
fi

if [ -n "$EXISTING_COMMAND" ]; then
    printf '%s' "$EXISTING_COMMAND" > "$WRAPPED_FILE"
    printf '%s' "$CURRENT_JSON" | "$JQ" '.statusLine' > "$ORIGINAL_FILE"
    chmod 600 "$WRAPPED_FILE" "$ORIGINAL_FILE"
else
    rm -f "$WRAPPED_FILE" "$ORIGINAL_FILE"
fi

# Atomic replace, keeping the original file mode.
mkdir -p "$(dirname "$SETTINGS_TARGET")"
TMP_SETTINGS="$(mktemp "$(dirname "$SETTINGS_TARGET")/.settings.json.XXXXXX")"
trap 'rm -f "$TMP_SETTINGS"' EXIT
printf '%s\n' "$NEW_JSON" | "$JQ" . > "$TMP_SETTINGS"
"$JQ" -e --arg cmd "$NEW_COMMAND" '.statusLine.command == $cmd' "$TMP_SETTINGS" >/dev/null \
    || fail "Validation of the new settings failed. Nothing changed."
if [ "$SETTINGS_EXISTS" -eq 1 ]; then
    chmod "$(stat -f '%Lp' "$SETTINGS_TARGET")" "$TMP_SETTINGS"
else
    chmod 600 "$TMP_SETTINGS"
fi
mv -f "$TMP_SETTINGS" "$SETTINGS_TARGET"
trap - EXIT

"$JQ" -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg settings "$SETTINGS" --arg backup "$BACKUP" \
    --argjson wrapped "$([ -n "$EXISTING_COMMAND" ] && echo true || echo false)" \
    --argjson created "$([ "$SETTINGS_EXISTS" -eq 0 ] && echo true || echo false)" \
    '{schemaVersion: 1, installedAt: $at, settingsPath: $settings, backupPath: $backup,
      wrappedExistingStatusLine: $wrapped, createdSettingsFile: $created}' > "$MARKER_FILE"
chmod 600 "$MARKER_FILE"

say ""
say "Installed. Next steps:"
say "  1. Open the Claude Usage app → Settings → Grant Access… and select"
say "     $DATA_DIR"
say "  2. Start or resume a Claude Code session and send a message."
say "Uninstall any time with: $SCRIPT_DIR/uninstall-integration.sh"
