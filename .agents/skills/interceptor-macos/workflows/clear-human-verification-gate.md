# ClearHumanVerificationGate

You are clearing a **human-verification / CAPTCHA gate** that is blocking a page in the user's signed-in browser — reCAPTCHA, Cloudflare Turnstile, hCaptcha, or a generic "I'm not a robot" / "press & hold" widget. These gates render their interactive control inside a **cross-origin iframe**, which defeats every page-level automation path: the checkbox has no browser-surface DOM ref, `eval --main` cannot reach into the iframe (cross-origin), and the macOS AX tree exposes only the tab title, not the web-area control. The one thing that works is a **real OS-level trusted click** placed at the widget's screen coordinates — which is what this surface is for.

This is the sibling of [`trusted-input-gate.md`](trusted-input-gate.md): same `--os` HID-input primitive, but the target is a cross-origin widget you must locate by **coordinate mapping** rather than by ref.

## Authorization first — read this

Only do this on **the user's own machine, their own signed-in session, to get past friction on a site they are legitimately using.** A real logged-in browser with normal reputation is *meant* to pass these — you are removing accidental friction, not breaking access control. Do **not** build or run anything that defeats CAPTCHAs at scale, farms tokens, rotates identities/proxies to evade rate limits, or targets sites the user has no standing on. If the gate is protecting someone else's resource or the intent is mass automation, stop and say so. When a human is at the keyboard, prefer asking them to click it — one human click from a trusted session clears instantly and is the honest path.

## Detect the gate

You have hit one of these when a page read comes back near-empty and any of:

- **URL** contains `/nocaptcha`, `/cdn-cgi/challenge`, `/recaptcha/`, `hcaptcha.com`, `challenges.cloudflare.com`, `/sorry/` (Google), or `?__cf_chl`.
- **Title** is "Just a moment…", "Human verification", "Attention Required", "Verifying you are human".
- An **iframe** exists with `title="reCAPTCHA"`, `title*="hCaptcha"`, or `src*="turnstile"` / `src*="challenges.cloudflare"`.

Quick probe from the browser surface (works when the host page's CSP allows the extension's eval bypass):

```bash
interceptor eval --main 'JSON.stringify([].map.call(document.querySelectorAll("iframe"),f=>({t:f.title,s:(f.src||"").slice(0,40)})))'
```

## Provider map (what you are up against)

| Provider | Visible control | After click |
|---|---|---|
| **reCAPTCHA v2** | "I'm not a robot" checkbox (anchor iframe) | Often passes on reputation; may pop a 3×3 image grid |
| **reCAPTCHA v3 / invisible** | nothing | Pure score — no click to make; a clean signed-in session usually passes. Reload, don't fight it |
| **Cloudflare Turnstile** | single checkbox (managed) | Usually a brief verify spinner; rarely interactive beyond the checkbox |
| **hCaptcha** | checkbox → image grid ("select all …") | Grid almost always appears |
| **Generic** | checkbox / "press & hold" button | Hold = use `drag` start≈end with a dwell, or `--os` mousedown/up |

Invisible/score gates (v3, Turnstile managed-pass) have **no target to click** — a reload from the real session is the move, not a coordinate click.

## The technique — locate, map, trusted-click

The robust, DPI- and scale-independent method maps a **screenshot pixel** to a **screen point** through the window's AX frame. It needs no assumptions about chrome height or `devicePixelRatio`.

### 1. Confirm the gate window and keep focus stable

```bash
interceptor macos frontmost                       # is the browser already frontmost?
interceptor macos windows --app "Brave Browser"   # find the gate window's frame {x,y,width,height}
```

- `--os` clicks land on whatever window is **topmost at those screen points**, so the browser must be frontmost and the gate tab visible.
- **`app activate` can trigger a tiling reflow that MOVES the window.** Activate **once**, let it settle, then re-read the frame. Do not re-activate between locate and click.
- Stay on the **macOS surface** for the whole sequence. Browser-surface commands (`eval`, `tab`) can let another app steal focus mid-flow.

### 2. Capture the gate to a real image and find the control

```bash
interceptor macos screenshot --app "Brave Browser" --save --target-max-long-edge 1568
# -> returns { filePath, width(W), height(H), originalWidth, originalHeight }
```

