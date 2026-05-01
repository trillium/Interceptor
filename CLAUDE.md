# interceptor

> Canonical agent instructions live in [AGENTS.md](AGENTS.md). User-facing overview lives in [README.md](README.md). This file is retained as a compatibility shim for tools that still look for `CLAUDE.md`.

Browser control CLI for AI agents. No CDP, no MCP, no API keys. You call `interceptor`, read the output, decide what's next.

**Binary:** `dist/interceptor`

## Two Surfaces

Interceptor ships one CLI binary with two product surfaces under one daemon:

- **Interceptor Browser** (`interceptor open / read / act / inspect / scene / monitor / net / sse / override / screenshot / …`) — drives a real Chrome / Brave session inside your existing profile. Skill: `.agents/skills/interceptor-browser/`.
- **Interceptor macOS** (`interceptor macos *`) — drives native macOS apps via a Swift bridge daemon. Skill: `.agents/skills/interceptor-macos/`.

Pick by where the target lives. Page content → Browser. Anything outside the page → macOS. The full decision matrix is in [AGENTS.md → Browser Extension vs macOS Bridge](AGENTS.md#browser-extension-vs-macos-bridge).

`.agents/skills/interceptor-windows/` is reserved for a future Windows surface (UIA / Win32 / ETW). It is not built.

## Start Here

```bash
# Browser
interceptor open "https://example.com"        # Open, wait, return tree + text
interceptor act e1                             # Click element, return updated tree + diff
interceptor inspect                            # Tree + text + network log + headers

# macOS (bridge installed)
interceptor macos open "Finder"                # Activate + tree + windows
interceptor macos act e5                       # Click + wait + updated tree
```

The daemon auto-starts on first command. When working inside this repo, prefer `./dist/interceptor ...` if `interceptor` is not on `PATH`.

## Where The Detail Lives

| You want to | Read |
|---|---|
| User-facing install / overview / per-surface command index / recipes | [README.md](README.md) |
| Agent operating manual: rules, decision tables, workflows, escape hatches | [AGENTS.md](AGENTS.md) |
| Architecture (transport, monitor, scene, screenshots) | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Browser-surface fast path for skill loaders | [.agents/skills/interceptor-browser/SKILL.md](.agents/skills/interceptor-browser/SKILL.md) |
| macOS-surface fast path for skill loaders | [.agents/skills/interceptor-macos/SKILL.md](.agents/skills/interceptor-macos/SKILL.md) |
| Native bridge domain index | [docs/native/README.md](docs/native/README.md) |
