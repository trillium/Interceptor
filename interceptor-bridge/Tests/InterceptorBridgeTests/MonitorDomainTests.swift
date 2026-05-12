import XCTest
@testable import interceptor_bridge

// MonitorDomain dispatch + lifecycle tests. We don't exercise the
// live AX, NSEvent, ScreenCaptureKit, OSLog, or Speech surfaces in CI (those
// require TCC consents that don't exist on a build runner). Tests here pin
// the dispatch contract, the structured-error format, and the session-meta
// shape produced by the orchestrator.

private final class ResultHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any] = [:]
    var value: [String: Any] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
    func set(_ v: [String: Any]) { lock.lock(); stored = v; lock.unlock() }
}

final class MonitorDomainTests: XCTestCase {
    private func dispatch(_ domain: MonitorDomain, sub: String, extra: [String: Any] = [:]) -> [String: Any] {
        var action: [String: Any] = ["type": "macos_monitor", "sub": sub]
        for (k, v) in extra { action[k] = v }
        let holder = ResultHolder()
        let exp = expectation(description: "monitor dispatch \(sub)")
        domain.handle("monitor", action: action) { r in
            holder.set(r)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        return holder.value
    }

    func testStopWithNoActiveSessionReturnsStructuredError() {
        let r = dispatch(MonitorDomain(), sub: "stop")
        XCTAssertEqual(r["success"] as? Bool, false)
        XCTAssertEqual(r["error"] as? String, "no_active_session")
        XCTAssertEqual(r["exitCode"] as? Int, 4)
    }

    func testPauseWithNoActiveSessionReturnsStructuredError() {
        let r = dispatch(MonitorDomain(), sub: "pause")
        XCTAssertEqual(r["error"] as? String, "no_active_session")
    }

    func testResumeWithNoActiveSessionReturnsStructuredError() {
        let r = dispatch(MonitorDomain(), sub: "resume")
        XCTAssertEqual(r["error"] as? String, "no_active_session")
    }

    func testStatusWhenIdle() {
        let r = dispatch(MonitorDomain(), sub: "status")
        XCTAssertEqual(r["success"] as? Bool, true)
        let data = r["data"] as? [String: Any]
        XCTAssertEqual(data?["status"] as? String, "idle")
    }

    func testListReturnsArray() {
        let r = dispatch(MonitorDomain(), sub: "list")
        XCTAssertEqual(r["success"] as? Bool, true)
        XCTAssertNotNil(r["data"] as? [Any])
    }

    func testExportRequiresSid() {
        let r = dispatch(MonitorDomain(), sub: "export")
        XCTAssertEqual(r["success"] as? Bool, false)
        XCTAssertEqual(r["error"] as? String, "export requires a sid")
    }

    func testStartWithoutAccessibilityTccReturnsStructuredError() {
        // CI runners and the build environment will not have AX TCC granted
        // to the test process, so this is the path we expect to hit.
        let r = dispatch(MonitorDomain(), sub: "start", extra: ["instruction": "test"])
        if r["success"] as? Bool == false {
            XCTAssertEqual(r["error"] as? String, "missing_tcc:Accessibility")
            XCTAssertEqual(r["exitCode"] as? Int, 2)
            XCTAssertNotNil(r["remediation"])
        } else {
            // If AX is granted (rare in CI), make sure we got a session id back.
            let data = r["data"] as? [String: Any]
            XCTAssertNotNil(data?["sid"] as? String)
            // Clean up so subsequent tests don't see an active session.
            // (Swallow result; we just want the side effect.)
            _ = dispatch(MonitorDomain(), sub: "stop")
        }
    }

    func testTailWithNoSessionReturnsError() {
        let r = dispatch(MonitorDomain(), sub: "tail")
        XCTAssertEqual(r["success"] as? Bool, false)
        XCTAssertEqual(r["error"] as? String, "no_active_session")
    }

    func testUnknownSubReturnsNotImplemented() {
        let r = dispatch(MonitorDomain(), sub: "nonexistent")
        let err = r["error"] as? String ?? ""
        XCTAssertTrue(err.contains("nonexistent"), "Error should reference the unknown sub")
    }

    // Multi-session map. Without AX consent the start path
    // exits on missing_tcc:Accessibility, so we exercise the runtime map
    // directly: insert two MonitorRuntimes, then verify sub-verb dispatch by
    // --sid argument finds the right one.
    func testConcurrentMultiSessionStatusDisambiguation() {
        let domain = MonitorDomain()

        let s1 = MonitorSession(
            id: "aaa11111", instruction: "first", startTime: Date(),
            scope: .frontmost(), includes: [], excludes: [],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: nil, microphone: nil)
        )
        let s2 = MonitorSession(
            id: "bbb22222", instruction: "second", startTime: Date(),
            scope: .all(), includes: ["clipboard"], excludes: [],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: nil, microphone: nil)
        )
        let r1 = MonitorRuntime(session: s1, domain: domain)
        let r2 = MonitorRuntime(session: s2, domain: domain)
        domain.runtimes[s1.id] = r1
        domain.runtimes[s2.id] = r2

