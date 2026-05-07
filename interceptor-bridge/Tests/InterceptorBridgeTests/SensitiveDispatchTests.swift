import XCTest
@testable import interceptor_bridge

// PRD-65 Spec 10 / PRD-64 Spec 2 regression. SensitiveDomain.handle
// previously switched on `command` ("sensitive") not action["sub"], so
// `sensitive check` and `sensitive monitor *` fell through to
// notImplemented despite the SCSensitivityAnalyzer implementation
// already being correct.

private final class SensitiveResultHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any] = [:]
    var value: [String: Any] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
    func set(_ v: [String: Any]) { lock.lock(); stored = v; lock.unlock() }
}

final class SensitiveDispatchTests: XCTestCase {
    private func dispatch(sub: String, extra: [String: Any] = [:]) -> [String: Any] {
        let domain = SensitiveDomain()
        var action: [String: Any] = ["type": "macos_sensitive", "sub": sub]
        for (k, v) in extra { action[k] = v }
        let holder = SensitiveResultHolder()
        let exp = expectation(description: "sensitive dispatch \(sub)")
        domain.handle("sensitive", action: action) { r in
            holder.set(r)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        return holder.value
    }

    private func isNotImplemented(_ result: [String: Any]) -> Bool {
        let err = (result["error"] as? String) ?? ""
        return err.contains("not yet implemented") || err.contains("not implemented")
    }

    func testCheckIsRoutedFromSub() {
        let r = dispatch(sub: "check")
        XCTAssertFalse(isNotImplemented(r), "check sub must reach checkContent")
        let data = r["data"] as? [String: Any]
        XCTAssertNotNil(data?["policyEnabled"], "checkContent must surface analyzer policy state")
    }

    func testMonitorStatusIsRoutedFromSub() {
        let r = dispatch(sub: "monitor", extra: ["op": "status"])
        XCTAssertFalse(isNotImplemented(r), "monitor sub must reach handleMonitor")
    }
}
