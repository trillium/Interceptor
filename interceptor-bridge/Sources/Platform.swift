import Foundation

enum Platform {
    static let bridgeSocketPath = "/tmp/interceptor-bridge.sock"
    static let bridgePidPath = "/tmp/interceptor-bridge.pid"
    static let bridgeLogPath = "/tmp/interceptor-bridge.log"
    static let bridgeEventsPath = "/tmp/interceptor-bridge-events.jsonl"
    static let maxEventFileSize = 10 * 1024 * 1024

    // Monitor-session artifacts. The directory mirrors the browser's
    // shared/platform.ts contract (`MONITOR_SESSIONS_DIR`) so the existing
    // CLI in cli/commands/monitor.ts (which prefers session-local files)
    // works for macOS sessions without changes. The env var override matches
    // the CLI's INTERCEPTOR_MONITOR_SESSIONS_DIR lookup.
    static var monitorSessionsDir: String {
        if let override = ProcessInfo.processInfo.environment["INTERCEPTOR_MONITOR_SESSIONS_DIR"], !override.isEmpty {
            return override
        }
        return "/tmp/interceptor-monitor-sessions"
    }

    static func sessionDir(_ sid: String) -> String {
        return monitorSessionsDir + "/" + sid
    }

    static func sessionEventsPath(_ sid: String) -> String {
        return sessionDir(sid) + "/events.jsonl"
    }

    static func sessionMetaPath(_ sid: String) -> String {
        return sessionDir(sid) + "/session.json"
    }

    static func ensureSessionDir(_ sid: String) {
        let dir = sessionDir(sid)
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    static func log(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: bridgeLogPath) {
                if let handle = FileHandle(forWritingAtPath: bridgeLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: bridgeLogPath, contents: data)
            }
        }
    }

    static func writePID() {
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try? pid.write(toFile: bridgePidPath, atomically: true, encoding: .utf8)
    }

    static func cleanupSocket() {
        unlink(bridgeSocketPath)
    }

    static func cleanup() {
        unlink(bridgeSocketPath)
        unlink(bridgePidPath)
    }

    static func emitEvent(_ event: String, data: [String: Any] = [:]) {
        var entry = data
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = event
        guard let jsonData = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: jsonData, encoding: .utf8) else { return }
        let content = line + "\n"
        if let data = content.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: bridgeEventsPath) {
                if let handle = FileHandle(forWritingAtPath: bridgeEventsPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: bridgeEventsPath, contents: data)
            }
        }
    }

    // appendMonitorEvent tees a single line to BOTH the rolling bridge
    // NDJSON (so `monitor tail` against /tmp/interceptor-bridge-events.jsonl
    // still works) AND the session-local events.jsonl. The CLI prefers the
    // session-local file when it exists, falling back to the rolling log.
    static func appendMonitorEvent(sid: String, event: String, data: [String: Any] = [:]) {
        var entry = data
        entry["event"] = event
        entry["sid"] = sid
        if entry["t"] == nil {
            entry["t"] = Int(Date().timeIntervalSince1970 * 1000)
        }
        if entry["timestamp"] == nil {
            entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: jsonData, encoding: .utf8) else { return }
        let payload = (line + "\n").data(using: .utf8) ?? Data()

        // Tee 1: rolling bridge log.
        if FileManager.default.fileExists(atPath: bridgeEventsPath) {
            if let handle = FileHandle(forWritingAtPath: bridgeEventsPath) {
                handle.seekToEndOfFile()
                handle.write(payload)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: bridgeEventsPath, contents: payload)
        }

        // Tee 2: per-session NDJSON.
        ensureSessionDir(sid)
        let sessionPath = sessionEventsPath(sid)
        if FileManager.default.fileExists(atPath: sessionPath) {
            if let handle = FileHandle(forWritingAtPath: sessionPath) {
                handle.seekToEndOfFile()
                handle.write(payload)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: sessionPath, contents: payload)
        }
    }

    /// Atomically write the session.json meta file.
    static func writeSessionMeta(sid: String, meta: [String: Any]) {
        ensureSessionDir(sid)
        guard let json = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) else { return }
        let path = sessionMetaPath(sid)
        try? json.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }
}
