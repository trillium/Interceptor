import XCTest
@testable import interceptor_bridge

// PRD-65 Spec 10 / PRD-64 Spec 6 regression. AudioDomain previously
// returned a literal informational string for `audio output devices`
// instead of an enumerated AVCaptureDevice list. The fix uses Apple's
// documented AVCaptureDevice.DiscoverySession (the legacy
// `devices(for:)` is deprecated since macOS 10.15).

final class AudioDeviceEnumerationTests: XCTestCase {
    func testEnumerateAudioDevicesReturnsArray() {
        // Pure helper — no daemon. Returns whatever DiscoverySession
        // surfaces on the host. Empty arrays are valid (CI / no-mic
        // hosts); we assert shape, not population.
        let devices = AudioDomain.enumerateAudioDevices(role: "input")
        // Either zero devices (acceptable on some hosts) or each entry
        // carries the documented shape.
        for d in devices {
            XCTAssertNotNil(d["uniqueID"] as? String, "missing uniqueID on device dict")
            XCTAssertNotNil(d["localizedName"] as? String, "missing localizedName")
            XCTAssertNotNil(d["deviceType"] as? String, "missing deviceType")
            XCTAssertEqual(d["role"] as? String, "input", "role tag must be passed through")
        }
    }

    func testRoleTagIsPassedThrough() {
        let outputs = AudioDomain.enumerateAudioDevices(role: "output")
        for d in outputs {
            XCTAssertEqual(d["role"] as? String, "output")
        }
    }
}
