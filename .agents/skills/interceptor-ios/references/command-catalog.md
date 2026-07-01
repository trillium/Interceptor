# Interceptor iOS — command catalog

Every command is `interceptor ios <sub> [args] [--on <name>] [--json]`. A phone is
addressed by alias (`--on phone`), by udid (`ios:<udid>`), or omitted when only one
phone is set up. Phones auto-connect on the first drive verb.

## Setup (one-time)

| Command | What it does |
|---|---|
| `interceptor ios setup [<device>] [--team <id>]` | Xcode self-service: build + sign + install + launch the runner using the Apple ID signed into Xcode. |
| `interceptor ios login --apple-id <id> --password <pw> [--code <2fa>]` | No-Xcode path: sign in with the user's own Apple ID (token stored in the Keychain, never the password). One time. |
| `interceptor ios logout` | Drop the stored Apple-ID token. |
| `interceptor ios refresh [<device>]` | Re-sign the installed runner now (also automatic before certificate expiry). |
| `interceptor ios install [<device>]` | Push / refresh the prebuilt agent (operator path). |
| `interceptor ios devices` | Phones with the agent installed, plus aliases, transport (USB/network), and iOS version. |
| `interceptor ios discover` | Full device discovery with toolchain + readiness notes. |
| `interceptor ios status` | Per-phone connection state: `connected` while driving, `disconnected` when installed but idle. |
| `interceptor ios name <device> <alias>` | Alias a phone so you can use `--on <alias>` (e.g. `--on phone`). |

## Drive verbs

| Command | What it does |
|---|---|
| `interceptor ios tree [--filter interactive\|all\|full]` | Ref-tagged element tree of the foreground app. Re-read before acting. |
| `interceptor ios find --label "Send" [--role button]` | Find elements by label and/or role; returns refs + frames. |
| `interceptor ios inspect <ref>` | Element details (type, label, enabled, frame). |
| `interceptor ios click <ref> \| --x N --y N` | Deterministic coordinate tap at the ref's frame center (or raw coordinates). |
| `interceptor ios type <ref> "text"` | Focus the field at `<ref>`, then type. Most reliable text entry — focus is atomic. |
| `interceptor ios keys "text"` | Type into whatever is already focused (append). |
| `interceptor ios scroll [<ref>] --dir up\|down\|left\|right` | Scroll the view (or the element at `<ref>`). |
| `interceptor ios drag <from> <to> [--duration s]` | Drag between two element refs (frame center to frame center). |
| `interceptor ios press home\|lock\|volume-up\|volume-down` | Hardware button. `lock` locks the phone (avoid mid-flow — it blocks launches). |
| `interceptor ios screenshot` | Capture the screen; saved as a VLM-budget-resized JPG. |
| `interceptor ios apps` | Installed apps on the phone (bundle id, name, version). |
| `interceptor ios app launch\|activate\|terminate <bundleId>` | App lifecycle by bundle id (e.g. `com.apple.Preferences`). |

## Addressing

- `--on <alias>` — the friendly name set with `interceptor ios name`.
- `--context ios:<udid>` — explicit context id; also how `interceptor contexts` lists the phone.
- Omit both when exactly one phone is set up.

## Notes

- **Refs are coordinates, not handles.** They are re-minted on every `tree` read, so
  they never go stale the way server-side element ids do — but they only reflect the
  screen at read time. Re-read after any navigation.
- **Unlocked + foreground.** A locked phone refuses app launches. The runner drops on
  idle and re-dials per verb, so chain a `launch` and its follow-up verbs closely.
- **UI only.** Cannot pass Face ID / passcode / Apple Pay or unlock the phone.
- Add `--json` to any command for machine-readable output.
