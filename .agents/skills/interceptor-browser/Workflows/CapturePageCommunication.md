# CapturePageCommunication

You are capturing page communication that does not show up as ordinary
fetch/XHR traffic. Use this workflow for:
- WebSocket lifecycle and payload previews
- `navigator.sendBeacon(...)` calls
- `BroadcastChannel` open/send/receive/close activity
- Monitor recordings that must preserve WebSocket/Beacon/BroadcastChannel rows

Use this before reaching for CDP. P1 page communication capture is passive,
page-world instrumentation; it does not attach the Chrome debugger and does not
show the DevTools infobar.

## Command Budget

Attach-now capture should complete in **4 commands**:
1. `interceptor net monitor on` -> arm and inject current-page wrappers
2. Trigger the page action -> click/type/navigate/user action
3. `interceptor net page-comm log --limit 50` -> inspect captured rows
4. `interceptor net monitor off` -> disable dynamic registration when done

From-start capture should complete in **5 commands**:
1. `interceptor net monitor on --reload` -> arm before the page starts
2. Wait for startup or trigger the flow
3. `interceptor net page-comm log --limit 100`
4. Optional narrow read: `interceptor net page-comm log --type ws --filter socket`
5. `interceptor net monitor off`

## Pick The Capture Mode

Use **attach-now** when the page is already loaded and you only care about
future activity:

```bash
interceptor net monitor on
# trigger the page behavior
interceptor net page-comm log --limit 50
interceptor net monitor off
```

Attach-now captures new WebSocket instances, future Beacon sends, and future
BroadcastChannel messages. It does not reconstruct WebSocket instances or
messages that happened before the wrapper was injected.

Use **from-start** when the socket/channel is created during page startup:

```bash
interceptor net monitor on --reload
# page reloads; let startup run or perform the flow
interceptor net page-comm log --type ws --limit 100
interceptor net monitor off
```

`--reload` is the operator-safe path for startup WebSockets because the MAIN
world wrapper is armed before the new document runs page scripts.

## Read The Log

Use type filters when you know the protocol family:

```bash
interceptor net page-comm log --type ws
interceptor net page-comm log --type beacon
interceptor net page-comm log --type broadcast
```

Use `--filter` to narrow by WebSocket/Beacon URL, BroadcastChannel name, or
event name:

```bash
interceptor net page-comm log --type ws --filter "/socket" --limit 20
interceptor net page-comm log --type broadcast --filter "room"
```

Important row meanings:
- `ws_opening`, `ws_open`, `ws_send`, `ws_message`, `ws_error`, `ws_close`
- `beacon`, `beacon_error`
- `broadcast_open`, `broadcast_send`, `broadcast_message`, `broadcast_error`, `broadcast_close`

Payloads are previews. Text and JSON-like values are capped; binary data is
represented as base64 preview with byte counts.

## Record With Monitor

Use monitor capture when the user is demonstrating a workflow and page
communication needs to survive export:

```bash
interceptor monitor start --capture page-comm --reload --instruction "Watch the login socket handshake"
# user performs the flow
interceptor monitor stop
interceptor monitor export <session-id> --format json
interceptor monitor export <session-id> --plan
```

Use `--reload` when the target flow opens sockets during startup. Without it,
monitor page-comm capture is attach-now and only captures future instances.

## Failure Reflexes

- Empty log after a startup flow -> rerun with `net monitor on --reload`.
- Empty log after attach-now -> confirm the action actually created a new
  WebSocket/Beacon/BroadcastChannel after arming.
- Missing fetch/XHR -> use `interceptor net log`, not `page-comm`.
- Missing SSE -> use `interceptor sse log`; SSE is its own surface.
- Need raw HTTP response bodies -> use `net log --format json|har` or monitor
  `--persist-bodies`; Beacon has no response body by design.
- Need raw network bytes or protocol-level frames below JavaScript APIs -> CDP
  or an external proxy is a different task.

## Output Format

Report:
- Capture mode used: attach-now or from-start
- Protocol family: ws, beacon, broadcast, or mixed
- Matching events found, with URL/channel and event names
- Payload preview and byte count when relevant
- Any limitation that affects the conclusion, especially pre-existing sockets

Mechanics and limits are in
[`../references/page-communication-capture.md`](../references/page-communication-capture.md).
