# Interceptor Native — Safety

The native macOS tools are powerful. This page documents the guardrails and your escape hatches.

## Panic hotkey

`Ctrl+Opt+Cmd+Escape` closes every active overlay regardless of owning session or agent. Bridge-side handler — no agent involvement required. Keep it discoverable.

## Permission policy

- **Allow** (observational): `mac_ax_*`, `mac_apps_*`, `mac_frontmost`, `mac_screenshot`, `mac_vision_*`, `mac_nlp_*`, `mac_clipboard_read`, `mac_display_*`, `mac_monitor_*`, `interceptor macos overlay *`, `mac_capture_*`, `mac_audio_*`, `mac_sound_*`, `mac_speech_*`, `mac_scroll`.
- **Ask** (interactive): `mac_click`, `mac_type`, `mac_keys`, `mac_drag`, `mac_app_quit`, `mac_app_hide`, `mac_clipboard_write`.
- **Deny**: none by default — tune per environment.

## Sensitive frontmost-app gate

Before `mac_type` / `mac_keys` / `mac_click(coords)` / `mac_drag` hit the bridge, the host-side identity layer queries `mac_frontmost` and rejects the call if the bundle ID is on the denylist:

- Keychain Access, 1Password, Dashlane, LastPass, Bitwarden
- System Settings
- Chase, Bank of America, Wells Fargo (common banking apps)

Extend the `SENSITIVE_BUNDLE_IDS` list in your host-side identity layer as needed.

## TCC permissions (macOS)

`mac_trust` returns the current grant status. Recommended minimum:

- **Accessibility** — for AX + input
- **Screen Recording** — for capture + vision

Optional:

- **Microphone** — for `mac_listen`
- **Input Monitoring** — for `mac_monitor` global key/click capture

The dashboard surfaces a deep-link to `System Settings → Privacy & Security` when a grant is missing (`GET /api/native/permissions`).

## Overlay budget

- Prefer corner-anchored rects over full-screen.
- Set `timeout_seconds` on decorative overlays.
- `interactive: false` unless you need clicks (otherwise the overlay swallows them).

## Stop control

- Active overlays do NOT block session completion.
- Session shutdown tears down every overlay owned by the session.
- Engine crash recovery: orphan overlays are marked `closed_reason=crash` in `native_overlays` table.

## If something goes wrong

1. `Ctrl+Opt+Cmd+Escape` kills all overlays.
2. `/native-restart` restarts the bridge.
3. `kill $(cat /tmp/interceptor-bridge.pid)` if the bridge is unresponsive.
4. `tccutil reset Accessibility com.interceptor.bridge` as last resort (triggers re-grant on next run).
