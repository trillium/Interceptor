---
name: interceptor-browser
description: Use when the agent should drive a real signed-in browser session via the `interceptor` CLI — read pages, click, type, navigate, observe passive network traffic, automate rich editors (Canva / Google Docs / Slides), record and replay user flows. Prefer compound commands and structured read surfaces over screenshots. This skill covers the Browser surface only; for native macOS apps use `interceptor-macos`.
---

# Interceptor Browser

This is an agent-operator skill for the Browser surface of Interceptor. Use the `interceptor` CLI (no prefix) to drive a live Chrome / Brave session: pages, network, scene graph, monitor, screenshots. For native macOS apps load `interceptor-macos` instead. The decision rule is at the bottom of this file.

## Fast Path

1. Run `interceptor status`.
2. Fall back to `./dist/interceptor ...` when working inside the Interceptor repo and the binary is not on `PATH`.
3. Prefer the compound commands first:

```bash
interceptor open "https://example.com"
interceptor read
interceptor act e5
interceptor act e7 "hello"
interceptor inspect
```

4. Treat `eN` refs as short-lived. Re-read or `find` again after DOM-changing actions.

## Speed Rules

- Prefer one compound command over multiple legacy commands.
- Ask Interceptor for the narrowest surface that answers the question: `--tree-only`, `--text-only`, `read <ref>`, `text <ref>`, `inspect --filter <pattern>`, `net log --filter <pattern> --limit <n>`.
- Prefer `find` or semantic selectors to recover after refs go stale.
- Use `wait-stable` only when the DOM should settle. Avoid blind sleeps when built-in waits already apply.
- Use `act --no-read` only when you intentionally do not need the updated tree.

## Read Hierarchy

- Default: `open`, `read`, `act`, `inspect`
- Narrow reads: `tree`, `find`, `text`, `html`, `diff`, `state`
- Network: `net log`, `net headers`, `override`, `sse`
- Rich editors: `scene profile`, then `scene list`, `scene text`, `scene insert`, `scene slide goto`, `scene render`
- Canvas / WebGL apps: dispatched events with `__interceptor_trust` marker via `eval --main` — see `references/rich-editors.md`
- Escape hatch: `eval --main` only when the built-in command surface is not enough

## Input Layer Priority

1. **Synthetic events (default).** `interceptor act`, `click`, `type`, `keys` — and dispatched `MouseEvent` / `KeyboardEvent` / `WheelEvent` via `eval --main` when finer control is needed. The pre-load `userActivation` override (shipped in `extension/src/inject-net.ts` at `document_start`, MAIN world) makes `navigator.userActivation.isActive` always read `true`, satisfying transient-activation gates. Tagging dispatched events with `event.__interceptor_trust = true` satisfies the per-event check on sites that read `isTrusted` via the prototype. Together they handle rich-editor typing, canvas pan/zoom/click, design-tool layer selection, bulk-export trigger, and the vast majority of regular sites.
2. **`--os` (escalation only).** Reach for it only after synthetic input is observed to fail. Genuine cases: sites with anti-automation that checks beyond `event.isTrusted` (some banking / payment gateways), IME composition input, OS-mediated dialogs that escape the page.
3. **`eval --main` (escape hatch).** When no built-in command exposes what you need. Frequently paired with the `__interceptor_trust` marker to drive canvas-rendered apps (Docs / Slides / Sheets, WebGL viewers, design tools).

Default to (1), measure, only escalate when it actually fails. The historical reflex of reaching for `--os` for every "isTrusted-checking site" is no longer correct.

## Screenshot Policy

- Do not use screenshots for routine navigation, extraction, or understanding. Real-world agent traces show screenshots can cost 6–10× more tokens per turn than structured reads.
- Prefer tree, text, network, or scene data first.
- Use screenshots only when pixels are the task: explicit visual evidence is requested, a layout or color issue cannot be confirmed from structured surfaces, or a specific render artifact must be captured.
- In editors, prefer `scene render` or `canvas read` before a page screenshot.
- When a screenshot is unavoidable, use the **agent default**:

  ```bash
  interceptor screenshot --save --format webp --target-max-long-edge 1568 --quality 85
  ```

  This writes a small WebP to disk and returns a path-only result (no inline base64). `--target-max-long-edge 1568` clamps to Anthropic Sonnet's auto-resize ceiling so no upload bytes are wasted; raise to `2576` for Opus, or omit only when the consumer needs higher fidelity. Without `--save`, the WebP rides the response inline at ~50–100 KB instead of multi-MB PNG.

## Choose The Workflow

### Use browser control

