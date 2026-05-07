import XCTest
@testable import interceptor_bridge

// PRD-65 Spec 10 / PRD-64 Spec 3 regression. StreamDomain.handle had no
// `list` case, so callers asking to enumerate active streams got
// "not yet implemented". The fix projects the existing sessions
// dictionary into a structured array.

private final class StreamResultHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any] = [:]
    var value: [String: Any] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
    func set(_ v: [String: Any]) { lock.lock(); stored = v; lock.unlock() }
}

final class StreamListTests: XCTestCase {
    func testListReturnsArrayOnEmptySessions() {
        let domain = StreamDomain()
        let holder = StreamResultHolder()
        let exp = expectation(description: "stream list")
        domain.handle("stream", action: ["type": "macos_stream", "op": "list"]) { r in
            holder.set(r)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        let result = holder.value
        let err = result["error"] as? String
        XCTAssertNil(err, "list must not error on empty sessions")
        // success-wrapped data is the array; empty when no streams active.
        let data = result["data"] as? [Any]
        XCTAssertNotNil(data, "list must return a top-level array via data field")
        XCTAssertEqual(data?.count, 0, "no sessions registered → empty array")
    }
}
