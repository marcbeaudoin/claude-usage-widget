# Claude Code status-line integration

`claude-usage-statusline.sh` is the bridge between Claude Code and the Claude Usage app.

## Input contract (verified)

Verified against the official documentation
(<https://code.claude.com/docs/en/statusline>) for Claude Code **2.1.309** on 2026-10-24.
Claude Code runs the configured `statusLine.command` and writes a JSON object to its
standard input. The only fields this script reads are:

| Field | Type | Meaning |
| --- | --- | --- |
| `rate_limits.five_hour.used_percentage` | number, 0–100 | Share of the rolling 5-hour session limit used |
| `rate_limits.five_hour.resets_at` | Unix epoch seconds | When that window resets |
| `rate_limits.seven_day.used_percentage` | number, 0–100 | Share of the 7-day limit used |
| `rate_limits.seven_day.resets_at` | Unix epoch seconds | When that window resets |
| `rate_limits.spend_limit.used_percentage` | number, may exceed 100 | Claude apps gateway spend limit only |
| `rate_limits.spend_limit.resets_at` | Unix epoch seconds | When the spend period resets |
| `version` | string | Claude Code version (heartbeat/diagnostics only) |

Documented availability rules, which the app reflects as "Not available from this data source":

- `rate_limits` is present only for **Claude Pro and Max subscribers** (or behind a gateway
  that sets a spend limit), and only **after the first API response** in a session.
- Each window may be independently absent.
- Claude Code **drops a window once its `resets_at` time passes**.
- No model-specific (e.g. Sonnet/Opus) weekly windows and no "extra usage" status are exposed.

`context_window.*` describes the conversation's context usage, not subscription usage; it
is never read.

## Output

Written to `~/Library/Application Support/ClaudeUsage/` (directory `0700`, files `0600`):

| File | Written when | Content |
| --- | --- | --- |
| `usage.json` | The payload has at least one valid window | Snapshot, schema version 1 (see main README) |
| `status.json` | Every run | `invokedAt`, `result` (`written`, `noRateLimits`, `invalidInput`, `writeFailed`), script and Claude Code version |

Both are written atomically (temp file in the same directory, then `rename`). If the payload
is not JSON or has no valid window, `usage.json` is left untouched.

Validation: a window is "reported" only if `used_percentage` is a number ≥ 0 and ≤ 100
(the spend limit may exceed 100). `resets_at` is used only if it is a positive number of
seconds (values that look like milliseconds are dropped rather than misread).

## Display

If `wrapped-command` exists in the same directory, the script pipes the identical input to
that command with `/bin/sh -c` and prints its output, so a pre-existing status line keeps
working unchanged. Otherwise it prints e.g. `Claude usage: 5h 24% · 7d 41%`.

## Testing manually

```sh
CLAUDE_USAGE_DIR=/tmp/cu bash Integration/claude-usage-statusline.sh \
  < Integration/fixtures/statusline-payload.sample.json
cat /tmp/cu/usage.json
```

`fixtures/statusline-payload.sample.json` is **synthetic test data** following the documented schema.
