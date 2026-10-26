# Claude Usage

A native macOS menu-bar app and WidgetKit widget that show your **Claude Code subscription
usage limits**: the current 5-hour session and the 7-day weekly limit, each with its own reset
time, a countdown, and a freshness indicator.

Values come only from Claude Code itself. Nothing is estimated, and nothing leaves your Mac
unless you opt in to the usage API.

_Screenshots: to be added._

## Features

- **Menu-bar app** showing session, weekly and spend limits, with reset countdowns.
- **Desktop widgets** in small, medium and large sizes.
- **No estimates:** missing limits show "Not available from this data source", never 0%.
- **Freshness:** "Updated" is the time Claude Code observed the data. Data older than
  15 minutes is marked **Stale**.
- **Keeps your status line:** an existing Claude Code status line is wrapped, and its output
  stays the same.
- **Optional usage API** that also covers Claude in Xcode and claude.ai.
- **Private:** the app is sandboxed, has no analytics, and writes files with owner-only
  permissions.

## Requirements

| Item | Requirement |
| --- | --- |
| macOS | 27.0 or later |
| Xcode | 27.2 or later |
| Claude Code | A version whose status-line input includes `rate_limits` (verified with 2.1.309) |
| Account | A Claude Pro or Max subscription. Claude Code reports usage limits only to subscribers. |
| Tools | `bash` and `jq` (`/usr/bin/jq` ships with macOS 15 and later) |
| Signing | An Apple Developer team that can sign apps using an App Group |

## Getting started

### 1. Clone

```sh
git clone <repository-url>
cd ClaudeUsageWidget
```

### 2. Configure your identifiers

Bundle IDs, the signing team and the App Group are not stored in the project. They are
defined in build configuration files:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Then edit `Config/Local.xcconfig`:

```xcconfig
BUNDLE_ID_PREFIX = com.yourname
DEVELOPMENT_TEAM = ABCDE12345
```

