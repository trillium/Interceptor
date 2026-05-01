# Interceptor Native — Scene-Script Cookbook

`scene-script` lets you spawn a SpriteKit scene from a JS-ish script. `OverlaySceneScriptView.swift` compiles and runs it at ~60 fps.

## Built-in scenes

| Scene | What it does |
|---|---|
| `roses` | Rose petals rain down. |
| `snow` | Snow falls. |
| `confetti` | Confetti burst. |
| `arrow` | A single arrow you can anchor. |
| `ninja_vs_pirate` | Two sprites duel. |
| `titans` | Larger multi-sprite scene. |

Invoke with `interceptor macos overlay start` + `scene: "<name>"` or use a preset via `scene_script:` raw text.

## Custom scene-script

```typescript
await call("mac_overlay_start", {
  scene_script: `
    spawn emoji "⚡" at center scale 2
    wait 0.5
    move "⚡" to 1,1 over 1.5
    wait 1.5
    fade "⚡" out over 0.5
    despawn "⚡"
  `,
  level: "overlay",
});
```

## Verbs

Call `interceptor macos overlay verbs` to introspect the verbs your scene supports.

Common verbs:
- `spawn <id> <asset> at <x,y>` — add a sprite.
- `move <id> to <x,y> over <secs>` — tween position.
- `fade <id> <in|out> over <secs>` — alpha tween.
- `scale <id> to <n> over <secs>` — scale tween.
- `rotate <id> by <degrees> over <secs>` — rotation.
- `wait <secs>` — pause sequence.
- `despawn <id>` — remove sprite.

## Dispatching commands at runtime

```typescript
await call("mac_overlay_ctl", {
  id: "<overlay-id>",
  verb: "move",
  args: { target: "ninja", x: 0.3, y: 0.5, duration: 1 },
});
```

## Budget tips

- `density > 100` on particles can stall the WebView on older GPUs — cap at 60.
- `lifetime: 0` = infinite. Always set `timeout_seconds` as a safety net.