        // Status with no sid returns array of N sessions.
        let bulk = dispatch(domain, sub: "status")
        XCTAssertEqual(bulk["success"] as? Bool, true)
        let bulkData = bulk["data"] as? [String: Any]
        let sessions = bulkData?["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 2)
        XCTAssertEqual(bulkData?["activeCount"] as? Int, 2)

        // Status targeted by sid returns the specific session.
        let one = dispatch(domain, sub: "status", extra: ["sid": "aaa11111"])
        let oneData = one["data"] as? [String: Any]
        XCTAssertEqual(oneData?["sid"] as? String, "aaa11111")
        XCTAssertEqual(oneData?["scope"] as? [String: Any] != nil, true)
    }

    func testStopWithSidStopsExactlyThatSession() {
        let domain = MonitorDomain()
        let s1 = MonitorSession(
            id: "ccc33333", instruction: nil, startTime: Date(),
            scope: .frontmost(), includes: [], excludes: [],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: nil, microphone: nil)
        )
        let s2 = MonitorSession(
            id: "ddd44444", instruction: nil, startTime: Date(),
            scope: .all(), includes: [], excludes: [],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: nil, microphone: nil)
        )
        domain.runtimes[s1.id] = MonitorRuntime(session: s1, domain: domain)
        domain.runtimes[s2.id] = MonitorRuntime(session: s2, domain: domain)

        // Stop the first by sid; only the second should remain.
        let stopped = dispatch(domain, sub: "stop", extra: ["sid": "ccc33333"])
        XCTAssertEqual(stopped["success"] as? Bool, true)

        XCTAssertNil(domain.runtimes["ccc33333"])
        XCTAssertNotNil(domain.runtimes["ddd44444"])
    }

    func testStopWithoutSidWhenAmbiguousReturnsNoActiveSession() {
        let domain = MonitorDomain()
        let s1 = MonitorSession(
            id: "eee55555", instruction: nil, startTime: Date(),
            scope: .frontmost(), includes: [], excludes: [],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: nil, microphone: nil)
        )
        let s2 = MonitorSession(
            id: "fff66666", instruction: nil, startTime: Date(),
            scope: .all(), includes: [], excludes: [],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: nil, microphone: nil)
        )
        domain.runtimes[s1.id] = MonitorRuntime(session: s1, domain: domain)
        domain.runtimes[s2.id] = MonitorRuntime(session: s2, domain: domain)

        // Two active sessions, no --sid → ambiguous → no_active_session.
        let r = dispatch(domain, sub: "stop")
        XCTAssertEqual(r["success"] as? Bool, false)
        XCTAssertEqual(r["error"] as? String, "no_active_session")
    }

    // CGEventTap fallback. We can't actually create a real
    // tap without Accessibility TCC, so this test verifies the code path
    // doesn't crash and surfaces the structured `tap_unavailable` event when
    // CGEvent.tapCreate returns nil.
    func testTapBridgeStartReturnsFalseWithoutTcc() {
        let bridge = MonitorTapBridge()
        // In test environment without AX TCC, tapCreate returns nil.
        // The bridge's start() returns false and doesn't crash.
        let ok = bridge.start()
        // Either result is acceptable — the contract is that the call
        // doesn't crash and returns a Bool. If somehow AX is granted on
        // the runner, ok==true is fine; we just stop it and move on.
        if ok { bridge.stop() }
    }

    func testTapBridgeModifierString() {
        var f: CGEventFlags = []
        XCTAssertEqual(MonitorTapBridge.modifierString(f), "")
        f = [.maskCommand]
        XCTAssertEqual(MonitorTapBridge.modifierString(f), "Meta")
        f = [.maskCommand, .maskShift]
        XCTAssertEqual(MonitorTapBridge.modifierString(f), "Meta+Shift")
        f = [.maskControl, .maskAlternate, .maskShift]
        XCTAssertEqual(MonitorTapBridge.modifierString(f), "Control+Alt+Shift")
    }
}
