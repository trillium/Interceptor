import XCTest
@testable import interceptor_bridge

// MonitorSession value-type tests. Pins the meta-dict shape so the
// CLI's MonitorSessionMeta type (shared/monitor-artifacts.ts) and the bridge
// stay in sync as new fields are added.

final class MonitorSessionTests: XCTestCase {
    func testMetaDictContainsRequiredFields() {
        let session = MonitorSession(
            id: "abc12345",
            instruction: "do the thing",
            startTime: Date(timeIntervalSince1970: 1715000000),
            scope: .frontmost(),
            includes: ["clipboard"],
            excludes: ["mouse-moved"],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: false, microphone: nil)
        )
        let meta = session.toMetaDict()
        XCTAssertEqual(meta["sessionId"] as? String, "abc12345")
        XCTAssertEqual(meta["surface"] as? String, "macos")
        XCTAssertEqual(meta["status"] as? String, "active")
        XCTAssertEqual(meta["paused"] as? Bool, false)
        XCTAssertEqual(meta["instruction"] as? String, "do the thing")
        XCTAssertEqual(meta["artifactVersion"] as? Int, 1)
        let counts = meta["counts"] as? [String: Int]
        XCTAssertEqual(counts?["evt"], 0)
        XCTAssertEqual(counts?["ax"], 0)
        let scope = meta["scope"] as? [String: Any]
        XCTAssertEqual(scope?["mode"] as? String, "frontmost")
        let tcc = meta["tcc"] as? [String: Any]
        XCTAssertEqual(tcc?["accessibility"] as? Bool, true)
        XCTAssertEqual(tcc?["screenRecording"] as? Bool, false)
    }

    func testTallyIncrementsExpectedCounters() {
        let s = MonitorSession(
            id: "x",
            instruction: nil,
            startTime: Date(),
            scope: .frontmost(),
            includes: [],
            excludes: [],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: nil, microphone: nil)
        )
        s.tally(event: "click")
        s.tally(event: "input")
        s.tally(event: "layout_change")
        s.tally(event: "frontmost")
        s.tally(event: "network_path")
        XCTAssertEqual(s.evt, 5)
        XCTAssertEqual(s.ax, 2)         // click + input
        XCTAssertEqual(s.mut, 1)        // layout_change
        XCTAssertEqual(s.nav, 1)        // frontmost
        XCTAssertEqual(s.net, 1)        // network_path
    }

    func testSequenceCounterIsMonotonic() {
        let s = MonitorSession(
            id: "x",
            instruction: nil,
            startTime: Date(),
            scope: .frontmost(),
            includes: [],
            excludes: [],
            tcc: MonitorTccSnapshot(accessibility: true, screenRecording: nil, microphone: nil)
        )
        var prev = -1
        for _ in 0..<5 {
            let cur = s.nextSeq()
            XCTAssertGreaterThan(cur, prev)
            prev = cur
        }
    }

    func testScopeAppsRoundTrip() {
        let scope = MonitorScope.apps(["Slack", "com.apple.mail"])
        let dict = scope.toDict()
        XCTAssertEqual(dict["mode"] as? String, "apps")
        XCTAssertEqual(dict["apps"] as? [String], ["Slack", "com.apple.mail"])
    }
}
