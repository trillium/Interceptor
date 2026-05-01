# container_run — Apple's container runtime

`interceptor macos container run <image> --cmd "..."` runs an OCI image inside Apple's `container` runtime (macOS 26+). Sandboxed Linux escape hatch with mounts, env, network policy, and a bounded timeout. Pipe-drain hardening ensures large stdout/stderr (>16-64 KB) never deadlocks.

## Quick examples

```bash
interceptor macos container run docker.io/library/alpine:3 --cmd "echo hello"
interceptor macos container run docker.io/library/python:3.12 \
  --cmd "python -c 'import json; print(json.dumps({\"ok\": True}))'" \
  --network off

interceptor macos container run my-image \
  --env KEY=val --env DEBUG=1 \
  --volume "/Users/me/data:/data:ro" \
  --network isolated \
  --timeout 30000
```

Returns: `{ exitCode, stdout, stderr, durationMs, image, command, network }`.

## Network modes

| `--network` | container CLI mapping | Use |
|---|---|---|
| `off` (default) | `--network none` | No outbound traffic. Best for build/test. |
| `isolated` | `--network default` | Container's own NAT; can reach the internet but not the host. |
| `host` | `--network host` | Shares the host's network stack. Use with care. |

## Volume mounts

`--volume host:container[:mode]` accepts `ro` (default) or `rw`. The host path is `expandingTildeInPath`-resolved, so `~/Documents/x:/x` works. Multiple `--volume` flags are allowed.

## Resolving the binary

The bridge searches in order, with the first match winning:

1. `INTERCEPTOR_CONTAINER_BIN` (env override; full path)
2. `/opt/homebrew/bin/container` (Apple silicon Homebrew, default)
3. `/usr/local/bin/container` (Intel / direct .pkg)
4. `/Applications/container.app/Contents/MacOS/container` (future GUI)

If none are found, the call returns:

```
container_run: Apple's `container` runtime not found. Searched: <paths>.
Install via `brew install container` (macOS 26+ required), then `container system start`.
```

## Pipe-drain hardening

A naive `Foundation.Process` driver typically uses the documented Foundation/Pipe deadlock pattern:

```swift
task.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()  // ← deadlocks if child wrote >pipe buffer
```

The current implementation:

- Installs `readabilityHandler` on stdout and stderr **before** `task.run()` and accumulates each chunk into an `NSLock`-guarded `LockedData`.
- Resolves the response from `task.terminationHandler` (final drain on `availableData`, then clear handler, then complete via an `AtomicFlag` one-shot latch).
- SIGTERM at `--timeout`, SIGKILL +2s grace if the child ignores SIGTERM. Both timers owned by an `@unchecked Sendable` `TimerHolder` that the termination handler can `cancelAll()` safely.

Acceptance criteria are codified in `Tests/InterceptorBridgeTests/ContainerDomainTests.swift`.
