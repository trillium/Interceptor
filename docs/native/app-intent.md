# Apple Events and OSA scripts

`interceptor macos script run` executes raw OSA scripts through AppleScript or JXA, and can also run plain JavaScript inside the bridge through JavaScriptCore. `interceptor macos intent dispatch` remains the compatibility and structured-dispatch surface for Apple Events — the universal app-control channel that has been on macOS since 1991.

This surface is different from Apple's App Intents framework. App Intents declare predefined actions for Shortcuts, Siri, Spotlight, widgets, and controls. OSA/JXA runs script source and can address scriptable apps through Apple Events. JavaScriptCore runs ECMAScript in `interceptor-bridge` itself and does not provide JXA's `Application(...)` automation host.

## Why Apple Events (not just Accessibility / CGEvent)

- **Structured.** "Play this track in Music" is a verb on a target with parameters — not a sequence of clicks.
- **Survives UI churn.** AX paths break when the app updates; Apple Events APIs change far less often.
- **TCC-aware.** macOS prompts for consent on first use per (interceptor-bridge, target_app) pair. Per-target grants are stored in the system TCC database.

## Four input shapes

### 1. Raw AppleScript (most flexible)

```bash
interceptor macos script run \
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
interceptor macos script run \
  --jxa "Application('Music').playpause()"
```

For scripts that define a JXA run handler, pass argv-style strings with
`--args`:

```bash
interceptor macos script run \
  --jxa "run = argv => argv.join('|')" \
  --args '["alpha","beta"]'
```

When `--bundle <id>` is provided with `--jxa`, the bridge prepends a
JXA binding named `target`:

```bash
interceptor macos script run \
  --bundle com.apple.Music \
  --jxa "target.playpause()"
```

The bridge does not call `activate()` for JXA. The target app comes forward only
if the script itself asks for that. `interceptor macos intent dispatch
--jxa ...` still works for callers that use `intent dispatch` as their script
entrypoint. The deprecated `--javascript` flag is accepted as an alias for
`--jxa`, but new docs and agents should use the explicit `--jxa` spelling.

### 4. JavaScriptCore (plain ECMAScript inside the bridge)

```bash
interceptor macos script run \
  --jsc "Math.max(1, 2, 3)"
```

For scripts that define a `run` function, pass argv-style strings with
`--args`:

```bash
interceptor macos script run \
  --jsc "run = argv => argv.join('|')" \
  --args '["alpha","beta"]'
```

`--jsc` creates a `JSContext` in `interceptor-bridge`, exposes `argv` as a
global array, evaluates the source, and calls `run(argv)` when `--args` is
present and `run` exists. It serializes JavaScript scalars, arrays, objects, and
dates into the response payload. It rejects `--bundle` because JavaScriptCore is
not JXA and does not expose `Application(...)` or send Apple Events by itself.

When a script needs native host capabilities, opt in with `--jsc-host`. The
flag injects `host` and `Interceptor` globals. `--jsc-host` with no value means
`all`; a comma-separated value narrows exposure:

```bash
interceptor macos script run \
  --jsc "host.sqlite('/tmp/example.sqlite', 'select 1')" \
  --jsc-host sqlite

interceptor macos script run \
  --jsc "host.sh('pwd').stdout" \
  --jsc-host shell
```

Capabilities:

| Capability | Host API |
|---|---|
| `env` | `host.home()`, `host.env(name)`, `host.expandPath(path)` |
| `fs` | `host.exists(path)`, `host.readText(path)`, `host.readBase64(path)`, `host.writeText(path, contents)`, `host.list(path)`, `host.stat(path)` |
| `sqlite` | `host.sqlite(path, sql)` using `/usr/bin/sqlite3 -readonly -json` |
| `shell` | `host.shell(executable, args)`, `host.sh(command)` |
| `osa` | `host.appleScript(source)`, `host.jxa(source, args)` |

`--jsc-unsafe-native` is an alias for `--jsc-host all`. Keep pure `--jsc` for
untrusted snippets; host mode executes with the bridge process' local privileges
and macOS TCC grants.

Script routes return this shape:
```json
{ "success": true, "data": { "result": <value>, "raw": "<string>", "script": "<source-string>" } }
```
For AppleScript and JXA, `<value>` is the Foundation-bridged `NSAppleEventDescriptor` decoding (text / bool / int32 / double / list / record). For JavaScriptCore, `<value>` is the sanitized `JSValue` result.

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

## When NOT to use OSA / Apple Events

- Apps that explicitly block Apple Events (some Sandboxed App-Store apps).
- Apps with no AppleScript dictionary — `osascript` returns `error -1708` ("not understood"). Use Accessibility (`interceptor macos {tree, click, ...}`) instead.
- Web apps in a browser — use the Interceptor browser surface, not the macOS bridge.
- Plain JavaScript computation that does not need Apple Events — use `--jsc`, not JXA.
