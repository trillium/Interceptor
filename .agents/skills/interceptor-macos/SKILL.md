---
name: interceptor-macos
description: Use when the agent should drive native macOS applications via `interceptor macos *` — read accessibility trees, click and type with OS-level trusted input, capture occluded / minimized / cross-Space windows, run on-device speech / vision / NLP, dispatch Apple Events to background apps, monitor and replay native flows. Stay background-first unless the user asks for activation. This skill covers the macOS surface only; for content inside a browser tab use `interceptor-browser`.
---

<!--
Reserved namespace: `.agents/skills/interceptor-windows/` is reserved for a future
Windows surface (UIA, Win32 input, ETW). It does not exist yet — do not stub it.
When it ships it will be a peer of this skill with the same shape.
-->

# Interceptor macOS

This is an agent-operator skill for the macOS surface of Interceptor. Use the `interceptor macos *` CLI to drive native macOS applications: AX trees, OS-level trusted input, capture / vision / speech / NLP / Apple Events, monitor-and-replay, overlays. For content inside a browser tab load `interceptor-browser` instead.

The macOS bridge is a Swift daemon launched as a LaunchAgent / `.app` bundle. It links Apple frameworks only (Accessibility, ScreenCaptureKit, AVFoundation, Speech, Vision, NaturalLanguage, OSLogStore, NSAppleScript, container runtime). No private APIs.

## Fast Path

1. Run `interceptor status` and `interceptor macos trust` — confirm the bridge socket is alive and the right TCC permissions are granted.
2. Prefer the compound surface:

```bash
interceptor macos open "Finder"      # Activate + tree + windows (one call)
interceptor macos read               # Tree + frontmost app info
interceptor macos act e5             # Click + wait + updated tree
interceptor macos act e3 "hello"     # Type + wait + updated tree
interceptor macos inspect            # Tree + apps + frontmost info
```

3. Treat `eN` refs as short-lived. AXObserver auto-invalidates the tree when the app changes; re-read before acting.

## Background First (default contract)

When the user names a specific app ("screenshot of Brave", "scroll Signal", "open a tab in Brave"), **do the work without bringing it to the foreground unless the task strictly requires it.** Never `interceptor macos app activate`, never insert `activate` into AppleScript blocks, never `--mode display`-screenshot a backgrounded app's window.

The bridge has paths for this:

| Want to do | Background path | No focus change? |
|---|---|---|
| Capture an occluded / minimized / cross-Space window | `interceptor macos screenshot --app "X"` (uses `CGSHWCaptureWindowList`) | ✅ |
| Read AX tree of an Electron app (Slack/Discord/Cursor/Brave/Notion/VS Code) | `interceptor macos tree --app "X"` (auto-wakes via `AXManualAccessibility`) | ✅ |
| Open URL in a specific browser | `interceptor macos intent dispatch --bundle <id> --script 'open location "..."'` | ✅ Apple Events deliver without raising |
| Read the active tab URL of Brave/Chrome/Safari | `interceptor macos intent dispatch --bundle <id> --script '... URL of active tab ...'` | ✅ |
| Scroll a backgrounded app | `interceptor macos scroll <dir> <amount> --app "X" --times <N>` (routes via `postToPid`) | ✅ for Cocoa & most Electron; Chromium-occluded apps may need brief raise |
| Move / resize a backgrounded window | `interceptor macos move/resize "X"` via AX | ✅ |
| Drive a non-frontmost native app | AX `interceptor macos act/click/type` against its PID | ✅ |

**Reflexes to drop:** `interceptor macos app activate` is not a precondition for capture, AX read, scroll, or Apple Events. Skip it. The user's focused window stays where it was.

**When the user explicitly says "bring it forward / show me / switch to"**: respect that. Activate, do the operation, leave it there (or return to previous frontmost if asked).

## Read Hierarchy