- Start with `open`, `read`, `act`, and `inspect`.
- Use `tree`, `find`, `text`, `html`, `diff`, and `state` only when the compound commands do not give enough detail.
- Use `inspect` or filtered `net` reads when the page is an SPA or hides the real data behind API calls.
- Clear request rewrite rules with `interceptor override clear` after extraction or pagination work.
- Use `eval --main` only when the built-in browser surface is insufficient. On strict-CSP sites, the first attempt may trigger an automatic reload/retry path.

### Use rich-editor control

- Run `interceptor scene profile` before assuming scene support.
- Prefer accessible menus and toolbars before scene clicks.
- Use `scene list`, `scene selected`, `scene text`, `scene insert`, `scene slide goto`, and `scene render` only after confirming the profile and capability fit.
- Treat Google Docs as the strongest structured editor target.
- Treat Google Slides as partly structured: navigation and selection are good, but text insertion and table growth can still require `eval --main`.

See `references/rich-editors.md` for canvas-rendered editor input, canvas camera apps, and native client-side export capture.

### Use teach-and-replay

- Record trusted user behavior with `interceptor monitor start`.
- Treat `interceptor monitor export <sid> --plan` as the highest-value artifact.
- Use replay plans when the fastest path is learning a real user flow instead of rediscovering it manually.

See `references/monitor-and-replay.md` for monitor session behavior, replay-plan generation, and cross-tab/focus-follow notes.

## Escalate Carefully

- **Try synthetic events first** (`act`, `click`, `type`, `keys`, or dispatched events via `eval --main` with `event.__interceptor_trust = true`). The pre-load `userActivation` override means the activation gate is already satisfied. Only escalate to `--os` if synthetic input is observed to fail.
- Use `eval --main` only when the built-in command surface doesn't expose what you need. The dispatched-event pattern (with `__interceptor_trust` marker) is often the narrowest viable path for canvas-rendered surfaces.
- Avoid `interceptor network on` unless raw CDP interception is explicitly needed. Passive capture already sees fetch / XHR / EventSource traffic using only standard Web APIs, without attaching the DevTools protocol. WebSocket frames need a MAIN-world `WebSocket` patch (see canvas-rendered notes), not CDP.

## Cross-Surface Note (Background-First)

PRD-59's background-first contract is **macOS-only** — the Browser surface doesn't have a frontmost-app concept that agents need to preserve. `interceptor open <url>`, `read`, `act`, `inspect`, etc. operate inside the user's existing browser session and never raise other apps. If a workflow involves both surfaces (e.g. open a URL in a backgrounded Brave) the macOS half runs through the `interceptor-macos` skill and inherits PRD-59 there.

## When To Switch Surfaces

If the target is **outside the page** — a native dialog, browser chrome (URL bar, profile picker), Save/Open file picker, OS notification, or any other macOS app — load `interceptor-macos` instead. The Browser surface cannot see anything outside the page.

| Task | Stay on Browser | Switch to interceptor-macos |
|---|---|---|
| Click / type on a webpage | ✅ default (`act`, `click`, `type`) | — |
| Read DOM, network, SPA state | ✅ default (`inspect`, `net`, `scene`) | — |
| Native dialogs / Save-Open / file pickers | ❌ extension cannot see | ✅ `mac_tree`, `mac_act` |
| Browser chrome (URL bar, profile picker, bookmark menu) | ❌ | ✅ |
| Cross-app routing (Notes → Slack, Mail → Brave) | ❌ | ✅ |
| Drive non-browser app (Notes, Mail, Music, Cursor, Discord) | ❌ | ✅ |
| Screenshot a backgrounded / occluded window | `interceptor screenshot` only for current Chrome tab | ✅ `mac_screenshot --app "X"` |

**Decision rule of thumb:**
- **Page content** → Browser (this skill)
- **Anything outside the page** → `interceptor-macos`

## Do Not Default To Troubleshooting

- If the user wants a browser task completed, run Interceptor commands.
- If the user wants Interceptor fixed, installed, or explained, that is a separate task.
- When working inside the Interceptor repo, use this skill mainly for live validation of browser behavior, not as the primary source of repo-development instructions.

## Open References

- [`references/browser-and-network.md`](references/browser-and-network.md) — command selection, SPA extraction, request overrides, SSE capture.
- [`references/rich-editors.md`](references/rich-editors.md) — Canva, Google Docs, Google Slides behavior and caveats.
- [`references/monitor-and-replay.md`](references/monitor-and-replay.md) — monitor usage, replay-plan generation, cross-tab/focus-follow behavior.
