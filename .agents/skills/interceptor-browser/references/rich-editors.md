# Rich Editors

## Start with detection

1. Run `interceptor scene profile`.
2. Run `interceptor scene profile --verbose` when capability support is unclear.
3. Prefer menu items, accessible toolbars, and searchable commands before scene geometry.

## Use Canva carefully

- Prefer the accessible side panel to add elements. It is more reliable than raw scene targeting.
- Use `scene list`, `scene hit`, `scene click`, and `scene selected` only after verifying the page reports a usable Canva profile.
- Treat stable `LB...` ids as document-local scene ids, not universal object handles.
- Verify selection by checking for element-level controls, not just the click result.
- Expect some live Canva editor states to fall back to `generic`.

## Use Google Docs as the strongest editor target

- Use `scene text` to read the hidden text model.
- Use `scene text --with-html` when table structure or range offsets matter.
- Use `scene insert "<text>"` once the cursor is inside the writable surface.
- Use menu search or native commands to create structure, then use `scene insert` and `Tab` to populate cells.

## Use Google Slides with stricter limits

- Use `scene slide list`, `scene slide current`, and `scene slide goto <n>` for navigation.
- Treat slide navigation as URL-fragment based. Do not rely on synthetic clicks on filmstrip thumbnails.
- Use `scene notes` and `scene render` for speaker notes and slide images.
- Expect missing write support in some edit flows. `scene insert` is not a general replacement for live slide editing.
- Use `eval --main` only when the native command surface and scene commands cannot finish the task.

## Verify with the right signal

- Verify Canva by changed selection controls.
- Verify Docs by changed hidden HTML/text output.
- Verify Slides by changed current slide, selected object state, or rendered output.

## Canvas-rendered editor input (Docs / Slides / Sheets)

When `scene insert` is not enough — cell-precise table writes, paragraph style shortcuts, anything Docs gates on transient activation — use the pre-load trust override path. `inject-net.js` runs at `document_start` in MAIN world and installs `navigator.userActivation.{isActive,hasBeenActive}` overrides that always return `true`, satisfying the activation gate.

Then via `interceptor eval --main`:

1. **Caret positioning:** dispatch `mousedown`/`mouseup`/`click` on `.kix-canvas-tile-content` with `event.__interceptor_trust = true` at the target pixel. Verify by reading `iwin.getSelection().anchorNode` parent chain for the `<TD>`.
2. **Text entry:** construct keyboard events with the iframe's OWN window — `new iwin.KeyboardEvent(...)` — and dispatch on `idoc`. Set `keyCode`/`which`/`key`/`code` via `Object.defineProperties`.
3. **Printable keys:** keydown → keypress → keyup.
4. **Navigation/control keys** (Tab, Arrow*, Home, End, Escape, Backspace, Delete, modifiers): keydown → keyup ONLY. Never dispatch `keypress` for these — it inserts the ASCII character (Tab=`\t`, ArrowUp=`&`, ArrowLeft=`%`, ArrowRight=`'`).
5. **Tab past last cell of last row creates a new row.** Fill row with N writes and N-1 Tabs; exit with `ArrowDown`.

Full reference: [`use-cases/interaction-skills/canvas-rendered-editor-input.md`](../../../../use-cases/interaction-skills/canvas-rendered-editor-input.md). Worked example: [`use-cases/domain-skills/google-docs/fill-empty-table-cells.md`](../../../../use-cases/domain-skills/google-docs/fill-empty-table-cells.md).

## Canvas camera apps (WebGL viewers)

The same `userActivation` + `__interceptor_trust` foundation drives WebGL camera apps. Pan via dispatched `MouseEvent` (mousedown → mousemove sweep → mouseup) on the canvas; zoom via `WheelEvent { deltaY: ±120 }` or `Minus`/`Equal` keystrokes. Anchor DOM overlays to lat/lng via Web Mercator projection (`pixels per deg lng = 256 * 2^zoom / 360`) and refresh on every URL change. Restyle the rendered view via CSS `filter` on the canvas element. Search-box teleport works in-SPA with the React-aware native value setter (`Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, text)` + dispatched `Enter`).

Full reference: [`use-cases/interaction-skills/canvas-camera-overlays.md`](../../../../use-cases/interaction-skills/canvas-camera-overlays.md) and [`use-cases/interaction-skills/webgl-camera-control.md`](../../../../use-cases/interaction-skills/webgl-camera-control.md).

## Native export capture (any client-side-rendering app)

Modern editor webapps render exports client-side: WebGL/Canvas2D → `Blob` → `URL.createObjectURL` → `<a download>.click()`. To capture the bytes without ever showing a Save dialog:

1. **Patch `URL.createObjectURL`** in MAIN world to log every blob URL the app stages.
2. **Patch `HTMLAnchorElement.prototype.click`** to swallow programmatic auto-downloads on `<a download>` / `blob:` hrefs (real user clicks elsewhere still flow through).
3. **`fetch(blobUrl).then(r => r.arrayBuffer())`** to read the bytes before the app revokes.

Works on any app whose export pipeline goes through a `Blob`. Pair with a layer/asset enumeration step in the host app for bulk export loops.

Full reference: [`use-cases/interaction-skills/blob-export-capture.md`](../../../../use-cases/interaction-skills/blob-export-capture.md).
