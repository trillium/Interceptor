# JSC Host Reference

Use `interceptor macos script run --jsc` for plain JavaScriptCore inside the bridge. This is not JXA: there is no `Application(...)`, no Objective-C bridge, and no target app context unless you explicitly call host APIs.

## Command Shape

```bash
interceptor macos script run --jsc '<javascript-core>'
interceptor macos script run --jsc 'run = argv => argv.join("|")' --args '["a","b"]'
interceptor macos script run --jsc 'host.sqlite("/tmp/example.sqlite", "select 1")' --jsc-host sqlite
```

Host access is opt-in. Prefer the narrowest capability set:

| Capability | APIs |
|---|---|
| `sqlite` | `host.sqlite(path, sql)` |
| `shell` | `host.shell(executable, args)`, `host.sh(command)` |
| `fs` | `host.exists`, `host.readText`, `host.readBase64`, `host.writeText`, `host.list`, `host.stat` |
| `osa` | `host.appleScript(source)`, `host.jxa(source, args)` |
| `env` | `host.env(name)`, `host.home()`, `host.expandPath(path)` |
| `all` | Every host API |

`--jsc-unsafe-native` is an alias for `--jsc-host all`. Use it only when the user explicitly asks for broad native access.

## Rules

- Use `--jxa` for app automation through Apple Events and `Application(...)`.
- Use `--jsc` for plain ECMAScript execution, local data inspection, and host-backed utilities.
- Never add host capabilities speculatively. If a snippet needs SQLite only, pass `--jsc-host sqlite`.
- For private local data, only run host-backed reads when the user explicitly asks for that data.
- Do not foreground an app just to inspect its local data. JSC host reads run through the bridge and do not activate the source app.
- Surface TCC and file permission errors as-is. Do not silently fall back to broader caps or unrelated locations.

## Return Values

The bridge serializes normal JavaScript values. Return a plain object or array when another tool or script will consume the result.

```javascript
const rows = host.sqlite("/tmp/example.sqlite", "select count(*) as count from sqlite_schema");
rows[0];
```

For CLI consumption, use `--json` when the caller needs the envelope. For agent-readable output, the default plain-text output is usually better.

## Common Pitfalls

- `--bundle` does not apply to `--jsc`; JSC runs in the bridge, not in a target application.
- JSC host SQLite returns database values as serialized bridge values; BLOBs from `sqlite3 -json` arrive as strings containing decoded bytes, so process character codes instead of assuming browser base64 helpers.
- SQLite rows are returned as JSON-compatible bridge values. Validate schema names first when querying an unknown database.
- `shell` is powerful. Use it for narrow discovery work such as finding Contacts databases, then switch back to `sqlite` when possible.
