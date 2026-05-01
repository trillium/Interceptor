import Foundation
import AppKit
import WebKit

// Transparent, topmost, click-through NSPanel hosting a WKWebView.

final class OverlayPanel: NSPanel {
    var interactive: Bool = false

    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }
}

final class OverlayContentView: NSView {
    var interactive: Bool = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { interactive }
}

struct OverlayContext {
    let id: String
    let panel: OverlayPanel
    let webView: WKWebView?                     // mode == "html"
    let emitterView: OverlayEmitterView?        // mode == "particles"
    let sceneView: OverlaySceneTitansView?      // mode == "scene" (hardcoded titans)
    let scriptView: OverlaySceneScriptView?     // mode == "scene-script" (dynamic)
    let mode: String                            // "html" | "particles" | "scene" | "scene-script"
    let levelName: String
    let interactive: Bool
    let source: String
    let createdAt: Date
    let displayID: CGDirectDisplayID
}

final class OverlayDomain: DomainHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var overlays: [String: OverlayContext] = [:]
    private var panicMonitor: Any?

    init() {
        // Install global panic kill-switch: Ctrl+Option+Cmd+Escape closes every overlay.
        // NSEvent.addGlobalMonitorForEvents observes keys system-wide without consuming them,
        // so this never interferes with other shortcuts.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.panicMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let required: NSEvent.ModifierFlags = [.control, .option, .command]
                if flags == required && event.keyCode == 53 /* Escape */ {
                    self?.panicCloseAll()
                }
            }
            Platform.log("overlay panic hotkey installed: Ctrl+Option+Cmd+Escape")
        }
    }

    private func panicCloseAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let all = Array(self.overlays.values)
            self.overlays.removeAll()
            self.lock.unlock()
            if all.isEmpty { return }
            for ctx in all {
                ctx.webView?.stopLoading()
                ctx.panel.orderOut(nil)
                ctx.panel.close()
            }
            Platform.log("overlay PANIC closed \(all.count) overlay(s) via Ctrl+Option+Cmd+Escape")
            Platform.emitEvent("overlay_panic_closed")
        }
    }

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "start":
            startOverlay(action, completion: completion)
        case "stop":
            stopOverlay(action, completion: completion)
        case "eval":
            evalOverlay(action, completion: completion)
        case "ctl":
            ctlOverlay(action, completion: completion)
        case "verbs":
            verbsOverlay(action, completion: completion)
        case "status":
            statusOverlay(action, completion: completion)
        case "list":
            listOverlays(completion: completion)
        default:
            notImplemented(command, completion: completion)
        }
    }

    // MARK: - start

    private func startOverlay(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let id = (action["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.prefix(8).lowercased().description

        lock.lock()
        if overlays[id] != nil {
            lock.unlock()
            completion(WireFormat.error("overlay id already in use: \(id)"))
            return
        }
        lock.unlock()

        let levelName = (action["level"] as? String) ?? "statusBar"
        let interactive = (action["interactive"] as? Bool) ?? false
        let singleSpace = (action["single_space"] as? Bool) ?? false
        let noFullscreenAux = (action["no_fullscreen_aux"] as? Bool) ?? false
        let timeoutSec: Double? = (action["timeout_seconds"] as? Double)
            ?? (action["timeout_seconds"] as? Int).map { Double($0) }

        // Mode routing. Particles (native CAEmitterLayer) is the transparent path;
        // HTML (WKWebView) is the interactive path but renders opaque on macOS 15+.
        let mode: String
        let source: String
        let loadKind: LoadKind?
        let particlesPreset: String?
        let customEmojis: [String]?
        let particleDensity: Double?
        let particleDirection: String?
        let particleLifetime: Float?
        let particleVelocity: CGFloat?
        let particleSizeScale: CGFloat

        let scenePreset = action["scene"] as? String
        let sceneScriptRaw = action["scene_script"] as? String
        var sceneScriptJson: [String: Any]? = nil
        if let raw = sceneScriptRaw, let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sceneScriptJson = obj
        } else if let path = action["scene_script_file"] as? String,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sceneScriptJson = obj
        }

        if sceneScriptJson != nil {
            mode = "scene-script"
            source = "scene-script"
            loadKind = nil
            particlesPreset = nil; customEmojis = nil; particleDensity = nil; particleDirection = nil
            particleLifetime = nil; particleVelocity = nil; particleSizeScale = 1.0
        } else if let sp = scenePreset, !sp.isEmpty {
            mode = "scene"
            source = "scene:" + sp
            loadKind = nil
            particlesPreset = nil; customEmojis = nil; particleDensity = nil; particleDirection = nil
            particleLifetime = nil; particleVelocity = nil; particleSizeScale = 1.0
        } else if let preset = action["particles"] as? String, !preset.isEmpty {
            mode = "particles"
            source = "particles:" + preset
            loadKind = nil
            particlesPreset = preset
            if let list = action["emojis"] as? [String] { customEmojis = list }
            else if let str = action["emojis"] as? String {
                customEmojis = str.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else { customEmojis = nil }
            particleDensity = (action["density"] as? Double) ?? (action["density"] as? Int).map { Double($0) }
            particleDirection = action["direction"] as? String
            particleLifetime = (action["lifetime"] as? Double).map { Float($0) }
                ?? (action["lifetime"] as? Int).map { Float($0) }
            particleVelocity = (action["velocity"] as? Double).map { CGFloat($0) }
                ?? (action["velocity"] as? Int).map { CGFloat($0) }
            particleSizeScale = (action["size_scale"] as? Double).map { CGFloat($0) }
                ?? (action["size_scale"] as? Int).map { CGFloat($0) }
                ?? 1.0
        } else if let b64 = action["html_b64"] as? String, let data = Data(base64Encoded: b64),
           let html = String(data: data, encoding: .utf8) {
            mode = "html"
            source = (action["source"] as? String) ?? "html"
            loadKind = .html(html)
            particlesPreset = nil; customEmojis = nil; particleDensity = nil; particleDirection = nil
            particleLifetime = nil; particleVelocity = nil; particleSizeScale = 1.0
        } else if let urlStr = action["url"] as? String, let url = URL(string: urlStr) {
            mode = "html"
            source = "url"
            loadKind = .url(url)
            particlesPreset = nil; customEmojis = nil; particleDensity = nil; particleDirection = nil
            particleLifetime = nil; particleVelocity = nil; particleSizeScale = 1.0
        } else {
            completion(WireFormat.error("overlay start requires --particles <preset>, --html <file>, --url <URL>, or --inline"))
            return
        }

        // Resolve target screen
        let requestedDisplay = action["display_id"] as? UInt32 ?? 0
        let screen: NSScreen
        if requestedDisplay != 0, let match = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == requestedDisplay
        }) {
            screen = match
        } else if let main = NSScreen.main {
            screen = main
        } else if let first = NSScreen.screens.first {
            screen = first
        } else {
            completion(WireFormat.error("no NSScreen available"))
            return
        }
        // --visible uses the screen's visibleFrame (menu bar + Dock excluded automatically).
        let useVisible = (action["visible"] as? Bool) ?? false
        let screenFrame = useVisible ? screen.visibleFrame : screen.frame
        let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0

        // Explicit rectangle overrides full-screen. rect = { x, y, width, height } in screen coords.
        // Corner presets via `anchor` for convenience: "tl", "tr", "bl", "br", "top", "bottom", "right", "left".
        let frame: NSRect
        if let rect = action["rect"] as? [String: Any],
           let w = (rect["width"] as? Int).map({ CGFloat($0) }) ?? (rect["width"] as? Double).map({ CGFloat($0) }),
           let h = (rect["height"] as? Int).map({ CGFloat($0) }) ?? (rect["height"] as? Double).map({ CGFloat($0) }) {
            let x = (rect["x"] as? Int).map({ CGFloat($0) }) ?? (rect["x"] as? Double).map({ CGFloat($0) }) ?? screenFrame.origin.x
            let y = (rect["y"] as? Int).map({ CGFloat($0) }) ?? (rect["y"] as? Double).map({ CGFloat($0) }) ?? screenFrame.origin.y
            frame = NSRect(x: x, y: y, width: w, height: h)
        } else if let anchor = action["anchor"] as? String {
            let w = (action["width"] as? Int).map({ CGFloat($0) }) ?? (action["width"] as? Double).map({ CGFloat($0) }) ?? 360
            let h = (action["height"] as? Int).map({ CGFloat($0) }) ?? (action["height"] as? Double).map({ CGFloat($0) }) ?? 200
            let margin: CGFloat = 24
            var x = screenFrame.origin.x + margin
            var y = screenFrame.origin.y + margin
            switch anchor {
            case "tl": x = screenFrame.minX + margin;                    y = screenFrame.maxY - h - margin
            case "tr": x = screenFrame.maxX - w - margin;                y = screenFrame.maxY - h - margin
            case "bl": x = screenFrame.minX + margin;                    y = screenFrame.minY + margin
            case "br": x = screenFrame.maxX - w - margin;                y = screenFrame.minY + margin
            case "top":    x = screenFrame.midX - w/2;                   y = screenFrame.maxY - h - margin
            case "bottom": x = screenFrame.midX - w/2;                   y = screenFrame.minY + margin
            case "right":  x = screenFrame.maxX - w - margin;            y = screenFrame.midY - h/2
            case "left":   x = screenFrame.minX + margin;                y = screenFrame.midY - h/2
            case "center": x = screenFrame.midX - w/2;                   y = screenFrame.midY - h/2
            default: break
            }
            frame = NSRect(x: x, y: y, width: w, height: h)
        } else {
            frame = screenFrame
        }

        // AppKit ops must run on main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let panel = OverlayPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.interactive = interactive
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = !interactive
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false

            panel.level = Self.resolveLevel(levelName)
            if levelName == "screenSaver" {
                Platform.log("overlay \(id): using .screenSaver level — window server may cap this for accessory apps")
            }

            var behavior: NSWindow.CollectionBehavior = [.ignoresCycle]
            if !singleSpace {
                behavior.insert(.canJoinAllSpaces)
            }
            if #available(macOS 13.0, *) {
                behavior.insert(.canJoinAllApplications)
            }
            if !noFullscreenAux {
                behavior.insert(.fullScreenAuxiliary)
            }
            panel.collectionBehavior = behavior

            // Container view — transparent, click-through receiver
            let container = OverlayContentView(frame: panel.contentView?.bounds ?? NSRect(origin: .zero, size: frame.size))
            container.interactive = interactive
            container.autoresizingMask = [.width, .height]
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = container

            var webView: WKWebView? = nil
            var emitterView: OverlayEmitterView? = nil
            var sceneView: OverlaySceneTitansView? = nil
            var scriptView: OverlaySceneScriptView? = nil

            if mode == "scene-script", let json = sceneScriptJson {
                let sv = OverlaySceneScriptView(frame: NSRect(origin: .zero, size: frame.size))
                sv.interactive = interactive
                sv.autoresizingMask = [.width, .height]
                container.addSubview(sv)
                sv.loadScript(json)
                scriptView = sv
                Platform.log("overlay \(id): scene-script loaded (\((json["entities"] as? [[String:Any]])?.count ?? 0) entities, \((json["timeline"] as? [[String:Any]])?.count ?? 0) ops)")
            } else if mode == "scene" {
                // Currently the only scene preset is "titans" (Godzilla vs Kong).
                let sv = OverlaySceneTitansView(frame: NSRect(origin: .zero, size: frame.size))
                sv.interactive = interactive
                sv.autoresizingMask = [.width, .height]
                container.addSubview(sv)
                sceneView = sv
                Platform.log("overlay \(id): scene preset=\(scenePreset ?? "titans")")
            } else if mode == "particles", let preset = particlesPreset {
                // Native CAEmitterLayer — transparent by construction.
                let ev = OverlayEmitterView(frame: NSRect(origin: .zero, size: frame.size))
                ev.interactive = interactive
                ev.autoresizingMask = [.width, .height]
                ev.apply(OverlayEmitterView.preset(preset,
                                                   customEmojis: customEmojis,
                                                   density: particleDensity,
                                                   direction: particleDirection,
                                                   lifetime: particleLifetime,
                                                   velocity: particleVelocity,
                                                   sizeScale: particleSizeScale))
                container.addSubview(ev)
                emitterView = ev
                Platform.log("overlay \(id): particles preset=\(preset) density=\(particleDensity ?? -1)")
            } else if let kind = loadKind {
                // WKWebView path (opaque on macOS 15+, use for interactive HUDs/tooltips).
                // Three-layer transparency best-effort (see R1).
                let config = WKWebViewConfiguration()
                config.suppressesIncrementalRendering = false
                let w = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
                w.autoresizingMask = [.width, .height]
                let drawsBgSel = NSSelectorFromString("setDrawsBackground:")
                if w.responds(to: drawsBgSel) { w.setValue(false, forKey: "drawsBackground") }
                if #available(macOS 13.0, *) { w.underPageBackgroundColor = .clear }
                w.wantsLayer = true
                w.layer?.backgroundColor = NSColor.clear.cgColor
                w.layer?.isOpaque = false
                container.addSubview(w)
                webView = w

                switch kind {
                case .html(let html): w.loadHTMLString(html, baseURL: nil)
                case .url(let url):   w.load(URLRequest(url: url))
                }
            }

            panel.orderFrontRegardless()

            let ctx = OverlayContext(
                id: id,
                panel: panel,
                webView: webView,
                emitterView: emitterView,
                sceneView: sceneView,
                scriptView: scriptView,
                mode: mode,
                levelName: levelName,
                interactive: interactive,
                source: source,
                createdAt: Date(),
                displayID: screenNumber
            )
            self.lock.lock()
            self.overlays[id] = ctx
            self.lock.unlock()

            Platform.log("overlay \(id) started: level=\(levelName) interactive=\(interactive) source=\(source) frame=\(Int(frame.width))x\(Int(frame.height))")

            // Optional auto-teardown timer.
            if let timeout = timeoutSec, timeout > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self = self else { return }
                    self.lock.lock()
                    let ctx = self.overlays.removeValue(forKey: id)
                    self.lock.unlock()
                    if let ctx = ctx {
                        ctx.webView?.stopLoading()
                        ctx.panel.orderOut(nil)
                        ctx.panel.close()
                        Platform.log("overlay \(id) auto-closed after \(timeout)s timeout")
                    }
                }
                Platform.log("overlay \(id) auto-timeout scheduled for \(timeout)s")
            }

            completion(WireFormat.success([
                "id": id,
                "level": levelName,
                "interactive": interactive,
                "source": source,
                "displayID": screenNumber,
                "frame": [
                    "x": Int(frame.origin.x),
                    "y": Int(frame.origin.y),
                    "width": Int(frame.width),
                    "height": Int(frame.height)
                ]
            ]))
        }
    }

    // MARK: - stop

    private func stopOverlay(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let id = action["id"] as? String
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let targets: [OverlayContext]
            if let id = id, let ctx = self.overlays[id] {
                targets = [ctx]
                self.overlays.removeValue(forKey: id)
            } else if id == nil {
                targets = Array(self.overlays.values)
                self.overlays.removeAll()
            } else {
                targets = []
            }
            self.lock.unlock()

            if targets.isEmpty, let id = id {
                completion(WireFormat.error("overlay not found: \(id)"))
                return
            }

            var closed: [String] = []
            for ctx in targets {
                ctx.webView?.stopLoading()
                ctx.panel.orderOut(nil)
                ctx.panel.close()
                closed.append(ctx.id)
                Platform.log("overlay \(ctx.id) stopped")
            }
            completion(WireFormat.success(["stopped": closed]))
        }
    }

    // MARK: - eval

    private func evalOverlay(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let js = action["js"] as? String, !js.isEmpty else {
            completion(WireFormat.error("eval requires js"))
            return
        }
        let id = action["id"] as? String

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let ctx: OverlayContext?
            if let id = id {
                ctx = self.overlays[id]
            } else if self.overlays.count == 1 {
                ctx = self.overlays.values.first
            } else {
                ctx = nil
            }
            self.lock.unlock()

            guard let target = ctx else {
                completion(WireFormat.error(id.map { "overlay not found: \($0)" } ?? "multiple overlays — pass --id"))
                return
            }

            guard let webView = target.webView else {
                completion(WireFormat.error("overlay \(target.id) has no WKWebView (mode=\(target.mode)); eval is only supported on html overlays"))
                return
            }
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    completion(WireFormat.error("eval error: \(error.localizedDescription)"))
                    return
                }
                completion(WireFormat.success(["id": target.id, "result": Self.sanitizeForJSON(result)]))
            }
        }
    }

    // MARK: - ctl / verbs

    private func ctlOverlay(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let id = action["id"] as? String
        let verb = (action["verb"] as? String) ?? ""
        guard !verb.isEmpty else { completion(WireFormat.error("ctl requires --verb <name>")); return }
        // Pre-parse args on the caller thread so we don't capture task-isolated Any across actor hop.
        let args: [String: Any]
        if let d = action["args"] as? [String: Any] {
            // Re-serialize + parse to produce a fresh Sendable tree.
            if let data = try? JSONSerialization.data(withJSONObject: d),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                args = parsed
            } else { args = [:] }
        } else if let s = action["args"] as? String, let data = s.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else {
            args = [:]
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let ctx: OverlayContext?
            if let id = id { ctx = self.overlays[id] }
            else if self.overlays.count == 1 { ctx = self.overlays.values.first }
            else { ctx = nil }
            self.lock.unlock()
            guard let target = ctx else {
                completion(WireFormat.error(id.map { "overlay not found: \($0)" } ?? "no overlay — pass --id or use list"))
                return
            }

            let controllable: OverlayControllable? = target.scriptView ?? target.sceneView ?? target.emitterView
            guard let c = controllable else {
                completion(WireFormat.error("overlay \(target.id) is mode=\(target.mode); no controllable surface (use `overlay eval` for html)"))
                return
            }
            let result = c.perform(verb: verb, args: args)
            completion(WireFormat.success(result))
        }
    }

    private func verbsOverlay(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let id = action["id"] as? String
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let ctx: OverlayContext?
            if let id = id { ctx = self.overlays[id] }
            else if self.overlays.count == 1 { ctx = self.overlays.values.first }
            else { ctx = nil }
            self.lock.unlock()
            guard let target = ctx else {
                completion(WireFormat.error(id.map { "overlay not found: \($0)" } ?? "no overlay"))
                return
            }
            let c: OverlayControllable? = target.scriptView ?? target.sceneView ?? target.emitterView
            completion(WireFormat.success([
                "id": target.id,
                "mode": target.mode,
                "verbs": c?.supportedVerbs ?? []
            ]))
        }
    }

    // MARK: - status / list

    private func statusOverlay(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let id = action["id"] as? String
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let snapshot: OverlayContext?
            if let id = id {
                snapshot = self.overlays[id]
            } else if self.overlays.count == 1 {
                snapshot = self.overlays.values.first
            } else {
                snapshot = nil
            }
            self.lock.unlock()

            guard let ctx = snapshot else {
                completion(WireFormat.error(id.map { "overlay not found: \($0)" } ?? "no overlay — pass --id or use list"))
                return
            }
            completion(WireFormat.success(Self.describe(ctx)))
        }
    }

    private func listOverlays(completion: @escaping @Sendable ([String: Any]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let all = Array(self.overlays.values)
            self.lock.unlock()
            completion(WireFormat.success(all.map(Self.describe)))
        }
    }

    // MARK: - helpers

    private enum LoadKind {
        case html(String)
        case url(URL)
    }

    private static func resolveLevel(_ name: String) -> NSWindow.Level {
        switch name {
        case "statusBar": return .statusBar
        case "mainMenu": return NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        case "floating": return .floating
        case "screenSaver": return .screenSaver
        default: return .statusBar
        }
    }

    @MainActor
    private static func describe(_ ctx: OverlayContext) -> [String: Any] {
        let frame = ctx.panel.frame
        return [
            "id": ctx.id,
            "mode": ctx.mode,
            "level": ctx.levelName,
            "interactive": ctx.interactive,
            "source": ctx.source,
            "displayID": ctx.displayID,
            "isVisible": ctx.panel.isVisible,
            "createdAt": ISO8601DateFormatter().string(from: ctx.createdAt),
            "frame": [
                "x": Int(frame.origin.x),
                "y": Int(frame.origin.y),
                "width": Int(frame.width),
                "height": Int(frame.height)
            ]
        ]
    }

    private static func sanitizeForJSON(_ value: Any?) -> Any {
        guard let value = value else { return NSNull() }
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return String(describing: value)
    }
}
