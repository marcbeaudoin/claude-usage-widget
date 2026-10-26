# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A sandboxed macOS 27+ menu-bar app (`ClaudeUsageWidget`) plus a WidgetKit extension (`ClaudeUsageWidgetsExtension`) that display Claude Code subscription usage limits (5-hour session, 7-day weekly, optional spend / model-specific limits) and their reset times. `README.md` holds the user-facing docs and is the reference for behavior, file formats, and troubleshooting. Some code comments still cite `FR-n` / `SPEC.md §n` from a spec that has since been removed.

## Commands

```sh
# Build / unit + end-to-end tests (Swift Testing). Prefer the xcode-tools MCP BuildProject / RunAllTests / RunSomeTests.
xcodebuild test -project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageWidget -destination 'platform=macOS'

# Single test
xcodebuild test -project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageWidget -destination 'platform=macOS' \
  -only-testing:ClaudeUsageWidgetTests/EndToEndTests/scriptOutputFlowsToWidgetModel\(\)

# Shell tests for the status-line script, installer, uninstaller (temporary HOME; never touches real ~/.claude)
Tests/integration/test-integration.sh
```

The Xcode project uses the new JSON `project.xcproj` format (not `project.pbxproj`) with folder-based target membership. New files under a target folder are picked up automatically.

## Architecture

Data flow (the README has a diagram):

1. **`Integration/claude-usage-statusline.sh`** runs as the Claude Code status line. It extracts only `rate_limits`, validates them, and atomically writes `usage.json` (schema v1), `status.json` (heartbeat), and reads `integration.json` (install marker) in `~/Library/Application Support/ClaudeUsage/`. It then pipes stdin to the user's previous status-line command (`wrapped-command`) so that output stays unchanged.
2. **App** (`ClaudeUsageWidget/App/`): `UsageRefreshCoordinator` (`@MainActor @Observable`) is the central owner of state. It watches the integration folder through a security-scoped bookmark (`IntegrationFolderAccess`), debounces events by 1 s, re-reads on wake or manual refresh, and falls back to a 5-minute poll only when watching fails. If the user opts in, `UsageAPIProvider` (an actor) becomes the primary source. It reads the Claude Code OAuth token from the Keychain and calls the unofficial `api.anthropic.com/api/oauth/usage`. If that fails, the coordinator falls back to the status-line file.
3. **`Shared/`** is compiled into *both* the app and the widget:
   - `UsageProvider` protocol (`fetchUsage() async throws(UsageProviderError)`), with `StatusLineFileProvider` as the default implementation.
   - `UsageSnapshotParser` performs strict schema-v1 validation. Any violation rejects the whole file.
   - `UsageSync` runs provider → `SnapshotMergePolicy` → `UsageStore`. It writes only validated, *newer* snapshots (by `observedAt`), so a failed or older read never erases known-good data.
   - `UsageStore` stores the snapshot in the App Group container (`SharedPaths.appGroupIdentifier`), written with `AtomicFileWriter`.
   - `WidgetTimelinePlanner` and `UsageFormatting` handle timeline entries (every 15 min, at reset times, at the stale threshold) and display strings.
4. **Widget** (`ClaudeUsageWidgets/`) only reads the App Group store and makes no network requests. The app requests reloads through WidgetKit after an update.

`Scripts/install-integration.sh` and `uninstall-integration.sh` edit only `statusLine` in `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`). They back the file up first, show a diff, and ask before writing. They are also bundled into the app's Resources.

## Conventions and invariants

- Build settings: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. Types in `Shared/` and parsers/models must be marked `nonisolated` (and `Sendable`) so they can be used from the widget and from background contexts.
- Errors use typed throws with `UsageProviderError`. Each case maps to a user-facing troubleshooting message (see the README table).
- Never fabricate data. Missing limits show "Not available from this data source" (never 0%). Passed reset times show "awaiting updated data". "Updated" always means `snapshot.observedAt`, never the time the app last read the file. Data older than 15 min is stale.
- `context_window.*` is not subscription usage and must never be used.
- Privacy: nothing leaves the Mac except the opt-in usage API call. Tokens are kept in memory only, redirects are refused, and tokens are never logged, stored, or included in `DiagnosticsReport`. Files use `0700`/`0600` permissions.
- When changing the snapshot schema, keep the shell script, `UsageSnapshotParser`, `ClaudeUsageWidgetTests/Fixtures/normalized-snapshot.json`, `Integration/fixtures/statusline-payload.sample.json`, and the README format section in sync. Both the Swift end-to-end tests and the shell tests use these fixtures.
- Identifiers live in `Config/Base.xcconfig` (placeholders), overridden by the git-ignored `Config/Local.xcconfig` (see `Local.xcconfig.example`). Never hard-code a team ID, bundle ID, or App Group. `APP_GROUP_IDENTIFIER` is expanded into both `.entitlements` files and both Info.plists (`ClaudeUsageAppGroupIdentifier`), and `SharedPaths` reads it at runtime.
