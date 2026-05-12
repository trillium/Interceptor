# Native Computer Use (`interceptor macos *`)

Interceptor is the deepest browser automation tool that exists, and it carries that depth through to native macOS — full filesystem, networking, log query, Apple Events, container runtime, and visual overlays — all behind one signed `.app` bundle that macOS TCC tracks correctly.

The native bridge (`interceptor-bridge`) runs as a LaunchAgent and communicates with the daemon over Unix socket. Same CLI vocabulary as the browser side. Same wire format (4-byte LE length prefix + UTF-8 JSON). Same ref system.

## All 43 Domains

The bridge ships 43 domains across reads, drives, capture, networking, recording, overlays, document processing, personal data, and distribution. PRD-66 added 14 new domains plus a UN extension to the existing `notifications` surface.

### Reading the system

| Domain | CLI prefix | Purpose |
|---|---|---|
| Accessibility | `interceptor macos {tree, find, inspect, value, action, focused, windows, resize, move}` | AX tree, element refs, window geometry |
| Apps | `interceptor macos {apps, app, frontmost}` | List/activate/hide/quit/launch apps |
| Files | `interceptor macos files` (legacy: watch / recent / open) | Filesystem watch + recent files |
| **Fs** | `interceptor macos fs {read, write, search}` | Native FileManager + UTType + Spotlight (`NSMetadataQuery`). See [fs.md](fs.md). |
| Health | `interceptor macos health` | HealthKit reads |

### Driving the system

| Domain | CLI prefix | Purpose |
|---|---|---|
| Input | `interceptor macos {click, type, keys, scroll, drag}` | OS-level CGEvent input |
| Menu | `interceptor macos menu` | Frontmost app menu tree + invoke |
| Sensitive | `interceptor macos sensitive` | Sensitive content analysis |
| **Intent** | `interceptor macos intent {dispatch, warmup}` | Apple Events → cross-app verb dispatch via `NSAppleScript`. TCC consent per (bridge, target_app) pair. See [app-intent.md](app-intent.md). |
| **Container** | `interceptor macos container run` | Run an OCI image in Apple's `container` runtime (macOS 26+). See [container-run.md](container-run.md). |

### Capturing & streaming

| Domain | CLI prefix | Purpose |
|---|---|---|
| Capture | `interceptor macos {screenshot, capture}` | ScreenCaptureKit single frame |
| Stream | `interceptor macos stream` | Continuous 30 fps capture |
| Display | `interceptor macos display` | List + create virtual displays |
| Audio | `interceptor macos audio` | System audio + microphone |
| Speech | `interceptor macos {listen, vad}` | Speech recognition + voice activity |
| Sound | `interceptor macos sounds` | Sound classification (300+ types) |
| Vision | `interceptor macos vision` | Faces / OCR / hands / bodies |
| NLP | `interceptor macos nlp` | Entities / sentiment / language |
| Intelligence | `interceptor macos ai` | On-device LLM (Apple Intelligence, macOS 26+) |

### Networking & logs

| Domain | CLI prefix | Purpose |
|---|---|---|
| **Net** (`url`) | `interceptor macos url {get, post}` | URLSession + cookies + ETag + bodyRef sidecar for >64 KB responses. See [url-fetch.md](url-fetch.md). |
| **Log** | `interceptor macos log query` | `OSLogStore` query with subsystem/category/level filters. See [log-query.md](log-query.md). |
| Notifications | `interceptor macos notifications` | Live notification stream |
| Clipboard | `interceptor macos clipboard` | Read / write / tail |
| Trust | `interceptor macos trust` | All TCC permissions + System Settings paths |

### Recording & overlays

| Domain | CLI prefix | Purpose |
|---|---|---|
| Monitor | `interceptor macos monitor {start, stop, pause, resume, status, tail, list, export}` | Record native flows via per-PID `AXObserver` + `NSWorkspace` + `NSEvent` global monitor; persist NDJSON sessions; export `--plan` as a replayable `interceptor macos *` script. Optional sources via `--include clipboard\|files\|network\|log\|notifications\|speech` and co-recording via `--frames N [--vision-text]`. Accessibility TCC always required; Screen Recording / Microphone added when `--frames` / `--include speech` are used. |
| Text | `interceptor macos text` | Read selection / visible / full text from frontmost app |
| Compound | `interceptor macos {open, read, act, inspect}` | Single-call agent ergonomics |
| **Overlay** | `interceptor macos overlay {start, stop, list, status, eval, ctl, verbs}` | Topmost transparent panels — particles (`CAEmitterLayer`), hardcoded Godzilla-vs-Kong (`SpriteKit`), dynamic scene-script (`SpriteKit`), HTML (`WKWebView`). Panic hotkey: `Ctrl+Opt+Cmd+Escape`. See [overlays.md](overlays.md). |

### Documents (PRD-66)

