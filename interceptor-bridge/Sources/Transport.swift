import Foundation
import Darwin.POSIX

final class Transport: @unchecked Sendable {
    private let router: Router
    private let socketPath: String
    private var serverFD: Int32 = -1
    private var running = true

    init(router: Router) throws {
        self.router = router
        self.socketPath = Platform.bridgeSocketPath

        Platform.cleanupSocket()

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw NSError(domain: "Transport", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to create socket"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            let raw = UnsafeMutableRawPointer(sunPathPtr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFD)
            throw NSError(domain: "Transport", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind failed: \(String(cString: strerror(errno)))"])
        }

        guard Darwin.listen(serverFD, 5) == 0 else {
            Darwin.close(serverFD)
            throw NSError(domain: "Transport", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen failed"])
        }
    }

    func start() {
        Platform.log("transport listening on \(socketPath)")
        let fd = serverFD
        let rtr = router
        let thread = Thread {
            Transport.acceptLoop(serverFD: fd, router: rtr)
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        running = false
        if serverFD >= 0 { Darwin.close(serverFD); serverFD = -1 }
    }

    private static func acceptLoop(serverFD: Int32, router: Router) {
        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(serverFD, sockPtr, &clientLen)
                }
            }
            guard clientFD >= 0 else {
                usleep(10_000)
                continue
            }

            Platform.log("client connected (fd: \(clientFD))")

            let rtr = router
            Thread.detachNewThread {
                Transport.handleClient(fd: clientFD, router: rtr)
            }
        }
    }

    // per-connection state held by the read loop. The read loop
    // never blocks on a router callback completing; instead each request is
    // dispatched to a global worker queue, and the per-fd serial writeQueue
    // serializes the actual `Darwin.write(fd, ...)` so framed bytes from
    // concurrent completions never interleave on the wire. The DispatchGroup
    // tracks every in-flight request so the read loop's exit path can drain
    // pending writes before closing the fd.
    /// Exposed at module-internal access so `@testable import interceptor_bridge`
    /// can drive a `socketpair`-backed handleClient in tests.
    static func handleClient(fd: Int32, router: Router) {
        var buffer = Data()
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)

        let writeQueue = DispatchQueue(label: "interceptor-bridge.write.\(fd)", qos: .userInitiated)
        let workQueue = DispatchQueue.global(qos: .userInitiated)
        let inflightGroup = DispatchGroup()
        let inflightCounter = InflightCounter()

        defer {
            readBuf.deallocate()
            // drain in-flight router callbacks + their writeQueue
            // tasks before closing the fd. group.wait() waits for every
            // group.enter() (request received) to be matched by group.leave()
            // (response written or write failure). writeQueue.sync afterwards
            // is a belt-and-braces flush — group.leave() runs inside the
            // writeQueue closure, so once the group is drained the queue is
            // empty, but a sync barrier is cheap and makes the ordering
            // self-evident to readers.
            inflightGroup.wait()
            writeQueue.sync { }
            Darwin.close(fd)
            Platform.log("client disconnected (fd: \(fd))")
        }

        while true {
            let bytesRead = Darwin.read(fd, readBuf, 65536)
            if bytesRead <= 0 { break }
            buffer.append(readBuf, count: bytesRead)

            while buffer.count >= 4 {
                let payloadLen: UInt32 = buffer.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(as: UInt32.self)
                }
                let frameLen = 4 + Int(payloadLen)
                // Sanity check: max 10MB message
                guard payloadLen > 0, payloadLen < 10_000_000, buffer.count >= frameLen else {
                    if payloadLen == 0 || payloadLen >= 10_000_000 {
                        Platform.log("invalid frame length: \(payloadLen), dropping buffer")
                        buffer.removeAll()
                    }
                    break
                }

                let payload = Data(buffer[4..<frameLen])
                buffer = Data(buffer[frameLen...])

                guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    // Synchronous write of an error frame is fine here — we
                    // have not yet entered the in-flight group for this id.
                    if let frame = Transport.encodeFrame(response: ["error": "invalid JSON"]) {
                        writeQueue.sync { Transport.writeFrame(fd: fd, frame: frame) }
                    }
                    continue
                }

