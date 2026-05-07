// container_run — sandboxed Linux escape hatch via Apple's
// `container` runtime (macOS 26+). This is the full implementation:
// when `/usr/local/bin/container` is present, we execute the requested
// image+command in an ephemeral container (--rm), with mounts, env,
// network policy, and timeout, and return structured stdout/stderr.
//
// stdout/stderr are drained concurrently via `readabilityHandler`
// while the child runs, and the response is resolved from
// `task.terminationHandler` — never via `waitUntilExit` followed by
// `readDataToEndOfFile`, which is the documented Foundation/Pipe deadlock
// pattern when a child writes more than the OS pipe buffer (~16–64 KB)
// before exiting (apple-developer-docs/Foundation/Process/waitUntilExit
// + apple-developer-docs/Foundation/FileHandle/readabilityHandler).

import Foundation
import Darwin

final class ContainerDomain: DomainHandler, @unchecked Sendable {
    private let candidatePaths: [String] = [
        "/opt/homebrew/bin/container",       // Apple silicon Homebrew (default)
        "/usr/local/bin/container",          // Intel Homebrew / direct .pkg install
        "/Applications/container.app/Contents/MacOS/container", // future GUI wrapper
    ]

    private func resolveBinary() -> String? {
        if let envOverride = ProcessInfo.processInfo.environment["INTERCEPTOR_CONTAINER_BIN"],
           FileManager.default.isExecutableFile(atPath: envOverride) {
            return envOverride
        }
        for p in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        switch command {
        case "run":
            handleRun(action, completion: completion)
        default:
            completion(WireFormat.error("container: unknown command \(command)"))
        }
    }

    private func handleRun(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let containerBinary = resolveBinary() else {
            completion(WireFormat.error(
                "container_run: Apple's `container` runtime not found. Searched: \(candidatePaths.joined(separator: ", ")). " +
                "Install via `brew install container` (macOS 26+ required), then `container system start`."
            ))
            return
        }

        guard let image = action["image"] as? String, !image.isEmpty else {
            completion(WireFormat.error("container_run: missing required 'image'"))
            return
        }
        guard let command = action["command"] as? [String], !command.isEmpty else {
            completion(WireFormat.error("container_run: 'command' must be a non-empty string array"))
            return
        }

        var args: [String] = ["run", "--rm"]

        // Network policy
        let network = (action["network"] as? String) ?? "off"
        switch network {
        case "off":
            args.append(contentsOf: ["--network", "none"])
        case "isolated":
            // Apple's container CLI defaults to isolated on macOS 26.
            args.append(contentsOf: ["--network", "default"])
        case "host":
            args.append(contentsOf: ["--network", "host"])
        default:
            args.append(contentsOf: ["--network", "none"])
        }

        // Environment vars
        if let env = action["env"] as? [String: String] {
            for (k, v) in env {
                args.append(contentsOf: ["--env", "\(k)=\(v)"])
            }
        }

        // Mounts: each is { ref?: CyArtifactRef, path: hostPath, mountPath: containerPath, mode: ro|rw }
        if let mounts = action["mounts"] as? [[String: Any]] {
            for m in mounts {
                let hostPath = (m["ref"] as? [String: Any])?["path"] as? String
                    ?? m["hostPath"] as? String
                    ?? m["path"] as? String
                let containerPath = m["mountPath"] as? String ?? hostPath
                let mode = (m["mode"] as? String) ?? "ro"
                guard let host = hostPath, let target = containerPath else { continue }
                let resolved = (host as NSString).expandingTildeInPath
                args.append(contentsOf: ["--volume", "\(resolved):\(target):\(mode)"])
            }
        }

        // Image + command
        args.append(image)
        args.append(contentsOf: command)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: containerBinary)
        task.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        task.standardInput = FileHandle.nullDevice

        // drain stdout/stderr concurrently while the child is
        // running. The lock-protected accumulators are written from the
        // FileHandle's internal dispatch queue (one queue per pipe) and read
        // from `task.terminationHandler` (a third queue). EOF arrives as
        // `availableData.isEmpty`, at which point we clear the handler so
        // the file handle can be released cleanly.
        let stdoutBuffer = LockedData()
        let stderrBuffer = LockedData()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stdoutBuffer.append(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(chunk)
        }

        let startedAt = Date()
        let completionFired = AtomicFlag()