1. Compound: `interceptor macos open "X"`, `interceptor macos read`, `interceptor macos inspect`.
2. AX tree narrows: `tree`, `find`, `focused`, `value`, `action`, `windows`, `inspect <ref>`.
3. App / window control: `apps`, `app activate/hide/quit/launch`, `frontmost`, `move`, `resize`.
4. Capture: `screenshot --app "X"`, `capture start/frame/stop`, `stream start/frame/stop`.
5. Audio intelligence: `listen`, `vad`, `sounds`, `audio output/input`.
6. Vision / NLP / Intelligence: `vision text/faces/hands/bodies`, `nlp entities/sentiment/language`, `ai prompt`.
7. Cross-app routing: `intent dispatch --bundle <id> --script <applescript>`, `intent warmup`.
8. System reads: `notifications tail`, `clipboard read/write/tail`, `files watch`, `fs read/write/search`, `url get/post`, `log query`.
9. Overlays: `overlay *` — panic hotkey `Ctrl+Opt+Cmd+Escape` always available.
10. Recording: `monitor start/stop/tail/export [--plan]`.

## Daily-Driver Domains

The five daily-driver domains an agent reaches for repeatedly:

- **Accessibility (AX)** — `tree`, `find`, `inspect`, `value`, `action`, `windows`, `focused`. See `references/accessibility-and-input.md`.
- **Input** — `click`, `type`, `keys`, `scroll`, `drag`. CGEvent-trusted. Auto-escalates from AX action to coordinate click when AX action fails. See `references/accessibility-and-input.md`.
- **Capture** — `screenshot`, `capture`. ScreenCaptureKit + `CGSHWCaptureWindowList` for occluded windows. See `references/capture-and-vision.md`.
- **Monitor** — record native flows, export replay plan. See `references/monitor-and-replay.md`.
- **Clipboard** — `clipboard read/write/tail`.

## Specialized Domains

Everything else the bridge supports — same agent-first contract, used less frequently. *Tiering means presentation, not deprecation; every domain is fully supported.*

- Apps & Windows (`apps`, `app *`, `frontmost`)
- Menu Traversal (`menu`)
- Audio (system + microphone capture)
- Speech & VAD (`listen`, `vad`)
- Sound Classification (`sounds`)
- Vision (`vision faces/text/hands/bodies`)
- NLP (`nlp entities/sentiment/language`)
- Apple Intelligence (`ai prompt`, macOS 26+)
- Notifications (`notifications tail`)
- Trust & Permissions (`trust`)
- Files & Filesystem (`files`, `fs`)
- URL Fetch (`url get/post`)
- Log Query (`log query`)
- Apple Events (`intent dispatch/warmup`)
- Container Runtime (`container run`, macOS 26+)
- Display & Streaming (`display`, `stream`)
- Text (`text` — selection / visible / full from frontmost app)
- Overlays (particles / titans / scene-script / HTML HUD)

See `references/advanced-domains.md` for the deep dive on each.

## Permissions

- Run `interceptor macos trust` — returns current grant status with deep links to System Settings.
- Run `interceptor macos trust --prompt` to register Interceptor in Accessibility.
- Run `interceptor macos trust --walkthrough` to prompt + auto-open the next relevant Privacy pane.
- Treat `interceptor macos trust` as a permission snapshot, not a runtime-health check. Use `interceptor status` to confirm the bridge socket is live before debugging native runtime failures.
- For packaged installs, `/Applications/Interceptor.app` owns helper registration and privacy onboarding. `interceptor macos trust` reports app-owned trust state, not proof that a shell-launched probe will succeed.
- For microphone-sensitive workflows, verify the live path with `interceptor macos audio input start/stop` after trust looks good.

| Permission | Required | Enables |
|---|---|---|
| Accessibility | Yes | AX tree, input, window management |
| Screen Recording | Optional | Screenshots, capture, stream, vision |
| Microphone | Optional | Speech recognition, VAD, sound classification |
| Input Monitoring | Optional | `monitor` global key/click capture |

If `interceptor macos *` reports `Interceptor bridge not running` or `connection closed before response`, the helper lifecycle is unhealthy even if `trust` says permissions are granted.

