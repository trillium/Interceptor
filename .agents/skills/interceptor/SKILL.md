---
name: interceptor
description: Thin index skill — points at the two surface-specific skills. Use `interceptor-browser` to drive a live signed-in Chrome / Brave session, or `interceptor-macos` to drive native macOS apps. Kept as a compatibility shim for one release; new work should load one of the surface skills directly.
---

# Interceptor (Index)

Interceptor ships two product surfaces under one CLI binary. Pick the right surface skill for the task; this file is a router, not a workflow.

| Task surface | Skill to load |
|---|---|
| Page content (DOM, network, scene graph in Canva / Docs / Slides, browser monitor, screenshots of a Chrome tab) | [`interceptor-browser`](../interceptor-browser/SKILL.md) |
| Native macOS apps, browser chrome (URL bar / menus), system dialogs, occluded window capture, Apple Events, on-device vision / speech / NLP, native monitor | [`interceptor-macos`](../interceptor-macos/SKILL.md) |

**Rule of thumb:** page content → `interceptor-browser`. Anything outside the page → `interceptor-macos`.

## Cross-Surface Decision Table

Both surfaces overlap on a few tasks. Pick by strength; lean into what the user asked for.

| Task | Browser | macOS bridge |
|---|---|---|
| Click / type on a webpage | ✅ default (`act`, `click`, `type`) | — |
| Read DOM, network, SPA state | ✅ default (`inspect`, `net`, `scene`) | — |
| Open URL in a *named* browser ("Brave", "Chrome", "Safari") | only if it already has the extension | ✅ Apple Events to that bundle id |
| Screenshot a specific app's window (browser or otherwise) | only the current Chrome tab | ✅ `mac_screenshot --app "X"` (works occluded / minimized) |
| Native dialogs / Save-Open / file pickers | ❌ extension cannot see | ✅ `mac_tree`, `mac_act` |
| Browser chrome (URL bar, profile picker, bookmark menu) | ❌ | ✅ |
| Cross-app routing (Notes → Slack, Mail → Brave) | ❌ | ✅ |
| Drive non-browser app (Notes, Mail, Music, Cursor, Discord) | ❌ | ✅ |
| Visual overlays / floating HUDs over content | DOM-only | ✅ `mac_overlay` (NSPanel above compositor) |

**Decision rules:**
- **Page content** → Browser
- **Anything outside the page** → macOS
- **App-level operation on a backgrounded app** → macOS in background (don't activate)
- **The user's words win.** "Open in Brave" = open in Brave (not just any browser). "Don't bring it up" = stay in the background. Lean into specifics.

## Reserved Surface

`.agents/skills/interceptor-windows/` is reserved for a future Windows surface (UIA accessibility tree, Win32 input, ETW traces). It does not exist yet — do not stub it. When it ships it will be a peer of the two existing skills with the same shape.

## Compatibility Note

This index skill is kept for one release while harnesses that pinned `.agents/skills/interceptor/SKILL.md` migrate to one of the surface skills. New skill loaders should target `interceptor-browser` or `interceptor-macos` directly.
