import Foundation

// MonitorSession is the in-memory record for an active or just-stopped
// monitor session. It mirrors the browser's MonitorSessionMeta shape from
// shared/monitor-artifacts.ts with the surface discriminator set to "macos"
// and a few macOS-only fields (rootPid, rootBundleId, appsObserved, tcc
// snapshot). Persistence is handled by MonitorDomain via
// Platform.appendMonitorEvent + writeSessionMeta — this type is just the
// authoritative live state.

final class MonitorSession: @unchecked Sendable {
    let id: String
    let instruction: String?
    let startTime: Date
    let surface: String = "macos"
    let scope: MonitorScope
    let includes: Set<String>
    let excludes: Set<String>

    var endTime: Date?
    var paused: Bool = false
    var stopReason: String?

    var rootPid: pid_t?
    var rootBundleId: String?
    var rootAppName: String?

    // Counts mirror the browser model — `evt` is total, `mut`/`net`/`nav`
    // exist for cross-surface render parity, plus an `ax` macOS-only counter.
    var evt: Int = 0
    var mut: Int = 0
    var net: Int = 0
    var nav: Int = 0
    var ax: Int = 0

    // Per-PID attachments. Each represents an AXObserver registration.
    var attachments: [MonitorAttachment] = []

    // TCC snapshot at start.
    var tcc: MonitorTccSnapshot

    private var seqCounter: Int = 0
    private let seqLock = NSLock()

    init(
        id: String,
        instruction: String?,
        startTime: Date,
        scope: MonitorScope,
        includes: Set<String>,
        excludes: Set<String>,
        tcc: MonitorTccSnapshot
    ) {
        self.id = id
        self.instruction = instruction
        self.startTime = startTime
        self.scope = scope
        self.includes = includes
        self.excludes = excludes
        self.tcc = tcc
    }

    func nextSeq() -> Int {
        seqLock.lock(); defer { seqLock.unlock() }
        let s = seqCounter
        seqCounter += 1
        return s
    }

    /// Bumps the right counter for an event-name. Called once per persisted
    /// event so the stop summary reflects what was actually written.
    func tally(event: String) {
        evt += 1
        switch event {
        case "layout_change":
            mut += 1
        case "fetch", "xhr", "sse", "network_path":
            net += 1
        case "frontmost", "title_change", "window_create":
            nav += 1
        case "click", "dblclick", "rclick", "input", "change", "key", "scroll",
             "focus", "blur", "selection", "menu_open", "menu_close",
             "menu_select", "sheet", "window_move", "window_resize",
             "window_min", "window_demin":
            ax += 1
        default:
            break
        }
    }

    func toMetaDict() -> [String: Any] {
        var meta: [String: Any] = [
            "artifactVersion": 1,
            "surface": surface,
            "sessionId": id,
            "startedAt": Int(startTime.timeIntervalSince1970 * 1000),
            "status": endTime == nil ? "active" : "stopped",
            "paused": paused,
            "counts": ["evt": evt, "mut": mut, "net": net, "nav": nav, "ax": ax],
            "attachments": attachments.map { $0.toDict() },
            "tcc": tcc.toDict(),
            "scope": scope.toDict(),
            "includes": Array(includes).sorted(),
            "excludes": Array(excludes).sorted()
        ]
        if let inst = instruction { meta["instruction"] = inst }
        if let pid = rootPid { meta["rootPid"] = Int(pid) }
        if let bid = rootBundleId { meta["rootBundleId"] = bid }
        if let app = rootAppName { meta["rootApp"] = app }
        if let end = endTime { meta["endedAt"] = Int(end.timeIntervalSince1970 * 1000) }
        if let reason = stopReason { meta["stopReason"] = reason }
        return meta
    }
}

// Scope describes which apps the session observes.
//   - .frontmost  : current frontmost app at start, plus follow-on focus
//                   switches (NSWorkspace.didActivateApplicationNotification).
//   - .apps([…])  : explicit set by name or bundle id.
//   - .all        : every running PID at start, plus newly-launched ones.
struct MonitorScope: Sendable {
    enum Mode: String, Sendable { case frontmost, apps, all }
    let mode: Mode
    let apps: [String]      // bundle ids or app names; empty for .frontmost / .all

    static func frontmost() -> MonitorScope { .init(mode: .frontmost, apps: []) }
    static func apps(_ list: [String]) -> MonitorScope { .init(mode: .apps, apps: list) }
    static func all() -> MonitorScope { .init(mode: .all, apps: []) }

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["mode": mode.rawValue]
        if !apps.isEmpty { d["apps"] = apps }
        return d
    }
}

struct MonitorAttachment: Sendable {
    let key: String
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String?
    let attachedAt: Int64
    var detachedAt: Int64?
    var axNotifications: [String]
    var reason: String?

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "key": key,
            "pid": Int(pid),
            "attachedAt": attachedAt,
            "axNotifications": axNotifications
        ]
        if let b = bundleIdentifier { d["bundleIdentifier"] = b }
        if let a = appName { d["appName"] = a }
        if let de = detachedAt { d["detachedAt"] = de }
        if let r = reason { d["reason"] = r }
        return d
    }
}

struct MonitorTccSnapshot: Sendable {
    var accessibility: Bool
    var screenRecording: Bool?
    var microphone: Bool?

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["accessibility": accessibility]
        if let s = screenRecording { d["screenRecording"] = s }
        if let m = microphone { d["microphone"] = m }
        return d
    }
}
