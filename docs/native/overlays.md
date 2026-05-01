# Overlays

Three overlay modes share one transparent topmost `NSPanel` (level `.statusBar` by default), backed by `OverlayDomain`:

| Mode | `interceptor macos overlay start` flag | Backed by | Use for |
|---|---|---|---|
| Particles | `--particles roses\|snow\|confetti\|…` | `CAEmitterLayer` | Visual feedback, celebrations, ambient effects |
| Scene (Titans) | `--scene titans` | `SpriteKit` `SKScene` | Hardcoded Godzilla-vs-Kong fight with verbs |
| Scene-script | `--scene-script <path-or-inline>` | `SpriteKit` runtime DSL | Dynamic cartoons, mini-games, custom scripted scenes |
| HTML | `--url <URL>` or `--html-b64 <b64>` | `WebKit` `WKWebView` | Arbitrary HUDs (React, D3, etc.) with `eval` JS injection |

## Starter examples

### Rose rain
```bash
interceptor macos overlay start --particles roses --density 40 --lifetime 8
```

### Godzilla vs Kong
```bash
ID=$(interceptor macos overlay start --scene titans --rect 0.05,0.05,0.9,0.9 | jq -r '.id')
interceptor macos overlay verbs "$ID"
interceptor macos overlay ctl "$ID" punch --target kong --power 0.9
interceptor macos overlay ctl "$ID" "breathe-fire" --duration 2.0
interceptor macos overlay ctl "$ID" knockout --winner godzilla
sleep 4
interceptor macos overlay stop "$ID"
```

Verbs available on the Titans scene: `say`, `punch`, `breathe-fire`, `taunt`, `roar`, `bow`, `knockout`, `reset`, `pause`, `resume`, `throw`, `tint`, `jump`, `round`.

### HTML HUD
```bash
ID=$(interceptor macos overlay start --url "file:///tmp/my-hud.html" \
  --rect 1200,60,400,200 --interactive | jq -r '.id')
# Update DOM live without reloading
interceptor macos overlay eval "$ID" "document.querySelector('h1').textContent = 'Updated!'"
```

### Scene-script (dynamic)
See [scene-script-cookbook.md](scene-script-cookbook.md) for the recipe DSL. Quick example:
```bash
interceptor macos overlay start --scene-script /path/to/hello-world.scene
```

## Lifecycle

- `interceptor macos overlay start ...` returns an `id`. Keep it.
- `interceptor macos overlay list` / `status [id]` to inspect.
- `interceptor macos overlay eval <id> "<js>"` runs JS inside an HTML overlay.
- `interceptor macos overlay ctl <id> <verb> [--key value ...]` dispatches a scene verb.
- `interceptor macos overlay verbs [id]` returns the supported verb list.
- `interceptor macos overlay stop <id>` stops one. Omit `id` to stop all overlays.
- Bridge shutdown (SIGTERM/SIGINT) auto-stops every overlay.

## Panic hotkey

`Ctrl+Opt+Cmd+Escape` closes every active overlay regardless of owner. The bridge installs a global non-consuming `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` at boot — it never interferes with other shortcuts because it does not consume the event.

## Safety norms

Overlays are persistent and can cover critical UI. Prefer:

- **Corner-anchored rects** over full-screen.
- **`--timeout-seconds N`** when an overlay is decorative — bridge auto-stops after N seconds.
- **`--no-interactive`** unless you actually need pointer events (otherwise the overlay swallows clicks behind it).

## Click-through

`canBecomeKey` and `acceptsFirstMouse(for:)` are both gated on `interactive`. With `--no-interactive` (default), clicks pass through to the underlying app. With `--interactive`, the overlay accepts focus and pointer events.

## Transparent rendering

The Titans/scene-script SpriteKit scenes set `SKView.allowsTransparency = true` + `SKScene.backgroundColor = .clear`. Without these, SpriteKit renders an opaque black background regardless of the host panel's transparency.

The HTML overlay path uses `WKWebView` inside an `NSPanel` with `level == .statusBar` and `collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary]`. macOS 15+ has a known regression where `WKWebView` can render opaque inside a panel; the donor's `OverlayPanel` + `OverlayContentView` overrides handle this.
