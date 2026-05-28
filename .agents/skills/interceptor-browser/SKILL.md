---
name: interceptor-browser
description: "Drive a signed-in Chrome / Brave session via the interceptor CLI: open/read pages, click, type, inspect DOM/text/network, automate rich browser editors and scene graphs, capture WebSocket/Beacon/BroadcastChannel traffic, record/replay flows, take VLM-budgeted screenshots, compare pages, and route to specific browser profiles with --context. Use for browser page content, tabs, forms, SPA extraction, request overrides, page communication capture, and deployment checks. Not for native macOS apps, OS dialogs, browser chrome, or large scraping."
metadata:
  short-description: Drive a real signed-in Chrome / Brave session via the interceptor CLI
---

# Interceptor Browser

Agent-operator skill for the Browser surface of Interceptor. Use the `interceptor` CLI (no prefix) to drive a live Chrome / Brave session: pages, network, scene graph, monitor, screenshots. For native macOS apps load `interceptor-macos` instead.

This installed skill is self-contained. Source checkouts also have `AGENTS.md`, but packaged users may only have the skill directory below `/Library/Application Support/Interceptor/skills`.

## Core Rules

- Use compound commands (`open`, `read`, `act`, `inspect`) before low-level verbs.
- Browser commands operate inside the cyan `interceptor` tab group. Do not use `--any-tab` unless the user explicitly authorizes acting outside that group.
- `interceptor open <url>` and `interceptor tab new <url>` create background tabs by default. Only `open --activate`, `tab new --activate`, `tab switch <id>`, and `window focus <id>` intentionally move browser focus.
- If multiple browser profiles are connected, run `interceptor contexts` and pass `--context <id>`.
- Prefer structured reads (`read`, `tree`, `text`, `inspect`, `scene`) before screenshots. Open `references/screenshot-policy.md` before screenshot-heavy work.
- Default to plain text output. Use `--json` only when piping into scripts or when a downstream tool needs a machine-readable contract.
- If an already-loaded unpacked extension behaves stale after a package update, reload it from `chrome://extensions` or `brave://extensions`, or run `interceptor reload` once the extension is reachable.

## Fast Path

```bash
interceptor status                        # 1. Confirm daemon + extension are alive
interceptor open "https://example.com"    # 2. Background tab + wait + tree + text
interceptor read                          # 3. Current state (re-read after any mutation)
interceptor act e5                        # 4. Click ref e5 (refs come from `read`)
interceptor act e7 "example user"         # 5. Type into ref e7
interceptor inspect                       # 6. Tree + text + network in one read
```

Inside this repo without `interceptor` on PATH, use `./dist/interceptor ...`.

## Workflows

Each workflow is a complete self-contained "you are doing X" procedure. Open the file when the task matches.

| Workflow | When to invoke |
|---|---|
| [`Workflows/VerifyDeploy.md`](Workflows/VerifyDeploy.md) | "Verify the deploy", "check that X works on the page", reproducing a bug before touching code |
| [`Workflows/ReadAndExtract.md`](Workflows/ReadAndExtract.md) | Compound page read + SPA state extraction — pull a specific value off a page |
| [`Workflows/DriveRichEditor.md`](Workflows/DriveRichEditor.md) | Canva, Google Docs, Google Slides, design-tool layer manipulation — anything where DOM refs aren't enough |
| [`Workflows/OverrideXhr.md`](Workflows/OverrideXhr.md) | Mutate a request before it hits the server — change params, force a status, throttle |
| [`Workflows/CapturePageCommunication.md`](Workflows/CapturePageCommunication.md) | Capture WebSocket, Beacon, and BroadcastChannel activity without CDP |
| [`Workflows/RecordAndReplay.md`](Workflows/RecordAndReplay.md) | Learn a real user flow, export a replay plan, run it back |
| [`Workflows/ScreenshotForVlm.md`](Workflows/ScreenshotForVlm.md) | Take a screenshot the model will actually understand — VLM-budgeted, WebP, on-disk |
| [`Workflows/MultiPageCompare.md`](Workflows/MultiPageCompare.md) | Compare facts across multiple pages (e.g. "who designed Python vs JavaScript") — sequential `open --text-only` per page |

## References

| File | Topic |
|---|---|
| [`references/browser-and-network.md`](references/browser-and-network.md) | Command selection, SPA extraction, request overrides, SSE capture, page-world `eval --main` cautions |
| [`references/page-communication-capture.md`](references/page-communication-capture.md) | P1 WebSocket, Beacon, and BroadcastChannel capture mechanics, commands, event shapes, and limits |
| [`references/rich-editors.md`](references/rich-editors.md) | Canva, Google Docs, Google Slides behavior, canvas-rendered editor input, WebGL camera apps, blob export capture |
| [`references/monitor-and-replay.md`](references/monitor-and-replay.md) | Monitor session behavior, replay-plan generation, cross-tab/focus-follow notes |
| [`references/command-catalog.md`](references/command-catalog.md) | Full browser command surface with flags and examples |
| [`references/screenshot-policy.md`](references/screenshot-policy.md) | VLM-aware screenshot budget table; agent-default recipe |

## When To Switch Surfaces

If the target is **outside the page** - a native dialog, browser chrome (URL bar, profile picker), Save/Open file picker, OS notification, or any non-browser macOS app - load `interceptor-macos` instead.

## Do Not Default To Troubleshooting

- User wants a browser task completed → run Interceptor commands.
- User wants Interceptor fixed, installed, or explained → that's a separate task; ask before diving into repo state.
- Inside the Interceptor repo, use this skill for live browser validation, not as the primary source of repo-development instructions.