| Domain | CLI prefix | Purpose |
|---|---|---|
| **PDF** | `interceptor macos pdf {info,text,outline,annotations,forms,find,merge,split,...}` | PDFKit (PDFDocument/PDFPage/PDFAnnotation/PDFOutline/PDFSelection). See [document.md](document.md). |
| **Detect** | `interceptor macos detect {types,run,file,stdin}` | NSDataDetector + DDMatch* on macOS 12+. See [document.md](document.md). |
| **Translate** | `interceptor macos translate {status,languages,availability,prepare,text,batch,file,stop}` | Translation framework (macOS 15+). See [document.md](document.md). |
| **Thumbnail** | `interceptor macos thumbnail [batch] <path>` | QuickLookThumbnailing. See [document.md](document.md). |

### Personal data (PRD-66; TCC-gated)

| Domain | CLI prefix | Purpose |
|---|---|---|
| **Auth** | `interceptor macos auth {status,confirm,invalidate,domain-state}` | LocalAuthentication (Touch ID / Face ID / passcode). See [personal-data.md](personal-data.md). |
| **Calendar** | `interceptor macos calendar {status,request,list,events,event,create,update,delete,move,...}` | EventKit events. macOS 14+ for `requestFullAccessToEvents`. |
| **Reminders** | `interceptor macos reminders {status,request,lists,all,incomplete,completed,create,...}` | EventKit reminders. macOS 14+ for `requestFullAccessToReminders`. |
| **Contacts** | `interceptor macos contacts {status,list,contact,me,find,create,update,delete,vcard,changes,...}` | Contacts framework. CNChangeHistoryFetchRequest macOS 10.15+. |
| **Photos** | `interceptor macos photos {status,albums,assets,export,thumbnail,favorite,delete,import,changes,...}` | PhotoKit (PHPhotoLibrary, PHAsset, PHFetchOptions). |
| **Location** | `interceptor macos location {status,current,monitor,geocode,reverse,distance,...}` | CoreLocation + CLGeocoder. |
| **Music** | `interceptor macos music {status,search,library,song,play,pause,now-playing,...}` | MusicKit (catalog macOS 12+; library + ApplicationMusicPlayer macOS 14+). |

### Distribution (PRD-66)

| Domain | CLI prefix | Purpose |
|---|---|---|
| **AppIntent** | `interceptor macos appintent {list,registered,donate,update-parameters,supports}` | AppIntents — 23 declared intents discoverable from Shortcuts/Siri/Spotlight. See [distribution.md](distribution.md). |
| **Maps** | `interceptor macos maps {search,complete,directions,eta,mapitem-open,reverse}` | MapKit local search + directions + ETA. |
| **Share** | `interceptor macos share {services,airdrop,email,message,reading-list,desktop-picture,named,text,url}` | NSSharingService — AirDrop / Mail / Messages / etc. |
| **Notifications (UN extension)** | `interceptor macos notifications {status,request,post,schedule-after,schedule-at,schedule-cron,pending,delivered,cancel,cancel-all,dismiss,dismiss-all,categories,badge}` | UNUserNotificationCenter on top of the existing DistributedNotificationCenter `tail/log` surface. |

## Bundle (`interceptor-bridge.app`)

The bridge ships as a real `.app` bundle, not a bare Mach-O binary. The bundle:

- Is signed with `Developer ID Application: HACKER VALLEY MEDIA, LLC` under the hardened runtime.
- Carries the `com.apple.security.automation.apple-events` entitlement.
- Declares `CFBundleIdentifier=com.interceptor.bridge`, `LSUIElement=true`, and `NS{AppleEvents,Accessibility,ScreenCapture,Microphone}UsageDescription` strings.
- Is registered with LaunchServices (`lsregister -f`) so `tccutil` and **System Settings → Privacy & Security** address it by bundle id.

**First-run launch path** uses `open -gj <bundle>` (LaunchServices) — never `Bun.spawn` of the inner binary directly. The aqua-session ancestry given by LaunchServices is what lets macOS render the TCC consent dialog the first time the bridge sends an Apple Event. The daemon's `spawnBridge()` helper handles this automatically.

## Privacy / TCC tutorial

Per-target Apple Events grants are stored in the macOS TCC database. Reset the entry with:

```bash
tccutil reset AppleEvents com.interceptor.bridge
```

Pre-warm a batch of targets (one consent dialog per target, then never again):

```bash
interceptor macos intent warmup com.apple.Music com.apple.Notes com.apple.Mail
```

## See also

- [overlays.md](overlays.md) — particles / titans / scene-script / HTML modes
- [scene-script-cookbook.md](scene-script-cookbook.md) — DSL recipes for dynamic SpriteKit scenes
- [app-intent.md](app-intent.md) — Apple Events guide, TCC flow, warmup pattern
- [fs.md](fs.md) — fs_read / fs_write / fs_search reference
- [url-fetch.md](url-fetch.md) — bodyRef sidecar pattern
- [log-query.md](log-query.md) — OSLogStore predicate examples
- [container-run.md](container-run.md) — Apple `container` runtime
- [safety.md](safety.md) — panic hotkey, click-through hygiene, fs_write denylist
