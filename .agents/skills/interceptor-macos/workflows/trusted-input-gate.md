# TrustedInputGate

You are completing a flow that requires OS-level trusted input — a native app or web page that filters synthesized `CGEvents` and only accepts events from real hardware (real HID source state). This is the bench S8 workflow and the rare case where the synthetic-first default fails by design.

**Try the default path first.** Synthetic events (the bridge's standard `click`/`type`/`keys`) work on almost everything. The browser-side equivalent — dispatched DOM events with `event.__interceptor_trust = true` — handles most `isTrusted`-checking webapps. Only escalate to `--os` after you've observed synthetic input failing.

## When `--os` is the answer

Look for these symptoms:
- The synthetic call returns successfully but the target acts as if nothing happened.
- The target is a native gate that checks `CGEventSourceGetSourceStateID` against `kCGEventSourceStateHIDSystemState`.
- The target is a webapp that reads `isTrusted` via a cached per-instance own property captured at boot (bypassing the prototype override).
- A banking, payment, or anti-automation page rejects standard input.

In those cases, `--os` flips the bridge to post events through `CGEvent.post(.cghidEventTap)` with `kCGEventSourceStateHIDSystemState`. The OS treats it as real hardware input.

## Verify permissions first

```bash
interceptor macos trust
```

The response shape:
- `accessibility` — must be `granted`. Without it, `CGEvent` posting fails silently.
- `screen_recording` — granted enables capture; not strictly needed for input gates.
- `microphone` / `input_monitoring` — separate consents, not required here.

If accessibility is `denied`, surface the deep link from `trust --walkthrough` so the user can grant it.

## The recipe

```bash
# Type with HID source state — looks like real keyboard input
interceptor macos type "..." --os

# Send keystrokes with HID source state
interceptor macos keys "Meta+S" --os
```

These follow the user's current frontmost app (legacy HID semantics — that's how real keyboards work). For per-PID delivery, prefer the AX path with refs, or `--app`/`--pid` flagged input.

## Worked example: the bench fixture

```bash
# 1. Navigate to the trusted-input page (browser surface)
interceptor open <trusted-input-fixture-url>

# 2. Identify the gate (read the page)
interceptor read --tree-only

# 3. If standard `type` doesn't satisfy the gate, escalate:
interceptor macos keys "Tab" --os                  # focus the input
interceptor macos type "expected text" --os        # HID-level keystrokes

# 4. Verify the page accepted the input
interceptor read --text-only
```

The success criterion is whatever the gate reveals after acceptance — a "success" banner, a new DOM element, a network call. Read for it explicitly.

## Browser-side equivalent (when `--os` is wrong)

For webapps, the synthetic-events-with-trust-marker path is usually the right escalation, not `--os`. Dispatch via `eval --main`:

```javascript
const evt = new MouseEvent('click', { bubbles: true, cancelable: true });
evt.__interceptor_trust = true;
element.dispatchEvent(evt);
```

Combined with the pre-load `userActivation` override (already installed via `inject-net.ts` at `document_start`), this handles transient-activation gates and per-event `isTrusted` checks without going to OS-level CGEvents. Only fall back to `--os` for native HID-source-state checks.

## Pitfalls

- **`--os` follows current frontmost.** It's legacy "drive whatever's visible" semantics. If the user clicked away mid-flow, your keys go to the wrong app. Verify with `interceptor macos frontmost` immediately before each `--os` call.
- **Reaching for `--os` reflexively.** The historical reflex "site checks `isTrusted` → use `--os`" is no longer correct on most sites. The pre-load `userActivation` override + `__interceptor_trust` marker handles the vast majority of webapps. Measure first.
- **Forgetting Accessibility consent.** `CGEvent.post` silently no-ops without it. If a `--os` call returns success but nothing happens, check `trust` first.
- **Sensitive frontmost-app gate.** The bridge rejects `type` / `keys` / `click x,y` / `drag` when frontmost is a denylisted bundle (Keychain, 1Password, Dashlane, LastPass, Bitwarden, System Settings, Chase, Bank of America, Wells Fargo). Surface the rejection to the user — do not try to bypass.

## Output format

Report:
- Why `--os` was needed (the observed symptom of synthetic failing)
- The exact call (`type` / `keys` / `--os`)
- `frontmost` before and after each `--os` call (proof of correct targeting)
- The success indicator from the gate (banner text, new element, response status)
- Whether Accessibility TCC was granted before the call