## Safety

- **Panic hotkey** — `Ctrl+Opt+Cmd+Escape` closes every active overlay regardless of owning session. Bridge-side handler.
- **Sensitive frontmost-app gate** — `mac_type`, `mac_keys`, `mac_click(coords)`, `mac_drag` are rejected when the frontmost app's bundle ID is on the denylist (Keychain, 1Password, Dashlane, LastPass, Bitwarden, System Settings, Chase, Bank of America, Wells Fargo). Extend per environment via `SENSITIVE_BUNDLE_IDS`.
- **Permission tiers** — Allow (observational): AX reads, app reads, screenshot, vision, NLP, clipboard read, capture, audio, sounds, speech, scroll, overlays. Ask (interactive): click, type, keys, drag, app quit/hide, clipboard write. Deny: none by default.
- **Stop control** — Active overlays do NOT block session completion. Session shutdown tears down every overlay owned by the session. Engine crash recovery marks orphan overlays `closed_reason=crash`.

## Background Recipes

```bash
# Screenshot of Brave's current window — Brave stays where it was
interceptor macos screenshot --app "Brave Browser" --save --target-max-long-edge 1568

# Open a tab in Brave without bringing Brave to front
interceptor macos intent dispatch --bundle com.brave.Browser \
  --script 'tell application "Brave Browser" to tell front window to make new tab with properties {URL:"https://example.com"}'

# Read the active tab URL/title from Brave (no focus change)
interceptor macos intent dispatch --bundle com.brave.Browser \
  --script 'tell application "Brave Browser" to URL of active tab of front window'

# Read AX tree of Cursor (Electron — wake-up automatic) without activating it
interceptor macos tree --app "Cursor" --filter interactive --depth 6

# Scroll Mail down 5 times while another app stays focused
interceptor macos scroll down 400 --app "Mail" --times 5 --interval-ms 80
```

## When To Switch Surfaces

If the target is **content inside a browser tab** — DOM, page network traffic, scene graph (Canva / Docs / Slides), webapp recording — load `interceptor-browser` instead. The macOS surface cannot read inside a page; the AX tree of a Chrome window stops at the tab strip.

| Task | Stay on macOS | Switch to interceptor-browser |
|---|---|---|
| Click / type in a native app | ✅ default | — |
| Read native AX tree | ✅ default | — |
| Capture occluded / minimized / cross-Space window | ✅ `screenshot --app "X"` | — |
| Native dialogs / Save-Open / file pickers | ✅ | ❌ |
| Browser chrome (URL bar, bookmark menu, profile picker) | ✅ | ❌ |
| Cross-app routing (Notes → Slack, Mail → Brave) | ✅ | ❌ |
| Click / type on a webpage | — | ✅ |
| Read DOM, network, SPA state | — | ✅ |
| Drive Canva / Google Docs / Google Slides scene | — | ✅ |

**Decision rule of thumb:**
- **Anything outside the page** → macOS (this skill)
- **Page content** → `interceptor-browser`
- **App-level operation on a backgrounded target** → stay in background; don't activate.
- **The user's words win.** "Open in Brave" = open in Brave (not just any browser). "Don't bring it up" = stay in the background.

## Open References

- [`references/accessibility-and-input.md`](references/accessibility-and-input.md) — AX tree usage, refs, find/inspect/value/action, input layer (CGEvent escalation).
- [`references/capture-and-vision.md`](references/capture-and-vision.md) — ScreenCaptureKit / CGSHWCaptureWindowList capture, vision (OCR / faces / hands / bodies), audio intelligence.
- [`references/monitor-and-replay.md`](references/monitor-and-replay.md) — native monitor sessions, AX-annotated event format, replay plan generation.
- [`references/advanced-domains.md`](references/advanced-domains.md) — specialized domains: Apple Events, Container, Log query, Fs, Notifications, NLP, Apple Intelligence, Overlays, Display, Stream, URL fetch.
