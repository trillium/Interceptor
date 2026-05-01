# Interceptor Native — Vision-Anchored HUDs

Combine Apple Vision with overlays to place annotations in screen-space.

## Recipe: point at a face

```typescript
const v = await call("mac_vision_faces", { full: true });
// v.data.observations = [{bounding_box: {x, y, width, height}, confidence}]
const first = v.data.observations[0];
await call("mac_overlay_start", {
  scene: "arrow",
  anchor: "normalized",
  rect: first.bounding_box,  // normalized 0..1 in screen coords
  timeout_seconds: 5,
});
```

## Recipe: highlight OCR'd text

```typescript
const r = await call("mac_vision_text", { app: "Safari" });
for (const obs of r.data.observations) {
  await call("mac_overlay_start", {
    url: "file:///usr/local/share/interceptor/hud/box.html",
    anchor: "normalized",
    rect: obs.bounding_box,
    timeout_seconds: 3,
  });
}
```

## Coordinate system

- Vision observations come back in **normalized** coordinates (0..1, origin bottom-left).
- `interceptor macos overlay start` accepts either `anchor: "normalized"` (same space) or absolute pixel rects.
- Multi-display: pass `display_id` to anchor to a specific display.

## Performance

- Vision on a 4K display: ~200-400ms for faces, ~500-1500ms for OCR.
- Overlay spawn: ~50ms.
- Chain vision → overlay in <1 s total; faster with cached capture frames (`mac_capture_start` then multiple vision calls per frame).

## Limits

- Vision results reflect the state at call time. For live HUDs, poll at 5-10 Hz.
- HTML overlays can't read screen pixels — compose annotations from the JSON you already have.
