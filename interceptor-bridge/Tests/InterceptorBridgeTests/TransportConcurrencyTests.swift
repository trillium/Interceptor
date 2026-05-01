// — verification suite for the per-fd async-dispatch +
// per-fd write-serialization model in Transport.swift.
//
// These tests cover acceptance criteria 1, 2, and 5 from //   1. Two concurrent requests on the same fd both reach `router.route`
//      before either completes.
//   2. With one synthetic ~5s slow request in flight, an interleaved fast
//      request still completes in <500 ms.
//   5. 100 concurrent requests on one fd produce 100 cleanly-decoded
//      responses (no interleaved frame bytes on the wire).
//
// Strategy: each test creates a `socketpair(AF_UNIX, SOCK_STREAM)`, hands
// one end to `Transport.handleClient` on a background thread, registers a
// `BlockingTestDomain` on a `Router`, and writes/reads framed JSON
// directly on the other end. This exercises the full read loop, worker
// dispatch, write-queue serialization, and shutdown-drain path.

import XCTest
import Darwin
@testable import interceptor_bridge

/// Test domain that lets each test stage requests with caller-controlled
/// latency. The router dispatches `macos_test_<command>`; the command
/// becomes the lookup key into `replies`.
final class BlockingTestDomain: DomainHandler, @unchecked Sendable {
    struct Reply {
        let delay: TimeInterval
        let payload: [String: Any]
    }

    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private(set) var receivedAt: [String: Date] = [:]

    func arm(_ command: String, delay: TimeInterval, payload: [String: Any] = [:]) {
        lock.lock()
        replies[command] = Reply(delay: delay, payload: payload)
        lock.unlock()
    }

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock()
        let reply = replies[command]
        receivedAt[command] = Date()
        lock.unlock()

        let delay = reply?.delay ?? 0
        let payloadBox = UncheckedSendableBox(reply?.payload ?? [String: Any]())
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            var merged = payloadBox.value
            merged["command"] = command
            completion(WireFormat.success(merged))
        }
    }
}

/// Helpers around the framed wire protocol (4-byte LE length + JSON).
enum TestFrame {
    static func encode(_ obj: [String: Any]) -> Data {
        let body = try! JSONSerialization.data(withJSONObject: obj)
        var len = UInt32(body.count)
        var out = Data(bytes: &len, count: 4)
        out.append(body)
        return out
    }

    static func readFrame(fd: Int32, timeoutSeconds: Int = 10) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var buf = [UInt8](repeating: 0, count: 65536)

        func readOnce(into target: inout Data, want: Int) -> Bool {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var tv = timeval(tv_sec: Int(remaining), tv_usec: 0)
            var rfds = fd_set()
            withUnsafeMutablePointer(to: &rfds) { ptr in
                let raw = UnsafeMutableRawPointer(ptr)
                memset(raw, 0, MemoryLayout<fd_set>.size)
            }
            let intOffset = Int(fd) / 32
            let bitOffset = Int32(fd) % 32
            withUnsafeMutablePointer(to: &rfds.fds_bits) { tuplePtr in
                tuplePtr.withMemoryRebound(to: Int32.self, capacity: 32) { wordPtr in
                    wordPtr[intOffset] |= (Int32(1) << bitOffset)
                }
            }
            let rc = Darwin.select(fd + 1, &rfds, nil, nil, &tv)
            if rc <= 0 { return false }
            let n = buf.withUnsafeMutableBufferPointer { bufPtr in
                Darwin.read(fd, bufPtr.baseAddress!, want)
            }
            if n <= 0 { return false }
            target.append(buf, count: n)
            return true
        }

