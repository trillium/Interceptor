# app_intent (Apple Events)

`interceptor macos intent dispatch` and `intent warmup` give an agent **cross-app verb dispatch** via Apple Events — the universal app-control channel that has been on macOS since 1991.

## Why Apple Events (not just Accessibility / CGEvent)

- **Structured.** "Play this track in Music" is a verb on a target with parameters — not a sequence of clicks.
- **Survives UI churn.** AX paths break when the app updates; Apple Events APIs change far less often.
- **TCC-aware.** macOS prompts for consent on first use per (interceptor-bridge, target_app) pair. Per-target grants are stored in the system TCC database.

## Three input shapes

### 1. Raw AppleScript (most flexible)

```bash
interceptor macos intent dispatch \
  --script 'tell application "Music" to play track "Bohemian Rhapsody"'
```

### 2. Structured (most ergonomic)

```bash
interceptor macos intent dispatch \
  --bundle com.apple.Music \
  --intent play \
  --args '["track","\"Bohemian Rhapsody\""]'
```

The bridge composes `tell application id "<bundleId>" to <intent> [<args>] [with properties <parameters>]`.

### 3. JXA (JavaScript for Automation, advanced)

```bash
interceptor macos intent dispatch \
  --javascript "Application('Music').playpause()"
```

All three return the same shape:
```json
{ "success": true, "result": <descriptor>, "raw": "<applescript-source-string>" }
```
where `<descriptor>` is the Foundation-bridged `NSAppleEventDescriptor` decoding (text / bool / int32 / double / list / record).

## TCC consent — the warmup pattern

The first time `interceptor-bridge` sends an Apple Event to an app, macOS pops a consent dialog:

> "interceptor-bridge.app" wants access to control "Music.app". Allowing control will provide access to documents and data in "Music.app", and to perform actions within that app.

Click **OK** once. macOS records the grant in the TCC database against the (bridge bundle id, target bundle id) pair. Subsequent dispatches against the same target are silent.

To pre-warm a batch of targets in one consent session:

```bash
interceptor macos intent warmup com.apple.Music com.apple.Notes com.apple.Mail
```

This issues one Apple Event per target on the bridge's main thread (required for `AEDeterminePermissionToAutomateTarget(askUserIfNeeded:true)` to render the dialog). Outcome map:

| Status | Meaning |
|---|---|
| `noErr` (0) | Granted |
| `-1743` | Denied (or user clicked "Don't Allow") |
| `-600` | Target app not running |
| other | `status_<n>` — opaque error |

## Why the bundle matters

`interceptor-bridge` ships as a real `.app` bundle (not a bare Mach-O binary) and registers itself with LaunchServices via `lsregister -f`. Without this, macOS TCC has nothing to track grants against — every dispatch would be a fresh consent prompt.

**Critical:** the first-run launch path **must** use `open -gj <bundle>`, not `Bun.spawn` of the inner binary. LaunchServices launching gives the process aqua-session ancestry; direct fork-exec does not, and macOS silently denies Apple Events without surfacing the consent UI in that case. The daemon's `spawnBridge()` helper does this automatically.

## Resetting consent

```bash
# Wipe all Apple Events grants for interceptor-bridge:
tccutil reset AppleEvents com.interceptor.bridge

# Re-prompt: just dispatch any intent to a target — macOS will pop the
# dialog again. Or run the warmup helper to batch:
interceptor macos intent warmup <bundleId>...
```

## Recipes

```bash
# Read selection from Notes
interceptor macos intent dispatch \
  --bundle com.apple.Notes \
  --intent "the selection of the front document"

# Tell Slack to mark a channel read
interceptor macos intent dispatch \
  --script 'tell application "Slack" to mark channel "general" as read'

# Tell Calendar to make an event
interceptor macos intent dispatch \
  --bundle com.apple.iCal \
  --intent "make new event" \
  --params '{"summary":"Standup","startDate":"date \"Monday at 9 AM\""}'
```

## When NOT to use app_intent

- Apps that explicitly block Apple Events (some Sandboxed App-Store apps).
- Apps with no AppleScript dictionary — `osascript` returns `error -1708` ("not understood"). Use Accessibility (`interceptor macos {tree, click, ...}`) instead.
- Web apps in a browser — use the Interceptor browser surface, not the macOS bridge.