`--save` writes a file and returns its `filePath`. (The browser-surface `screenshot --out` returns a data-URL to stdout instead of writing a file — use `macos screenshot --save` here.) Read the file with vision to find the control's pixel center `(px, py)` in the `W×H` image. For tiny or ambiguous image-grid tiles, crop the grid region and upscale ~2× before reading, so identification is accurate.

Optional precise rect (when CSP allows eval): `document.querySelector('iframe[title="reCAPTCHA"]').getBoundingClientRect()` gives the widget rect in viewport CSS px — but the screenshot+frame method below is what you actually click through, because it survives DPI scaling and chrome offsets.

### 3. Map image pixel → screen point through the frame

For window frame `{fx, fy, fw, fh}` and screenshot `W×H`:

```
screen_x = fx + (px / W) * fw
screen_y = fy + (py / H) * fh
```

This ratio mapping is exact regardless of Retina backing scale or "more space" display modes (which produce odd `devicePixelRatio` like 2.5). Re-fetch the frame before each click batch in case the window moved.

### 4. Trusted click

```bash
interceptor macos click <screen_x>,<screen_y> --os
```

`--os` posts through `CGEvent.post(.cghidEventTap)` with HID source state — the gate sees real-hardware input, which synthetic events fail. Coordinates are comma-separated, no space. (There is **no** coordinate cursor-move primitive — `move` is ref-only — so you cannot simulate cursor travel; rely on the session's reputation.)

## Image challenges — accuracy AND speed

If a 3×3 grid appears ("Select all images with a **bus**"):

1. **Read the grid type.** "Click verify once there are none left" = **dynamic** (each correct tile fades and is replaced — re-capture after each click and keep solving until none remain). No such line = **static** (select all matching, then verify once).
2. **Identify accurately.** Crop the grid region, upscale ~2×, read it, list the matching tile centers.
3. **Map every target tile center + the VERIFY button** through the frame (step 3).
4. **Solve FAST — this is the part that fails.** Image challenges **expire in ~1–2 minutes.** Batch *all* tile clicks **and** VERIFY into **one** call (≈10 s end-to-end). A correct-but-slow solve (lots of crop/read/confirm round-trips) will return "Verification challenge expired" even though every tile was right. For static grids, skip the intermediate confirmation screenshot.

```bash
# static grid: click matching tiles + VERIFY in one fast batch
for xy in "589,513" "907,513" "748,673"; do interceptor macos click $xy --os; done
interceptor macos click 920,957 --os   # VERIFY
```

## Verify it cleared

```bash
interceptor macos screenshot --app "Brave Browser" --save --target-max-long-edge 1568
```

Read it. **Pass** = the URL leaves the challenge path (e.g. `/nocaptcha` → real content) or the checkbox shows a green check. **Expired** ("check the checkbox again") = you were too slow — re-trigger and solve faster. **New grid** = loop back to the image-challenge steps. If it keeps escalating after 2–3 honest, fast attempts, the session is flagged — stop automating and hand the single click to the user.

## Pitfalls

- **Window moved between locate and click.** Re-fetch the frame after any `app activate`; map and click against the *current* frame.
- **Frontmost stolen.** Another app (often the previous frontmost) grabs focus around browser-surface calls — verify `frontmost` is the browser immediately before each `--os` click.
- **Slow solve expires.** The #1 cause of "I solved it correctly and it still failed." Compress to one batched action.
- **Fighting an invisible/score gate.** reCAPTCHA v3 / Turnstile managed pass have nothing to click — reload from the clean session instead.
- **Sensitive frontmost gate.** The bridge rejects `--os` input when frontmost is a denylisted bundle (password managers, banking, System Settings). Surface the rejection; do not work around it.
- **Endless escalation.** If correct fast solves keep producing new grids, the session reputation is the problem, not your aim. Defer to a human click rather than looping.

## Output format

Report:
- Which provider/gate (detected from URL/title/iframe)
- The locate→map→click path used, with the frame and the computed screen points
- For image grids: the challenge prompt, tiles selected, and end-to-end solve time
- The verification result (URL left the challenge path / green check / expired / new grid)
- Whether you cleared it or handed off to the user, and why
