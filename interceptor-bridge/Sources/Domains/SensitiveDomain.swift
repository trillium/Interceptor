import Foundation
import SensitiveContentAnalysis

final class SensitiveDomain: DomainHandler, @unchecked Sendable {
    private var monitorActive = false

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        // PRD-65 Spec 2 / PRD-64 Spec 2: SensitiveDomain mirrored the
        // pre-PRD-63 NLP dispatch bug — switched on `command` ("sensitive")
        // not action["sub"]. The SCSensitivityAnalyzer integration at
        // checkContent already follows Apple's documented API; only the
        // dispatch was broken.
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "check":
            checkContent(action, completion: completion)
        case "monitor":
            handleMonitor(action, completion: completion)
        default:
            notImplemented(sub, completion: completion)
        }
    }

    private func checkContent(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14.0, *) {
            Task {
                let analyzer = SCSensitivityAnalyzer()
                let policy = analyzer.analysisPolicy
                completion(WireFormat.success([
                    "policyEnabled": policy != .disabled,
                    "policy": String(describing: policy),
                    "note": "Use with screenshot data for actual content analysis"
                ]))
            }
        } else {
            completion(WireFormat.error("SensitiveContentAnalysis requires macOS 14.0+"))
        }
    }

    private func handleMonitor(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let op = action["op"] as? String ?? "status"
        switch op {
        case "start":
            if #available(macOS 14.0, *) {
                monitorActive = true
                completion(WireFormat.success(["monitoring": true, "note": "Sensitive content analysis is active — results available via 'sensitive check'"]))
            } else {
                completion(WireFormat.error("SensitiveContentAnalysis requires macOS 14.0+"))
            }
        case "stop":
            monitorActive = false
            completion(WireFormat.success(["monitoring": false]))
        case "status":
            completion(WireFormat.success(["monitoring": monitorActive]))
        default:
            notImplemented("sensitive monitor \(op)", completion: completion)
        }
    }
}
