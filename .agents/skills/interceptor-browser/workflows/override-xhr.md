# OverrideXhr

You are mutating an HTTP request before it hits the server, or rewriting a response before the page sees it. Use this workflow when:
- The page does the right thing, but you need to test what happens when the API returns 500 / 404 / slow
- You need to change request parameters without rebuilding the UI
- You need to inject test data the backend can't produce

## Command Budget

This workflow should complete in **5 commands**:
1. `interceptor net log --filter <pattern>` (observe real traffic first; don't override blind) → 1 command
2. `interceptor override "<pattern>" status=...` (install the override) → 1 command
3. Trigger the request (`act`, `click`, `type`, or `navigate`) → 1 command
4. `interceptor net log --filter <pattern> --since 30s` (verify the override fired — **NOT** a fresh `read`; the response data lives in the network log, not the DOM) → 1 command
5. `interceptor override clear` (always clear; overrides persist across `open` calls and poison subsequent tasks) → 1 command

If verification at step 4 shows the override didn't fire, the pattern probably missed — refine the pattern and retry steps 2-4 once. Do not reach for a fresh `read` to "check the page" before confirming the network override fired.

## Steps

1. **Open the page.**
   ```bash
   interceptor open <url>
   ```

2. **Observe the real traffic first.** Don't override blind.
   ```bash
   interceptor net log --filter <pattern>           # See what's flying
   interceptor net headers --filter <pattern>       # Confirm exact URL shape
   ```
   Pick a unique substring of the URL — that's your override key.

3. **Install the override.**
   ```bash
   interceptor override "*api/search*" status=500           # Force a status
   interceptor override "*api/search*" delay=1000           # Add latency
   interceptor override "*api/search*" status=200 body='{"results":[]}'   # Custom response
   interceptor override "*api/items*" params=count:5        # Mutate query param
   ```

4. **Trigger the request** — click, type, navigate, whatever causes the page to make the call.

5. **Verify the override fired.**
   ```bash
   interceptor net log --filter <pattern> --since 30s
   ```
   The response should match what you forced. If it doesn't, your pattern probably missed.

6. **Clear when done.** Overrides persist until cleared and can poison subsequent tasks.
   ```bash
   interceptor override clear
   ```

## When to use CDP `network` instead

`interceptor override` uses the extension's declarativeNetRequest path — no debugger banner, no DevTools UI fingerprint. Reach for `interceptor network on` + `interceptor network override` only when:
- You need request-body rewriting (extension overrides are URL/header-only for some sites)
- You need to observe raw bytes pre-decode

CDP attach shows a "DevTools is debugging this tab" banner. Pages that watch for it will behave differently. Default to extension overrides.

For WebSocket, Beacon, or BroadcastChannel observation, use
`interceptor net page-comm log` or
[`capture-page-communication.md`](capture-page-communication.md) before CDP.

## Pitfalls

- **Pattern too broad.** `*` alone overrides everything including your own extension traffic — pages can hang. Use a substring that uniquely identifies the request.
- **Forgetting `override clear`.** Override rules survive across `open` calls until explicitly cleared. A test that "passed last run" may be reading a stale override.
- **Override + cache.** Browsers cache. If you override `GET /api/foo` but the page reads from a `Cache-Control: max-age` response, the override doesn't fire. Reload with `--no-cache` semantics by passing `?cb=<timestamp>` or use `interceptor navigate` instead of an in-page click.

## Output format

Report:
- The override key used (URL pattern + what was changed)
- The observed response after triggering
- Whether the page's behavior matched expectations under the forced state
- Whether `override clear` was called at the end