        var header = Data()
        while header.count < 4 {
            if !readOnce(into: &header, want: 4 - header.count) { return nil }
        }
        let len: UInt32 = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        var body = Data()
        while body.count < Int(len) {
            let need = Int(len) - body.count
            if !readOnce(into: &body, want: min(need, 65536)) { return nil }
        }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

final class TransportConcurrencyTests: XCTestCase {
    private var pair: (server: Int32, client: Int32) = (-1, -1)
    private var serverThread: Thread?
    private var router: Router!
    private var domain: BlockingTestDomain!

    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)

        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { ptr in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, ptr.baseAddress!)
        }
        XCTAssertEqual(rc, 0, "socketpair failed: \(String(cString: strerror(errno)))")
        pair = (server: fds[0], client: fds[1])

        domain = BlockingTestDomain()
        router = Router()
        router.register("test", handler: domain)

        let serverFD = pair.server
        let r = router!
        let thread = Thread {
            Transport.handleClient(fd: serverFD, router: r)
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        serverThread = thread
    }

    override func tearDown() {
        if pair.client >= 0 { Darwin.close(pair.client) }
        let deadline = Date().addingTimeInterval(5)
        while let t = serverThread, !t.isFinished, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        pair = (-1, -1)
        serverThread = nil
        router = nil
        domain = nil
        super.tearDown()
    }

    func testTwoConcurrentRequestsBothReachRouterBeforeEitherCompletes() throws {
        domain.arm("a", delay: 0.6)
        domain.arm("b", delay: 0.6)

        let frameA = TestFrame.encode(["id": "req-a", "action": ["type": "macos_test_a"]])
        let frameB = TestFrame.encode(["id": "req-b", "action": ["type": "macos_test_b"]])

        let writeStart = Date()
        _ = frameA.withUnsafeBytes { Darwin.write(pair.client, $0.baseAddress!, frameA.count) }
        _ = frameB.withUnsafeBytes { Darwin.write(pair.client, $0.baseAddress!, frameB.count) }

        let r1 = TestFrame.readFrame(fd: pair.client, timeoutSeconds: 5)
        let r2 = TestFrame.readFrame(fd: pair.client, timeoutSeconds: 5)
        let totalElapsed = Date().timeIntervalSince(writeStart)

        XCTAssertNotNil(r1, "first response missing")
        XCTAssertNotNil(r2, "second response missing")
        XCTAssertLessThan(totalElapsed, 1.0, "responses arrived sequentially (≥1.0s elapsed) — handleClient is still serializing per-fd")

        let aAt = domain.receivedAt["a"]
        let bAt = domain.receivedAt["b"]
        XCTAssertNotNil(aAt)
        XCTAssertNotNil(bAt)
        if let aAt = aAt, let bAt = bAt {
            XCTAssertLessThan(abs(aAt.timeIntervalSince(bAt)), 0.2,
                "router.route did not get both requests near-simultaneously — read loop is blocked")
        }
    }

    func testFastRequestNotStarvedBySlowRequest() throws {
        domain.arm("slow", delay: 5.0)
        domain.arm("fast", delay: 0.05)

        let slow = TestFrame.encode(["id": "req-slow", "action": ["type": "macos_test_slow"]])
        let fast = TestFrame.encode(["id": "req-fast", "action": ["type": "macos_test_fast"]])

        let start = Date()
        _ = slow.withUnsafeBytes { Darwin.write(pair.client, $0.baseAddress!, slow.count) }
        usleep(20_000)
        _ = fast.withUnsafeBytes { Darwin.write(pair.client, $0.baseAddress!, fast.count) }

        guard let firstResp = TestFrame.readFrame(fd: pair.client, timeoutSeconds: 2) else {
            XCTFail("fast response did not arrive within 2s — slow request is starving the fd")
            return
        }
        let firstResponseElapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(firstResp["id"] as? String, "req-fast",
            "expected fast response first, got \(firstResp["id"] ?? "nil")")
        XCTAssertLessThan(firstResponseElapsed, 0.5,
            "fast request took \(firstResponseElapsed)s — should be <500ms")
    }

    func testManyConcurrentRequestsAllDecodeCleanly() throws {
        let n = 100
        for i in 0..<n {
            domain.arm("req\(i)", delay: 0.0)
        }

        for i in 0..<n {
            let frame = TestFrame.encode([
                "id": "id-\(i)",
                "action": ["type": "macos_test_req\(i)"],
            ])
            _ = frame.withUnsafeBytes { Darwin.write(pair.client, $0.baseAddress!, frame.count) }
        }

        var seenIds = Set<String>()
        for _ in 0..<n {
            guard let resp = TestFrame.readFrame(fd: pair.client, timeoutSeconds: 5) else {
                XCTFail("ran out of responses; collected \(seenIds.count)/\(n) before timeout")
                return
            }
            guard let id = resp["id"] as? String else {
                XCTFail("response missing id: \(resp)")
                return
            }
            XCTAssertTrue(seenIds.insert(id).inserted, "duplicate response id \(id)")
        }
        XCTAssertEqual(seenIds.count, n)
    }
}

/// Unit tests for the small Sendable helpers introduced in Transport.swift
/// and ContainerDomain.swift.
final class TransportInternalsTests: XCTestCase {
    func testInflightCounterIncrementsAndDecrements() {
        let c = InflightCounter()
        XCTAssertEqual(c.increment(), 1)
        XCTAssertEqual(c.increment(), 2)
        XCTAssertEqual(c.increment(), 3)
        XCTAssertEqual(c.decrement(), 2)
        XCTAssertEqual(c.decrement(), 1)
        XCTAssertEqual(c.decrement(), 0)
        XCTAssertEqual(c.decrement(), 0)
    }

    func testInflightCounterIsThreadSafe() {
        let c = InflightCounter()
        let g = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        for _ in 0..<1000 {
            g.enter()
            q.async {
                _ = c.increment()
                _ = c.decrement()
                g.leave()
            }
        }
        g.wait()
        XCTAssertEqual(c.increment(), 1, "counter drift after 1000 inc/dec pairs")
    }

    func testLockedDataAccumulatesUnderConcurrency() {
        let d = LockedData()
        let g = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        for i in 0..<100 {
            g.enter()
            q.async {
                d.append(Data([UInt8(i % 256)]))
                g.leave()
            }
        }
        g.wait()
        XCTAssertEqual(d.snapshot().count, 100)
    }

    func testAtomicFlagSetIsOneShot() {
        let f = AtomicFlag()
        XCTAssertTrue(f.set())
        XCTAssertFalse(f.set())
        XCTAssertFalse(f.set())
    }

    func testAtomicFlagIsThreadSafe() {
        let f = AtomicFlag()
        let g = DispatchGroup()
        let q = DispatchQueue.global()
        let firstSetters = LockedCounter()
        for _ in 0..<200 {
            g.enter()
            q.async {
                if f.set() { firstSetters.increment() }
                g.leave()
            }
        }
        g.wait()
        XCTAssertEqual(firstSetters.value, 1, "AtomicFlag.set() granted 'first' to multiple racers")
    }
}

/// Tiny test-only counter (separate from the production `InflightCounter`
/// because we want to assert on exact values).
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }; return n
    }
    func increment() {
        lock.lock(); n += 1; lock.unlock()
    }
}
