---
name: interceptor
description: "Choose the right Interceptor surface. Use interceptor-browser for page DOM, network, browser tabs, rich editors, screenshots, and browser automation. Use interceptor-macos for native apps, browser chrome, URL bars, OS dialogs, cross-app routing, AX trees, native screenshots, Apple Events, and trusted OS input. Background-first by default; focus changes require explicit opt-in."
metadata:
  short-description: Choose the right Interceptor surface
---

# Interceptor

Use this as the routing skill before loading a surface-specific skill.

## Surface Decision

| Task | Skill |
|---|---|
| Page DOM, text, network, SPA state, browser monitor, screenshots of browser content | `interceptor-browser` |
| Rich browser editors, canvas / scene graph reads, page-world request overrides | `interceptor-browser` |
| Native macOS apps, OS dialogs, browser chrome, URL bars, app windows, menu bars | `interceptor-macos` |
| Open or control a named app such as Brave, Mail, Finder, Signal, or Cursor | `interceptor-macos` |
| Backgrounded, occluded, minimized, or cross-Space app capture | `interceptor-macos` |

## Core Rules

- Browser commands operate inside the cyan `interceptor` tab group. Do not use `--any-tab` unless the user explicitly authorizes acting outside that group.
- `interceptor open <url>` and `interceptor tab new <url>` create background tabs by default. Only `open --activate`, `tab new --activate`, `tab switch <id>`, and `window focus <id>` intentionally move browser focus.
- The macOS surface is background-first by default. Only `interceptor macos app activate <app>` and `interceptor macos open <app> --activate` intentionally move focus.
- If multiple browser profiles are connected, run `interceptor contexts` and pass `--context <id>`.
- Prefer compound commands (`open`, `read`, `act`, `inspect`) and structured reads before screenshots.
- If an already-loaded unpacked extension behaves stale after a package update, reload it from `chrome://extensions` or `brave://extensions`, or run `interceptor reload` once the extension is reachable.

## Load A Surface Skill

- Load `interceptor-browser` for browser page content, network, tabs, scene graphs, and browser screenshots.
- Load `interceptor-macos` for native apps, browser chrome, OS dialogs, window capture, AX trees, and Apple Events.