        // hardened timeout. SIGTERM at `timeoutMs`, then SIGKILL
        // after a 2-second grace if the child is still alive — we do not
        // trust children to honour SIGTERM. We use a Sendable `TimerHolder`
        // so the timers can be cancelled from `terminationHandler` (which
        // is itself a Sendable closure under Swift 6 strict concurrency).
        let timeoutMs = (action["timeoutMs"] as? Int) ?? 60000
        let timeoutSec = max(1, timeoutMs / 1000)
        let timers = TimerHolder()
        timers.sigtermTimer = DispatchWorkItem { [weak task] in
            if let t = task, t.isRunning {
                t.terminate()
            }
        }
        timers.sigkillTimer = DispatchWorkItem { [weak task] in
            if let t = task, t.isRunning {
                let pid = t.processIdentifier
                if pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
        }
        if let sigterm = timers.sigtermTimer {
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSec), execute: sigterm)
        }
        if let sigkill = timers.sigkillTimer {
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSec + 2), execute: sigkill)
        }

        // resolve the response in `terminationHandler`. Drain
        // any final bytes still buffered in the pipe (the child has exited
        // so the write side is closed and EOF is guaranteed) before
        // building the response. Calling `availableData` once more here is
        // safe and complements the readabilityHandler accumulators —
        // anything not yet delivered to the handler will arrive in this
        // final read.
        task.terminationHandler = { finishedTask in
            timers.cancelAll()

            let trailingStdout = stdoutPipe.fileHandleForReading.availableData
            if !trailingStdout.isEmpty { stdoutBuffer.append(trailingStdout) }
            let trailingStderr = stderrPipe.fileHandleForReading.availableData
            if !trailingStderr.isEmpty { stderrBuffer.append(trailingStderr) }
            // Drop any remaining handlers explicitly so neither pipe holds
            // a strong reference to the closure capture graph.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            let stdoutBytes = stdoutBuffer.snapshot()
            let stderrBytes = stderrBuffer.snapshot()
            let stdout = String(data: stdoutBytes, encoding: .utf8) ?? ""
            let stderr = String(data: stderrBytes, encoding: .utf8) ?? ""
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

            if completionFired.set() {
                var payload: [String: Any] = [
                    "exitCode": finishedTask.terminationStatus,
                    "stdout": stdout,
                    "stderr": stderr,
                    "durationMs": durationMs,
                    "image": image,
                    "command": command,
                    "network": network
                ]
                // PRD-65 Spec 9 / PRD-64 Spec 9: when the container daemon
                // isn't running, surface the recovery as a structured
                // setup_required field so callers don't have to scrape
                // stderr to learn what to do.
                if stderr.contains("container system service has not been started")
                    || stderr.contains("XPC connection error: Connection invalid") {
                    payload["setup_required"] = [
                        "reason": "container daemon is not running",
                        "command": "container system start",
                        "docs": "https://developer.apple.com/documentation/virtualization"
                    ]
                }
                completion(WireFormat.success(payload))
            }
        }

        do {
            try task.run()
        } catch {
            timers.cancelAll()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if completionFired.set() {
                completion(WireFormat.error("container_run: failed to spawn `\(containerBinary)`: \(error.localizedDescription)"))
            }
            return
        }
    }
}

/// holder for the SIGTERM and SIGKILL `DispatchWorkItem`s.
/// `DispatchWorkItem` is not `Sendable` in Swift 6, so the holder is
/// marked `@unchecked Sendable` and exposes a `cancelAll()` method that
/// can be called safely from `task.terminationHandler` (a `@Sendable`
/// closure under strict concurrency).
final class TimerHolder: @unchecked Sendable {
    private let lock = NSLock()
    var sigtermTimer: DispatchWorkItem?
    var sigkillTimer: DispatchWorkItem?

    func cancelAll() {
        lock.lock()
        sigtermTimer?.cancel()
        sigkillTimer?.cancel()
        lock.unlock()
    }
}

/// /CY-6: tiny lock-protected `Data` accumulator written by the
/// pipe's `readabilityHandler` (background queue) and read by
/// `terminationHandler` (also background, different queue). NSLock is
/// sufficient — critical sections are bounded by `Data.append`.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}

/// latch that ensures the completion handler is invoked at
/// most once even if `task.run()` throws after the SIGTERM/SIGKILL timers
/// have been scheduled. `set()` returns true on the first call only.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func set() -> Bool {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        return first
    }
}
