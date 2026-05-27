import Foundation
import AppKit
import ApplicationServices
import CoreFoundation
import CoreImage
import CoreMedia
import ImageIO
import Network
import UniformTypeIdentifiers
#if canImport(OSLog)
import OSLog
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(Speech)
import Speech
import AVFoundation
#endif

// `interceptor macos monitor` orchestrator. Concurrent multi-session via
// `runtimes: [sid: MonitorRuntime]` lets the bridge run N sessions at once,
// each with its own AX / workspace / input / tap / source state.
// The CGEventTap fallback (`--tap`) is wired through MonitorTapBridge, which
// runs at kCGSessionEventTap placement (no root, Accessibility-gated).
//
// Persistence shape mirrors the browser monitor (shared/monitor-artifacts.ts).
// Optional sources opt-in via `--include` flag (clipboard / files / network /
// log / notifications / speech) and the `--frames N` / `--vision-text` flags.
//
// TCC preflight is the first thing `start` does: AXIsProcessTrusted must be
// true before any AX observer or NSEvent global monitor is created.

final class MonitorDomain: DomainHandler, @unchecked Sendable {
    private let lock = NSLock()
    // Phase 5 — concurrent multi-session map. Each runtime owns its own AX /
    // workspace / input / tap bridges plus optional source state.
    var runtimes: [String: MonitorRuntime] = [:]

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "start":   startSession(action, completion: completion)
        case "stop":    stopSession(action: action, reason: "user_stop", completion: completion)
        case "pause":   pauseSession(action: action, completion: completion)
        case "resume":  resumeSession(action: action, completion: completion)
        case "status":  statusSession(action: action, completion: completion)
        case "tail":    tailEvents(action, completion: completion)
        case "list":    listSessions(completion: completion)
        case "export":  exportSession(action, completion: completion)
        default:        notImplemented(sub, completion: completion)
        }
    }

    // MARK: - lifecycle: start

    private func startSession(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        // Accessibility preflight (shared across sessions).
        let axTrusted = AXIsProcessTrusted()
        if !axTrusted {
            var err = WireFormat.error("missing_tcc:Accessibility")
            err["remediation"] = "interceptor macos trust --accessibility-prompt"
            err["exitCode"] = 2
            completion(err)
            return
        }

        let instruction = action["instruction"] as? String
        let taskId = action["taskId"] as? String
        let includes = parseSet(action["include"])
        let excludes = parseSet(action["exclude"])
        let scope = parseScope(action)
        let framesPerSec = (action["frames"] as? Int) ?? 0
        let visionText = (action["visionText"] as? Bool) ?? false
        // Frame encoding knobs. Default jpeg q=80 mirrors CaptureDomain
        // ("WebP added to format union; default jpeg with q80"). Naive PNG
        // is 10-20× larger and was the wrong default — fixed in this revision.
        let frameFormat = (action["frameFormat"] as? String) ?? "jpeg"
        let frameQuality = (action["frameQuality"] as? Int) ?? 80
        let frameMaxLongEdge = (action["frameMaxLongEdge"] as? Int) ?? 0
        let includeMouseMoved = excludes.contains("mouse-moved") == false && includes.contains("mouse-moved")
        let excludeKey = excludes.contains("key")
        let useTap = (action["tap"] as? Bool) ?? false

        // Screen recording preflight if --frames or --vision-text.
        var screenRecordingTcc: Bool? = nil
        if framesPerSec > 0 || visionText {
            #if canImport(ScreenCaptureKit)
            let granted = CGPreflightScreenCaptureAccess()
            screenRecordingTcc = granted
            if !granted {
                var err = WireFormat.error("missing_tcc:ScreenRecording")
                err["remediation"] = "interceptor macos trust --screen-prompt"
                err["exitCode"] = 3
                completion(err)
                return
            }
            #else
            completion(WireFormat.error("screen recording requested but ScreenCaptureKit not available"))
            return
            #endif
        }

        // sid: 8-char lowercase hex.
        let sid = String(UUID().uuidString.prefix(8)).lowercased()
        let tcc = MonitorTccSnapshot(
            accessibility: axTrusted,
            screenRecording: screenRecordingTcc,
            microphone: nil
        )
        let session = MonitorSession(
            id: sid,
            taskId: taskId,
            instruction: instruction,
            startTime: Date(),
            scope: scope,
            includes: includes,
            excludes: excludes,
            tcc: tcc
        )
        let runtime = MonitorRuntime(session: session, domain: self)

        // Wire bridge callbacks to record into THIS session.
        runtime.axBridge.setCallback { [weak self, weak runtime] event, data in
            guard let r = runtime else { return }
            self?.recordEvent(runtime: r, event: event, data: data)
        }
        runtime.workspaceBridge.setCallback { [weak self, weak runtime] event, data in
            guard let r = runtime else { return }
            self?.recordEvent(runtime: r, event: event, data: data)
        }
        runtime.workspaceBridge.setAppLifecycleHooks(
            launch: { [weak self, weak runtime] pid, bundleId, name in
                guard let self = self, let r = runtime else { return }
                if r.session.scope.mode == .all {
                    self.attachToPid(runtime: r, pid: pid, bundleId: bundleId, appName: name)
                }
            },
            terminate: { [weak runtime] pid in
                runtime?.axBridge.detach(pid: pid)
            }
        )
        runtime.inputBridge.setCallback { [weak self, weak runtime] event, data in
            guard let r = runtime else { return }
            self?.recordEvent(runtime: r, event: event, data: data)
        }
        runtime.tapBridge.setCallback { [weak self, weak runtime] event, data in
            guard let r = runtime else { return }
            self?.recordEvent(runtime: r, event: event, data: data)
        }

        // Register the runtime BEFORE kicking off bridges so concurrent
        // events arriving on async queues find the right session.
        lock.lock()
        runtimes[sid] = runtime
        lock.unlock()

        // Initial AX attachments.
        let initialPids = resolveInitialPids(scope: scope)
        if initialPids.isEmpty && scope.mode != .all {
            recordEvent(runtime: runtime, event: "scope_warning", data: ["reason": "no apps matched initial scope"])
        }
        for (pid, bundleId, appName) in initialPids {
            attachToPid(runtime: runtime, pid: pid, bundleId: bundleId, appName: appName)
        }

        // Start workspace + input always.
        runtime.workspaceBridge.start()
        runtime.inputBridge.start(includeMouseMoved: includeMouseMoved, excludeKey: excludeKey)

        // CGEventTap fallback when --tap is set. Records its own structured
        // `tap_unavailable` event if creation fails.
        if useTap {
            let ok = runtime.tapBridge.start()
            runtime.tapActive = ok
            if !ok {
                recordEvent(runtime: runtime, event: "tap_unavailable", data: [
                    "reason": "CGEventTap creation failed (Accessibility TCC may be missing or kCGSessionEventTap was rejected)"
                ])
            }
        }

        // Optional sources, gated by --include.
        if includes.contains("clipboard") { startPasteboardWatch(runtime: runtime) }
        if includes.contains("files") { startFileWatch(runtime: runtime, action: action) }
        if includes.contains("network") { startPathMonitor(runtime: runtime) }
        if includes.contains("log") { startLogPolling(runtime: runtime, action: action) }
        if includes.contains("notifications") { startDistributedNotificationsWatch(runtime: runtime) }
        #if canImport(ScreenCaptureKit)
        if framesPerSec > 0 {
            startFrameCapture(
                runtime: runtime,
                framesPerSec: framesPerSec,
                visionText: visionText,
                format: frameFormat,
                quality: frameQuality,
                maxLongEdge: frameMaxLongEdge
            )
        }
        #endif
        #if canImport(Speech)
        if includes.contains("speech") { startSpeechRecognition(runtime: runtime) }
        #endif

        // Auto-stop timer.
        startAutoStopTimer(runtime: runtime)

        Platform.writeSessionMeta(sid: sid, meta: session.toMetaDict())

        var startData: [String: Any] = [
            "surface": "macos",
            "scope": scope.toDict(),
            "includes": Array(includes).sorted(),
            "tap": runtime.tapActive
        ]
        if let inst = instruction { startData["ins"] = inst }
        if let taskId = taskId { startData["taskId"] = taskId }
        if let bid = session.rootBundleId { startData["rootBundleId"] = bid }
        if let app = session.rootAppName { startData["rootApp"] = app }
        if let pid = session.rootPid { startData["rootPid"] = Int(pid) }
        recordEvent(runtime: runtime, event: "mon_start", data: startData)

        var ok: [String: Any] = [
            "sid": sid,
            "status": "recording",
            "surface": "macos",
            "tcc": tcc.toDict(),
            "tap": runtime.tapActive
        ]
        if let inst = instruction { ok["instruction"] = inst }
        if let taskId = taskId { ok["taskId"] = taskId }
        ok["scope"] = scope.toDict()
        ok["includes"] = Array(includes).sorted()
        ok["sessionDir"] = Platform.sessionDir(sid)
        ok["activeCount"] = lockedRuntimes().count
        completion(WireFormat.success(ok))
    }

    // MARK: - lifecycle: stop / pause / resume / status

    private func stopSession(action: [String: Any], reason: String, completion: @escaping @Sendable ([String: Any]) -> Void) {
        let runtime = lookupRuntime(action: action)
        guard let r = runtime else {
            var err = WireFormat.error("no_active_session")
            err["exitCode"] = 4
            completion(err)
            return
        }
        let s = r.session
        s.endTime = Date()
        s.stopReason = reason
        let summary: [String: Any] = [
            "sid": s.id,
            "duration": s.endTime!.timeIntervalSince(s.startTime),
            "evt": s.evt, "mut": s.mut, "net": s.net, "nav": s.nav, "ax": s.ax,
            "reason": reason
        ]
        let metaSnapshot = s.toMetaDict()

        stopAutoStopTimer(runtime: r)
        r.axBridge.detachAll()
        r.workspaceBridge.stop()
        r.inputBridge.stop()
        r.tapBridge.stop()
        stopPasteboardWatch(runtime: r)
        stopFileWatch(runtime: r)
        stopPathMonitor(runtime: r)
        stopLogPolling(runtime: r)
        stopDistributedNotificationsWatch(runtime: r)
        #if canImport(ScreenCaptureKit)
        stopFrameCapture(runtime: r)
        #endif
        #if canImport(Speech)
        stopSpeechRecognition(runtime: r)
        #endif

        // Record mon_stop while the runtime is still in the map so
        // recordEvent can find it and tally counts.
        recordEvent(runtime: r, event: "mon_stop", data: summary)

        lock.lock()
        runtimes.removeValue(forKey: s.id)
        lock.unlock()

        Platform.writeSessionMeta(sid: s.id, meta: metaSnapshot)
        completion(WireFormat.success(summary))
    }

    private func pauseSession(action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let r = lookupRuntime(action: action) else {
            var err = WireFormat.error("no_active_session")
            err["exitCode"] = 4
            completion(err)
            return
        }
        r.session.paused = true
        recordEvent(runtime: r, event: "mon_pause", data: [:])
        completion(WireFormat.success(["sid": r.session.id, "status": "paused"]))
    }

    private func resumeSession(action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let r = lookupRuntime(action: action) else {
            var err = WireFormat.error("no_active_session")
            err["exitCode"] = 4
            completion(err)
            return
        }
        r.session.paused = false
        recordEvent(runtime: r, event: "mon_resume", data: [:])
        completion(WireFormat.success(["sid": r.session.id, "status": "recording"]))
    }

    private func statusSession(action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let active = lockedRuntimes()
        if active.isEmpty {
            completion(WireFormat.success(["status": "idle"]))
            return
        }
        // If --sid passed, return that one; otherwise return list of active.
        if let sid = action["sid"] as? String, let r = active[sid] {
            completion(WireFormat.success(statusDictFor(runtime: r)))
            return
        }
        let rows = active.values.map { statusDictFor(runtime: $0) }
        completion(WireFormat.success(["sessions": rows, "activeCount": rows.count]))
    }

    private func statusDictFor(runtime r: MonitorRuntime) -> [String: Any] {
        let s = r.session
        return [
            "sid": s.id,
            "surface": "macos",
            "status": s.paused ? "paused" : "recording",
            "duration": Date().timeIntervalSince(s.startTime),
            "counts": ["evt": s.evt, "mut": s.mut, "net": s.net, "nav": s.nav, "ax": s.ax],
            "attachments": s.attachments.map { $0.toDict() },
            "scope": s.scope.toDict(),
            "includes": Array(s.includes).sorted(),
            "tcc": s.tcc.toDict(),
            "tap": r.tapActive
        ]
    }

    // MARK: - read paths: tail / list / export

    private func tailEvents(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sid: String
        if let s = action["sid"] as? String { sid = s }
        else if let r = lookupRuntime(action: action) { sid = r.session.id }
        else {
            completion(WireFormat.error("no_active_session"))
            return
        }
        let limit = (action["limit"] as? Int) ?? 50
        let events = readSessionEvents(sid: sid)
        completion(WireFormat.success(Array(events.suffix(limit))))
    }

    private func listSessions(completion: @escaping @Sendable ([String: Any]) -> Void) {
        let dir = Platform.monitorSessionsDir
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            completion(WireFormat.success([]))
            return
        }
        var rows: [[String: Any]] = []
        for sid in entries.sorted() {
            let metaPath = Platform.sessionMetaPath(sid)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  var meta = obj as? [String: Any] else { continue }
            meta["sid"] = sid
            rows.append(meta)
        }
        completion(WireFormat.success(rows))
    }

    private func exportSession(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let sid = action["sid"] as? String else {
            completion(WireFormat.error("export requires a sid"))
            return
        }
        let format = (action["format"] as? String) ?? "timeline"
        let events = readSessionEvents(sid: sid)
        let metaPath = Platform.sessionMetaPath(sid)
        let metaData = (try? Data(contentsOf: URL(fileURLWithPath: metaPath))) ?? Data()
        let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] ?? [:]
        let instruction = meta["instruction"] as? String

        switch format {
        case "json":
            completion(WireFormat.success(events))
        case "plan":
            completion(WireFormat.success(MonitorReplayPlanner.generateReplayPlan(events: events, instruction: instruction)))
        default:
            completion(WireFormat.success(MonitorReplayPlanner.generateTimeline(events: events, instruction: instruction)))
        }
    }

    // MARK: - helpers

    /// Resolves the runtime for an action. Honors --sid if present; otherwise
    /// returns the single active runtime when there's exactly one, or nil.
    private func lookupRuntime(action: [String: Any]) -> MonitorRuntime? {
        let active = lockedRuntimes()
        if let sid = action["sid"] as? String, let r = active[sid] {
            return r
        }
        if active.count == 1 { return active.values.first }
        return nil
    }

    func lockedRuntimes() -> [String: MonitorRuntime] {
        lock.lock(); defer { lock.unlock() }
        return runtimes
    }

    func recordEvent(runtime: MonitorRuntime, event: String, data: [String: Any]) {
        let s = runtime.session
        let lifecycle = event == "mon_start" || event == "mon_stop" || event == "mon_pause" || event == "mon_resume"
        if s.paused, !lifecycle { return }
        var enriched = data
        if let taskId = s.taskId { enriched["taskId"] = taskId }
        enriched["s"] = s.nextSeq()
        s.tally(event: event)
        Platform.appendMonitorEvent(sid: s.id, event: event, data: enriched)
    }

    private func attachToPid(runtime: MonitorRuntime, pid: pid_t, bundleId: String?, appName: String?) {
        let accepted = runtime.axBridge.attach(pid: pid)
        let attachment = MonitorAttachment(
            key: "pid:\(pid)",
            pid: pid,
            bundleIdentifier: bundleId,
            appName: appName,
            attachedAt: Int64(Date().timeIntervalSince1970 * 1000),
            detachedAt: nil,
            axNotifications: accepted,
            reason: "scope_attach"
        )
        runtime.session.attachments.append(attachment)
        if runtime.session.rootPid == nil {
            runtime.session.rootPid = pid
            runtime.session.rootBundleId = bundleId
            runtime.session.rootAppName = appName
        }
        recordEvent(runtime: runtime, event: "mon_attach", data: [
            "pid": Int(pid),
            "app": appName ?? "",
            "bundleId": bundleId ?? "",
            "ax": accepted
        ])
    }

    private func resolveInitialPids(scope: MonitorScope) -> [(pid_t, String?, String?)] {
        switch scope.mode {
        case .frontmost:
            if let app = NSWorkspace.shared.frontmostApplication {
                return [(app.processIdentifier, app.bundleIdentifier, app.localizedName)]
            }
            return []
        case .apps:
            return NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String?, String?)? in
                let name = app.localizedName ?? ""
                let bid = app.bundleIdentifier ?? ""
                if scope.apps.contains(name) || scope.apps.contains(bid) {
                    return (app.processIdentifier, app.bundleIdentifier, app.localizedName)
                }
                return nil
            }
        case .all:
            return NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier, $0.localizedName) }
        }
    }

    private func parseSet(_ raw: Any?) -> Set<String> {
        if let arr = raw as? [String] { return Set(arr) }
        if let s = raw as? String {
            return Set(s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return []
    }

    private func parseScope(_ action: [String: Any]) -> MonitorScope {
        if let allFlag = action["allApps"] as? Bool, allFlag { return .all() }
        if let apps = action["apps"] as? [String], !apps.isEmpty { return .apps(apps) }
        if let appsCsv = action["apps"] as? String, !appsCsv.isEmpty {
            return .apps(appsCsv.split(separator: ",").map { String($0) })
        }
        if let app = action["app"] as? String, !app.isEmpty { return .apps([app]) }
        return .frontmost()
    }

    private func readSessionEvents(sid: String) -> [[String: Any]] {
        let path = Platform.sessionEventsPath(sid)
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in data.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let bytes = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: bytes),
               let row = obj as? [String: Any] {
                out.append(row)
            }
        }
        return out
    }

    // MARK: - PHASE 2: clipboard / files / network (per-runtime)

    private func startPasteboardWatch(runtime r: MonitorRuntime) {
        r.lastPasteboardChangeCount = NSPasteboard.general.changeCount
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self, weak r] in
            guard let self = self, let r = r else { return }
            let pb = NSPasteboard.general
            let cur = pb.changeCount
            if cur != r.lastPasteboardChangeCount {
                r.lastPasteboardChangeCount = cur
                let preview = pb.string(forType: .string).map { String($0.prefix(200)) } ?? ""
                let types = pb.types?.map { $0.rawValue } ?? []
                self.recordEvent(runtime: r, event: "clipboard", data: [
                    "changeCount": cur, "types": types, "preview": preview
                ])
            }
        }
        timer.resume()
        r.pasteboardTimer = timer
    }

    private func stopPasteboardWatch(runtime r: MonitorRuntime) {
        r.pasteboardTimer?.cancel()
        r.pasteboardTimer = nil
    }

    private func startFileWatch(runtime r: MonitorRuntime, action: [String: Any]) {
        var paths: [String] = []
        if let p = action["watchPath"] as? String, !p.isEmpty {
            paths.append(NSString(string: p).expandingTildeInPath)
        }
        if let arr = action["watchPaths"] as? [String] {
            for p in arr where !p.isEmpty { paths.append(NSString(string: p).expandingTildeInPath) }
        }
        if paths.isEmpty { return }
        r.fsPaths = paths

        var context = FSEventStreamContext()
        let unmanaged = Unmanaged.passUnretained(r)
        context.info = unmanaged.toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info = info else { return }
            let runtime = Unmanaged<MonitorRuntime>.fromOpaque(info).takeUnretainedValue()
            guard let domain = runtime.domain else { return }
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            for i in 0..<numEvents {
                guard let raw = CFArrayGetValueAtIndex(cfArray, i) else { continue }
                let cfStr = unsafeBitCast(raw, to: CFString.self)
                let path = cfStr as String
                domain.recordEvent(runtime: runtime, event: "file_change", data: ["path": path])
            }
        }

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let s = stream else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        r.fsStream = s
    }

    private func stopFileWatch(runtime r: MonitorRuntime) {
        if let s = r.fsStream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            r.fsStream = nil
        }
        r.fsPaths.removeAll()
    }

    private func startPathMonitor(runtime r: MonitorRuntime) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak r] path in
            guard let self = self, let r = r else { return }
            self.recordEvent(runtime: r, event: "network_path", data: [
                "status": Self.pathStatusString(path.status),
                "isExpensive": path.isExpensive,
                "isConstrained": path.isConstrained,
                "supportsIPv4": path.supportsIPv4,
                "supportsIPv6": path.supportsIPv6,
                "supportsDNS": path.supportsDNS,
                "interfaces": path.availableInterfaces.map { $0.name }
            ])
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        r.pathMonitor = monitor
    }

    private func stopPathMonitor(runtime r: MonitorRuntime) {
        r.pathMonitor?.cancel()
        r.pathMonitor = nil
    }

    private static func pathStatusString(_ s: NWPath.Status) -> String {
        switch s {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .requiresConnection: return "requiresConnection"
        @unknown default: return "unknown"
        }
    }

    // MARK: - PHASE 3: log / notifications

    private func startLogPolling(runtime r: MonitorRuntime, action: [String: Any]) {
        guard #available(macOS 12.0, *) else {
            recordEvent(runtime: r, event: "log_unavailable", data: ["reason": "OSLogStore requires macOS 12+"])
            return
        }
        r.logCursorDate = Date()
        let predicate = (action["logPredicate"] as? String) ?? r.session.rootBundleId.map { "subsystem == \"\($0)\"" }
        r.logPredicate = predicate

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        timer.setEventHandler { [weak self, weak r] in
            guard let self = self, let r = r else { return }
            self.pollLog(runtime: r)
        }
        timer.resume()
        r.logTimer = timer
    }

    @available(macOS 12.0, *)
    private func pollLog(runtime r: MonitorRuntime) {
        guard let cursor = r.logCursorDate else { return }
        do {
            let store = try OSLogStore.local()
            let position = store.position(date: cursor)
            var pred: NSPredicate? = nil
            if let p = r.logPredicate, !p.isEmpty {
                pred = NSPredicate(format: p)
            }
            let entries = try store.getEntries(at: position, matching: pred)
            for entry in entries {
                if let logEntry = entry as? OSLogEntryLog {
                    recordEvent(runtime: r, event: "log", data: [
                        "level": String(describing: logEntry.level),
                        "subsystem": logEntry.subsystem,
                        "category": logEntry.category,
                        "message": logEntry.composedMessage,
                        "process": logEntry.process
                    ])
                }
            }
            r.logCursorDate = Date()
        } catch {
            recordEvent(runtime: r, event: "log_error", data: ["error": "\(error.localizedDescription)"])
        }
    }

    private func stopLogPolling(runtime r: MonitorRuntime) {
        r.logTimer?.cancel()
        r.logTimer = nil
        r.logCursorDate = nil
        r.logPredicate = nil
    }

    private func startDistributedNotificationsWatch(runtime r: MonitorRuntime) {
        let dnc = DistributedNotificationCenter.default()
        let names = [
            "com.apple.screenIsLocked",
            "com.apple.screenIsUnlocked",
            "com.apple.screensaver.didstart",
            "com.apple.screensaver.didstop",
            "com.apple.menuExtraHostKilled",
            "com.apple.HIToolbox.beginMenuTrackingNotification",
            "com.apple.HIToolbox.endMenuTrackingNotification"
        ]
        for name in names {
            let token = dnc.addObserver(forName: NSNotification.Name(name), object: nil, queue: nil) { [weak self, weak r] note in
                guard let self = self, let r = r else { return }
                self.recordEvent(runtime: r, event: "notification", data: [
                    "name": note.name.rawValue,
                    "source": "distributed"
                ])
            }
            r.distNotificationObservers.append(token)
        }
    }

    private func stopDistributedNotificationsWatch(runtime r: MonitorRuntime) {
        let dnc = DistributedNotificationCenter.default()
        for o in r.distNotificationObservers { dnc.removeObserver(o) }
        r.distNotificationObservers.removeAll()
    }

    // MARK: - PHASE 4: frames / OCR / speech

    #if canImport(ScreenCaptureKit)
    @available(macOS 12.3, *)
    private func startFrameCapture(
        runtime r: MonitorRuntime,
        framesPerSec: Int,
        visionText: Bool,
        format: String,
        quality: Int,
        maxLongEdge: Int
    ) {
        Task { [weak r, weak self] in
            guard let r = r, let self = self else { return }
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = Int(display.width)
                config.height = Int(display.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSec)))
                config.queueDepth = 3
                let output = MonitorCaptureOutput(
                    domain: self,
                    runtime: r,
                    sid: r.session.id,
                    visionText: visionText,
                    format: format,
                    quality: quality,
                    maxLongEdge: maxLongEdge
                )
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInitiated))
                try await stream.startCapture()
                r.captureStream = stream
                r.captureOutput = output
            } catch {
                self.recordEvent(runtime: r, event: "frame_error", data: ["error": "\(error.localizedDescription)"])
            }
        }
    }

    @available(macOS 12.3, *)
    private func stopFrameCapture(runtime r: MonitorRuntime) {
        Task { [weak r] in
            try? await r?.captureStream?.stopCapture()
            r?.captureStream = nil
            r?.captureOutput = nil
        }
    }
    #endif

    #if canImport(Speech)
    private func startSpeechRecognition(runtime r: MonitorRuntime) {
        SFSpeechRecognizer.requestAuthorization { [weak self, weak r] status in
            guard let self = self, let r = r else { return }
            guard status == .authorized else {
                self.recordEvent(runtime: r, event: "speech_unavailable", data: ["reason": "authorization \(status.rawValue)"])
                return
            }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                self.recordEvent(runtime: r, event: "speech_unavailable", data: ["reason": "recognizer not available"])
                return
            }
            DispatchQueue.main.async {
                self.spinUpSpeechEngine(runtime: r, recognizer: recognizer)
            }
        }
    }

    private func spinUpSpeechEngine(runtime r: MonitorRuntime, recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }

        let task = recognizer.recognitionTask(with: request) { [weak self, weak r] result, error in
            guard let self = self, let r = r else { return }
            if let res = result {
                self.recordEvent(runtime: r, event: "speech_segment", data: [
                    "text": res.bestTranscription.formattedString,
                    "isFinal": res.isFinal
                ])
            }
            if let e = error {
                self.recordEvent(runtime: r, event: "speech_unavailable", data: ["reason": "\(e.localizedDescription)"])
            }
        }

        do {
            engine.prepare()
            try engine.start()
            r.speechEngine = engine
            r.speechRequest = request
            r.speechTask = task
        } catch {
            recordEvent(runtime: r, event: "speech_unavailable", data: ["reason": "engine start failed: \(error.localizedDescription)"])
        }
    }

    private func stopSpeechRecognition(runtime r: MonitorRuntime) {
        r.speechTask?.cancel()
        r.speechRequest?.endAudio()
        r.speechEngine?.stop()
        r.speechEngine?.inputNode.removeTap(onBus: 0)
        r.speechTask = nil
        r.speechRequest = nil
        r.speechEngine = nil
    }
    #endif

    // MARK: - PHASE 5: retention timers (per-runtime)

    private func startAutoStopTimer(runtime r: MonitorRuntime) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60))
        timer.setEventHandler { [weak self, weak r] in
            guard let self = self, let r = r else { return }
            if Date().timeIntervalSince(r.session.startTime) >= MonitorRuntime.sessionMaxDurationSeconds {
                self.stopSession(action: ["sid": r.session.id], reason: "session_timeout_24h") { _ in }
                return
            }
            let path = Platform.sessionEventsPath(r.session.id)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64,
               size > MonitorRuntime.sessionMaxBytesPerFile {
                self.rotateSessionEvents(sid: r.session.id, runtime: r)
            }
        }
        timer.resume()
        r.autoStopTimer = timer
    }

    private func stopAutoStopTimer(runtime r: MonitorRuntime) {
        r.autoStopTimer?.cancel()
        r.autoStopTimer = nil
    }

    private func rotateSessionEvents(sid: String, runtime r: MonitorRuntime) {
        let dir = Platform.sessionDir(sid)
        let cur = Platform.sessionEventsPath(sid)
        var idx = 1
        while FileManager.default.fileExists(atPath: dir + "/events.jsonl.\(idx)") {
            idx += 1
        }
        let archive = dir + "/events.jsonl.\(idx)"
        do {
            try FileManager.default.moveItem(atPath: cur, toPath: archive)
            recordEvent(runtime: r, event: "rotation", data: ["archived": archive, "index": idx])
        } catch {
            Platform.log("MonitorDomain: rotation failed sid=\(sid) error=\(error.localizedDescription)")
        }
    }
}