                let requestId = json["id"] as? String ?? UUID().uuidString
                let action = json["action"] as? [String: Any] ?? [:]
                let actionType = action["type"] as? String ?? "unknown"

                let inflight = inflightCounter.increment()
                Platform.log("request \(requestId.prefix(8)) \(actionType) inflight=\(inflight)")

                let startTime = Date()
                inflightGroup.enter()

                // dispatch each request onto the global worker
                // queue. The read loop continues immediately to the next
                // frame — one slow router callback no longer blocks
                // unrelated requests on the same connection. `action` is
                // `[String: Any]` (not Sendable under Swift 6 strict
                // concurrency) so we wrap it in an unchecked-Sendable box
                // for the queue hop. Router.route already documents that
                // its action parameter is consumed exactly once.
                let actionBox = UncheckedSendableBox(action)
                workQueue.async {
                    router.route(action: actionBox.value) { result in
                        let duration = Date().timeIntervalSince(startTime) * 1000
                        let success = result["success"] as? Bool ?? false
                        let remaining = inflightCounter.decrement()
                        Platform.log("response \(requestId.prefix(8)) \(success ? "ok" : "err") \(actionType) \(Int(duration))ms inflight=\(remaining)")

                        // Serialize the response on the worker queue (off
                        // the read thread, off the writeQueue) so we hand
                        // an already-framed `Data` blob across the queue
                        // boundary — `[String: Any]` is not Sendable, but
                        // `Data` is.
                        let response: [String: Any] = [
                            "id": requestId,
                            "result": result
                        ]
                        let frame = Transport.encodeFrame(response: response)

                        // writes are serialized per-fd so frame
                        // bytes from concurrent completions cannot interleave.
                        // group.leave() is called from inside the writeQueue
                        // closure so the read loop's exit-path drain
                        // (inflightGroup.wait()) actually waits until the
                        // bytes are out the door.
                        writeQueue.async {
                            if let frame = frame {
                                Transport.writeFrame(fd: fd, frame: frame)
                            }
                            inflightGroup.leave()
                        }
                    }
                }
            }
        }
    }

    /// serialize a response dict to the framed wire format. Returns
    /// nil and logs if JSON encoding fails. Done OFF the writeQueue so we
    /// hand a Sendable `Data` across queue boundaries (`[String: Any]` is
    /// not Sendable under Swift 6 strict concurrency).
    fileprivate static func encodeFrame(response: [String: Any]) -> Data? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: response) else {
            Platform.log("failed to serialize response")
            return nil
        }
        var length = UInt32(jsonData.count)
        let header = Data(bytes: &length, count: 4)
        return header + jsonData
    }

    /// caller MUST already be running on the per-fd writeQueue so
    /// frame bytes cannot interleave with a concurrent in-flight write.
    fileprivate static func writeFrame(fd: Int32, frame: Data) {
        frame.withUnsafeBytes { ptr in
            _ = Darwin.write(fd, ptr.baseAddress!, frame.count)
        }
    }
}

/// tiny `@unchecked Sendable` wrapper so we can pass non-Sendable
/// values (here, the parsed action `[String: Any]`) across a queue
/// boundary without a torrent of warnings. The transport hands the action
/// to exactly one consumer (`router.route`) which lives on the worker
/// queue, so concurrent access is not a real risk.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// tiny lock-protected counter used to stamp `inflight=N` onto
/// `request`/`response` log lines, giving operators a queue-depth signal
/// now that the read loop no longer serializes per-fd. The counter is
/// per-connection (constructed inside `handleClient`).
final class InflightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0

    /// Increment and return the new value (for the `request` log line).
    func increment() -> Int {
        lock.lock()
        count += 1
        let now = count
        lock.unlock()
        return now
    }

    /// Decrement and return the new value (for the `response` log line).
    func decrement() -> Int {
        lock.lock()
        count = max(0, count - 1)
        let now = count
        lock.unlock()
        return now
    }
}
