// native log query primitive — log_query.
// Replaces tailing files via bash. Uses OSLogStore + OSLogEnumerator on
// macOS 12+. Returns structured entries (timestamp, subsystem, category,
// message, level) instead of opaque text.

import Foundation
#if canImport(OSLog)
import OSLog
#endif

final class LogDomain: DomainHandler, @unchecked Sendable {
    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        switch command {
        case "query":
            handleQuery(action, completion: completion)
        default:
            completion(WireFormat.error("log: unknown command \(command)"))
        }
    }

    private func handleQuery(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let limit = (action["limit"] as? Int) ?? 100
        let predicateStr = action["predicate"] as? String
        let sinceStr = action["since"] as? String
        let includeInfo = (action["includeInfo"] as? Bool) ?? false
        let includeDebug = (action["includeDebug"] as? Bool) ?? false

        #if canImport(OSLog)
        if #available(macOS 12.0, *) {
            do {
                // PRD-65 Spec 8 / PRD-64 Spec 8: OSLogStore.Scope
                // .currentProcessIdentifier returns ONLY entries from this
                // bridge process — by definition cannot return entries
                // from com.apple.WindowServer or any other subsystem the
                // caller queries. Apple documents OSLogStore.local() as
                // the system-wide alternative
                // (OSLog/OSLogStore.md:25-26). Switch to .local() so the
                // documented predicate-based queries against arbitrary
                // subsystems actually return entries.
                let store = try OSLogStore.local()
                let position: OSLogPosition
                if let s = sinceStr {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
                        position = store.position(date: date)
                    } else {
                        position = store.position(date: Date(timeIntervalSinceNow: -300))
                    }
                } else {
                    position = store.position(date: Date(timeIntervalSinceNow: -300))
                }
                var pred: NSPredicate? = nil
                if let p = predicateStr, !p.isEmpty {
                    pred = NSPredicate(format: p)
                }
                let entries = try store.getEntries(at: position, matching: pred)
                var out: [[String: Any]] = []
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                for entry in entries {
                    if let logEntry = entry as? OSLogEntryLog {
                        let level = String(describing: logEntry.level)
                        if logEntry.level == .info && !includeInfo { continue }
                        if logEntry.level == .debug && !includeDebug { continue }
                        out.append([
                            "timestamp": f.string(from: logEntry.date),
                            "subsystem": logEntry.subsystem,
                            "category": logEntry.category,
                            "message": logEntry.composedMessage,
                            "level": level,
                            "process": logEntry.process
                        ])
                    } else {
                        out.append([
                            "timestamp": f.string(from: entry.date),
                            "message": entry.composedMessage
                        ])
                    }
                    if out.count >= limit { break }
                }
                completion(WireFormat.success(["entries": out, "count": out.count, "scope": "local"]))
                return
            } catch {
                completion(WireFormat.error("log_query failed: \(error.localizedDescription)"))
                return
            }
        }
        #endif
        completion(WireFormat.error("log_query: requires macOS 12+ (OSLogStore unavailable)"))
    }
}