`Config/Local.xcconfig` is git-ignored. Without it, the build uses the placeholder values in
`Config/Base.xcconfig` (`com.example`, no team) and cannot be signed. See
[Configuration](#configuration).

### 3. Build and run

1. Open `ClaudeUsageWidget.xcodeproj` in Xcode.
2. Select the **ClaudeUsageWidget** scheme and run it (⌘R).

The app appears in the menu bar. It has no Dock icon.

### 4. Connect Claude Code

1. **Install the status-line integration.** Open the menu-bar item, choose *Open Setup
   Guide*, and copy the installer command. You can also run it from the repository:

   ```sh
   Scripts/install-integration.sh            # add --dry-run to preview without changes
   ```

2. **Grant folder access.** In the app, choose *Settings… → Folder access → Grant Access…*
   and select `~/Library/Application Support/ClaudeUsage`.
3. **Send a message** in Claude Code. Usage arrives after the first response in a session.
4. **Add the widget.** Right-click the desktop, choose *Edit Widgets…*, and search for
   "Claude Usage".

## Configuration

### Identifiers

Every identifier is derived from two values in `Config/Local.xcconfig`:

| Setting | Default (`Base.xcconfig`) | Used for |
| --- | --- | --- |
| `BUNDLE_ID_PREFIX` | `com.example` | All bundle IDs, such as `$(BUNDLE_ID_PREFIX).ClaudeUsageWidget` |
| `DEVELOPMENT_TEAM` | (empty) | Code signing for all targets |
| `APP_GROUP_IDENTIFIER` | `group.$(BUNDLE_ID_PREFIX).ClaudeUsage` | Storage shared by the app and the widget |

Build settings, Info.plist files and `.entitlements` files reference these values as `$(VAR)`.
At runtime the app and the widget read the App Group from the `ClaudeUsageAppGroupIdentifier`
Info.plist key (`SharedPaths.appGroupIdentifier`). Changing `BUNDLE_ID_PREFIX` or
`APP_GROUP_IDENTIFIER` moves the shared data to a new App Group container.

### Optional: Claude usage API

Claude in Xcode runs Claude Code through the Agent SDK, which never runs the status line.
Without the usage API, usage from Xcode appears only when a terminal session next gets a
response. To follow usage from every client, turn on **Settings → Claude usage API → Fetch
usage from Anthropic**.

- The app reads your Claude Code login token from the Keychain. macOS asks once; choose
  *Always Allow*.
- It calls `https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's
  `/usage`. This endpoint is **unofficial** and may change or break without notice.
- It checks every 5 minutes, never more than once a minute automatically, and waits
  15 minutes after a rate-limit response. *Refresh Now* checks immediately.
- It also reports model-specific weekly limits (Sonnet and Opus) when the account has them.
- The token stays in memory and is sent only to `api.anthropic.com`; redirects are refused.
  It is never stored, refreshed, logged or included in diagnostics.
- If the call fails, the app uses the status-line data instead.

## Supported limits

The data source is the **Claude Code status line**. Its fields follow the
[official status-line documentation](https://code.claude.com/docs/en/statusline).

| Limit | Shown | Source field | Reset time |
| --- | --- | --- | --- |
| Current session (5-hour) | ✅ when reported | `rate_limits.five_hour.used_percentage` | ✅ `rate_limits.five_hour.resets_at` |
| Weekly (7-day) | ✅ when reported | `rate_limits.seven_day.used_percentage` | ✅ `rate_limits.seven_day.resets_at` |
| Spend limit (Claude apps gateway only) | ✅ when reported (may exceed 100%) | `rate_limits.spend_limit.used_percentage` | ✅ `rate_limits.spend_limit.resets_at` |
| Model-specific weekly limits (Sonnet/Opus) | Usage API only | — | — |
| Extra usage status | ❌ not exposed | — | — |

Claude Code sends `rate_limits` only after the first response in a session. Each window can
be missing on its own, and Claude Code drops a window once its reset time passes.
Context-window percentages (`context_window.*`) are not subscription usage and are never used.

## Uninstall

```sh
Scripts/uninstall-integration.sh        # or --keep-data / --delete-data
```

The uninstaller backs up `settings.json`, shows a diff, and asks before restoring your previous
`statusLine`, or removing it if you had none. If the status line changed since installation,
it leaves the settings untouched. It removes the script and install records, and asks whether
to delete the local usage snapshot (the default is to keep it). Settings backups are kept.

Then quit Claude Usage from its menu and move the app to the Trash. Nothing runs in the
background, and no launch agents are installed. To remove the widget's shared data, delete
`~/Library/Group Containers/<APP_GROUP_IDENTIFIER>`.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Build fails with a signing error | Create `Config/Local.xcconfig` with your `BUNDLE_ID_PREFIX` and `DEVELOPMENT_TEAM`. |
| "Folder access needed" | Choose Settings → Grant Access… and select `~/Library/Application Support/ClaudeUsage`. If the folder does not exist, run the installer first. |
| "Integration not installed" | Run `Scripts/install-integration.sh`. |
| "No data yet" | Open Claude Code and send a message. Usage arrives after the first response. |
| "Usage not provided" | Claude Code ran the script but sent no `rate_limits`. Either you are not on a Pro or Max plan, or no response has completed yet. |
| "Usage data could not be read" / "Unsupported data format" | The file is malformed or from a newer version, and the last valid snapshot is kept. Reinstall the integration. |
| "Claude login expired" (usage API) | Send a message in Claude Code or Claude in Xcode. That renews the token, and the app uses it on the next check. |
| "Keychain access denied" (usage API) | Choose *Refresh Now* and click *Always Allow*. Debug builds signed differently may ask again after rebuilding. |
| "Usage service error" (usage API) | The unofficial endpoint changed or failed. The app uses the status-line data meanwhile. |
| "Shared storage unavailable" | The app and the widget do not share an App Group. Check `APP_GROUP_IDENTIFIER` and both targets' signing. |
| Widget empty while the app shows data | Make sure the app has run once since the last update; WidgetKit may delay reloads. If needed, remove and re-add the widget. |
| Status line looks different | Check that `~/Library/Application Support/ClaudeUsage/wrapped-command` contains your original command. |

*Settings → Copy Diagnostics* copies a sanitized report: provider, file status, timestamps,
validated percentages and error categories. It contains no payloads, prompts, paths or tokens.
## Known limitations

- Subscription usage is available only to Claude Pro and Max subscribers, and only while
  Claude Code runs and receives responses.
- The status line does not expose model-specific weekly limits or extra-usage status. The
  usage API reports model-specific weekly limits; extra usage is not shown.
- Without the usage API, usage from Claude in Xcode appears only once a terminal Claude Code
  session receives a response.
- Each concurrent Claude Code session writes the file. The app keeps the newest observation and
  never lets an older one overwrite newer data.
- macOS controls when widgets refresh.
- Warning (70%) and critical (90%) colors are display conventions, not Claude-defined
  thresholds.
- Because the app keeps the App Sandbox, it needs a one-time folder-access grant.
- The usage API relies on an undocumented endpoint and may stop working.
