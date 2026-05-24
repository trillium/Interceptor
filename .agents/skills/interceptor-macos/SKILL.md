---
name: interceptor-macos
description: "Drive native macOS apps via `interceptor macos *` — read AX trees, click and type with OS-level trusted input, capture occluded / minimized / cross-Space windows, run on-device speech / vision / NLP, dispatch Apple Events, monitor and replay native flows, and run bridge-local JSC host utilities. Background-first by contract — only `app activate` and `open --activate` move focus. Workflows: CaptureBackgroundedApp (occluded window screenshot), DriveBackgroundedApp (click/type on non-frontmost app), DispatchAppleEvent (Apple Events to named app), ReadAxTree (AX tree with Electron wake-up), RecordAndReplayMacFlow (native monitor flow), TrustedInputGate (OS-level trusted input). USE WHEN macOS app, native app, AX tree, Apple Events, screenshot of app, drive Finder/Mail/Cursor, occluded window, browser chrome, URL bar, system dialog, trusted input, on-device vision, on-device speech, NLP, monitor mac flow, replay native, overlay, vibrate, intent dispatch, JSC host. NOT FOR content inside a browser tab (use interceptor-browser)."
metadata:
  short-description: Drive native macOS apps via the interceptor CLI; background-first
---

<!--
Reserved namespace: `.agents/skills/interceptor-windows/` is reserved for a future
Windows surface (UIA, Win32 input, ETW). It does not exist yet — do not stub it.
-->

# Interceptor macOS

Agent-operator skill for the macOS surface of Interceptor. Use the `interceptor macos *` CLI to drive native macOS applications: AX trees, OS-level trusted input, capture / vision / speech / NLP / Apple Events, monitor-and-replay, overlays. For content inside a browser tab load `interceptor-browser` instead.

The macOS bridge is a Swift daemon launched as a LaunchAgent / `.app` bundle. Links Apple frameworks only (Accessibility, ScreenCaptureKit, AVFoundation, Speech, Vision, NaturalLanguage, OSLogStore, NSAppleScript, container runtime). No private APIs.

Constitutional rules (Background-First, Surface Decision) live in [AGENTS.md](../../../AGENTS.md). This file is a dispatcher to the **Workflows** and **references** below.

## Fast Path

```bash
interceptor status                       # 1. Confirm daemon + bridge are alive
interceptor macos trust                  # 2. Confirm TCC permissions granted
interceptor macos open "Finder"          # 3. Tree + windows (background — does NOT raise Finder)
interceptor macos read                   # 4. AX tree + frontmost info
interceptor macos act e5                 # 5. AX press of ref e5 — no focus change
interceptor macos act e3 "hello"         # 6. AX value-set of ref e3 — no focus change
```

Treat `eN` refs as short-lived. AX state can change between calls; re-read before acting.

## The One Rule

**Only two commands move focus:** `interceptor macos app activate <app>` and `interceptor macos open <app> --activate`. Everything else is background-first by contract — `open` (without `--activate`), all input verbs, all reads, capture, AX, menu, intent dispatch, scroll, drag, vision, overlays. If you call any other command and the user's frontmost app changes, that is a bug — file it.

Full contract + verb inventory + worked examples + pitfalls: [`references/background-first.md`](references/background-first.md).

## Workflows

Each workflow is a complete self-contained "you are doing X" procedure. Open the file when the task matches.

| Workflow | When to invoke |
|---|---|
| [`Workflows/CaptureBackgroundedApp.md`](Workflows/CaptureBackgroundedApp.md) | Screenshot an occluded / minimized / cross-Space window — without activating it |
| [`Workflows/DriveBackgroundedApp.md`](Workflows/DriveBackgroundedApp.md) | Click / type / keys / drag against a non-frontmost app via AX + `postToPid` |
| [`Workflows/DispatchAppleEvent.md`](Workflows/DispatchAppleEvent.md) | Apple Events to a named bundle id — open URL in Brave, read active tab, etc. |
| [`Workflows/ReadAxTree.md`](Workflows/ReadAxTree.md) | `tree --app` of any app, with automatic Electron wake-up |
| [`Workflows/RecordAndReplayMacFlow.md`](Workflows/RecordAndReplayMacFlow.md) | `macos monitor` record + export + replay native UI flows |
| [`Workflows/TrustedInputGate.md`](Workflows/TrustedInputGate.md) | Satisfy an OS-level trusted-input gate that filters synthetic CGEvents |

## References

| File | Topic |
|---|---|
| [`references/background-first.md`](references/background-first.md) | Full Background-First contract, verb inventory, reflexes-to-drop, pitfalls |
| [`references/accessibility-and-input.md`](references/accessibility-and-input.md) | AX tree mechanics, input routing, window control, sensitive-app gate |
| [`references/capture-and-vision.md`](references/capture-and-vision.md) | ScreenCaptureKit + CGS capture, Vision OCR, audio intelligence |
| [`references/advanced-domains.md`](references/advanced-domains.md) | Apple Events, container runtime, OS log, fs, URL fetch, file watch |
| [`references/jsc-host.md`](references/jsc-host.md) | Plain JavaScriptCore host capabilities, flags, scope rules, and pitfalls |
| [`references/monitor-and-replay.md`](references/monitor-and-replay.md) | Native monitor sessions, replay plans, event sources |
| [`references/command-catalog.md`](references/command-catalog.md) | Full macOS command surface with flags and examples |
| [`references/permissions.md`](references/permissions.md) | TCC permissions, microphone re-poll, Dock-icon notes |

## When To Switch Surfaces

If the target is **inside a browser page** (DOM, network, SPA state, browser monitor, scene-graph of a Canva/Docs/Slides editor) — load `interceptor-browser` instead. Decision table is in [AGENTS.md § Surface Decision](../../../AGENTS.md#surface-decision).

## Do Not Default To Troubleshooting

- User wants a macOS task completed → run Interceptor commands.
- User wants Interceptor fixed, installed, or explained → that's a separate task; ask before diving into repo state.
- Inside the Interceptor repo, use this skill for live macOS validation, not as the primary source of repo-development instructions.
