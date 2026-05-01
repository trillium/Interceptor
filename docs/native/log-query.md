# log_query — `OSLogStore`

`interceptor macos log query` queries the Unified Logging system via `OSLogStore` + `OSLogEnumerator` (macOS 12+). Returns structured entries with `timestamp`, `subsystem`, `category`, `message`, `level`, `process`.

## Quick examples

```bash
interceptor macos log query --subsystem com.apple.WindowServer --since "5m ago"
interceptor macos log query --predicate "subsystem == 'com.apple.WindowServer' AND category == 'render'"
interceptor macos log query --include-debug --limit 500
```

## Flags

| Flag | Effect |
|---|---|
| `--subsystem <s>` | Filter by subsystem (`com.apple.<...>`) |
| `--category <c>` | Filter by category |
| `--predicate "<pred>"` | Raw NSPredicate. Overrides --subsystem/--category. |
| `--since <ISO\|relative>` | Earliest entry. ISO 8601 or e.g. `5m ago`, `1h ago`. Default: 5 min ago. |
| `--limit N` | Max entries (default 100) |
| `--include-info` | Include level=info entries (default: skip) |
| `--include-debug` | Include level=debug entries (default: skip) |

## Predicate cookbook

```bash
# Errors only, last 10 minutes
interceptor macos log query --predicate "messageType == 16" --since "10m ago"

# Specific process by PID
interceptor macos log query --predicate "processIdentifier == 1234"

# Multiple subsystems
interceptor macos log query --predicate "subsystem IN {'com.apple.network', 'com.apple.WindowServer'}"

# Message regex (case-insensitive contains)
interceptor macos log query --predicate "message CONTAINS[c] 'connection'"
```

## Permissions

`OSLogStore.local()` requires either `com.apple.private.logging.diagnostic` (private entitlement, not available to third parties) or running as the same user that owns the log entries. The bridge runs as the user, so user-scope queries work without entitlement. System-scope (`scope: .system`) is restricted.