// Frame output handler. Saves frames to <session-dir>/frames/ using
// CaptureDomain's shared encoder so default jpeg q=80 produces 10-20× smaller
// files than naive PNG. Optional --frame-max-long-edge resizes at capture
// time, mirroring the existing `--target-max-long-edge` knob on
// `interceptor macos screenshot`. Optionally runs VNRecognizeTextRequest per
// frame for ocr_text events.
#if canImport(ScreenCaptureKit)
@available(macOS 12.3, *)
final class MonitorCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    weak var domain: MonitorDomain?
    weak var runtime: MonitorRuntime?
    let sid: String
    let visionText: Bool
    let format: String      // "jpeg" | "png" | "webp"
    let quality: Int        // 0..100; ignored for png
    let maxLongEdge: Int    // 0 = no resize; otherwise scale so max(w,h) == this
    private var frameCount = 0

    init(
        domain: MonitorDomain?,
        runtime: MonitorRuntime?,
        sid: String,
        visionText: Bool,
        format: String = "jpeg",
        quality: Int = 80,
        maxLongEdge: Int = 0
    ) {
        self.domain = domain
        self.runtime = runtime
        self.sid = sid
        self.visionText = visionText
        self.format = format.lowercased()
        self.quality = max(0, min(100, quality))
        self.maxLongEdge = max(0, maxLongEdge)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let framesDir = Platform.sessionDir(sid) + "/frames"
        try? FileManager.default.createDirectory(atPath: framesDir, withIntermediateDirectories: true)
        let frameIndex = frameCount
        frameCount += 1
        let ext = format == "png" ? "png" : (format == "webp" ? "webp" : "jpeg")
        let path = framesDir + "/\(String(format: "%06d", frameIndex)).\(ext)"

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()
        guard let rawCg = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        // Resize if requested.
        let cg: CGImage
        if maxLongEdge > 0 {
            let longest = max(rawCg.width, rawCg.height)
            if longest > maxLongEdge {
                let scale = Double(maxLongEdge) / Double(longest)
                let newW = Int(Double(rawCg.width) * scale)
                let newH = Int(Double(rawCg.height) * scale)
                cg = CaptureDomain.resize(cgImage: rawCg, width: newW, height: newH) ?? rawCg
            } else {
                cg = rawCg
            }
        } else {
            cg = rawCg
        }

        guard let data = CaptureDomain.encode(cgImage: cg, format: format, quality: quality) else {
            // Surface encoder failures as a structured event instead of silently
            // dropping frames. Most common cause is `--frame-format webp` on a
            // macOS build where CGImageDestination rejects the WebP UTType.
            if let r = runtime, let d = domain {
                d.recordEvent(runtime: r, event: "frame_encode_error", data: [
                    "format": format,
                    "quality": quality,
                    "w": cg.width,
                    "h": cg.height
                ])
            }
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))

        if let r = runtime, let d = domain {
            d.recordEvent(runtime: r, event: "frame", data: [
                "path": path,
                "w": cg.width,
                "h": cg.height,
                "bytes": data.count,
                "format": format,
                "quality": quality
            ])
            if visionText { d.runOCROnImage(runtime: r, cg: cg, framePath: path) }
        }
    }
}
#endif

extension MonitorDomain {
    #if canImport(Vision)
    func runOCROnImage(runtime r: MonitorRuntime, cg: CGImage, framePath: String) {
        let request = VNRecognizeTextRequest { [weak self, weak r] req, _ in
            guard let self = self, let r = r else { return }
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            let blocks = observations.prefix(64).map { obs -> [String: Any] in
                let top = obs.topCandidates(1).first
                return [
                    "text": top?.string ?? "",
                    "confidence": top?.confidence ?? 0,
                    "rect": [
                        "x": obs.boundingBox.origin.x, "y": obs.boundingBox.origin.y,
                        "w": obs.boundingBox.size.width, "h": obs.boundingBox.size.height
                    ]
                ]
            }
            self.recordEvent(runtime: r, event: "ocr_text", data: ["frame": framePath, "blocks": Array(blocks)])
        }
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
    }
    #endif
}
