// app_intent — full implementation via Apple Events.
//
// Apple Events is the universal app-control channel that has been on
// macOS since 1991. AppIntents is Apple's modern wrapper over it. By
// dispatching via NSAppleScript we get:
//   - true cross-app verb dispatch
//   - macOS TCC Automation consent prompt on first use per (interceptor-bridge,
//     target_app) pair (correct consent UX, no entitlement audit)
//   - structured parameter passing via AppleScript record syntax
//   - structured result back via NSAppleEventDescriptor
//
// The wire shape (action["..."]) accepts any of three input forms,
// in order of flexibility:
//
//   1. Raw script:    { script: "<applescript source>" }
//   2. Structured:    { bundleId, intent, parameters?, target?, args? }
//                     → "tell application id \"<bundleId>\" to <intent> [<args>] [<target>] [with properties <parameters>]"
//   3. JXA (advanced) { javascript: "<JXA source>" }
//
// All three return the same shape: { result: <descriptor>, success: bool, raw: string }.

import Foundation
import AppKit
import Carbon // for AEDeterminePermissionToAutomateTarget

final class IntentDomain: DomainHandler, @unchecked Sendable {
    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        switch command {
        case "dispatch":
            handleDispatch(action, completion: completion)
        case "warmup":
            handleWarmup(action, completion: completion)
        default:
            completion(WireFormat.error("intent: unknown command \(command)"))
        }
    }

    /// pre-prompt TCC for a batch of bundle ids in one call. macOS
    /// will display each consent dialog in turn; user clicks Allow once
    /// per app and is never bothered again for that pair. Returns a map
    /// of bundleId → granted/denied so the engine can record state.
    private func handleWarmup(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let bundleIds = action["bundleIds"] as? [String], !bundleIds.isEmpty else {
            completion(WireFormat.error("intent.warmup: requires bundleIds: [String]"))
            return
        }
        DispatchQueue.main.async {
            var results: [[String: Any]] = []
            for bid in bundleIds {
                let status = self.requestAutomationPermission(for: bid)
                let outcome: String
                switch status {
                case noErr:
                    outcome = "granted"
                case -1743:
                    outcome = "denied"
                case -600:
                    outcome = "app_not_running"
                default:
                    outcome = "status_\(status)"
                }
                results.append([
                    "bundleId": bid,
                    "status": status,
                    "outcome": outcome
                ])
            }
            let granted = results.filter { ($0["outcome"] as? String) == "granted" }.count
            let denied = results.filter { ($0["outcome"] as? String) == "denied" }.count
            completion(WireFormat.success([
                "results": results,
                "summary": [
                    "total": bundleIds.count,
                    "granted": granted,
                    "denied": denied
                ]
            ]))
        }
    }

    // MARK: dispatch
    private func handleDispatch(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        // Form 1: raw AppleScript source.
        if let rawScript = action["script"] as? String, !rawScript.isEmpty {
            executeAppleScript(rawScript, targetBundleId: nil, completion: completion)
            return
        }

        // Form 3: JavaScript for Automation (JXA) source.
        if let jxa = action["javascript"] as? String, !jxa.isEmpty {
            executeOSAScript(jxa, language: "JavaScript", completion: completion)
            return
        }

        // Form 2: structured intent dispatch.
        guard let bundleId = action["bundleId"] as? String, !bundleId.isEmpty,
              let intent = action["intent"] as? String, !intent.isEmpty else {
            completion(WireFormat.error("app_intent: requires bundleId + intent (or raw script/javascript)"))
            return
        }
        let parameters = action["parameters"] as? [String: Any] ?? [:]
        let target = action["target"] as? String
        let argsArr = action["args"] as? [Any]

        let source = buildAppleScriptSource(
            bundleId: bundleId,
            intent: intent,
            parameters: parameters,
            target: target,
            args: argsArr
        )
        executeAppleScript(source, targetBundleId: bundleId, completion: completion)
    }

    /// Forces the macOS TCC consent dialog to appear synchronously by calling
    /// AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true). Returns
    /// noErr (0) if granted, errAEEventNotPermitted (-1743) if denied, or
    /// other OSStatus values for transient errors.
    private func requestAutomationPermission(for bundleId: String) -> OSStatus {
        var targetDesc = AEAddressDesc()
        let bidNS = bundleId as NSString
        guard let cString = bidNS.cString(using: String.Encoding.utf8.rawValue) else {
            return -50 // paramErr
        }
        let length = bidNS.lengthOfBytes(using: String.Encoding.utf8.rawValue)
        let createStatus = AECreateDesc(typeApplicationBundleID, cString, length, &targetDesc)
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&targetDesc) }
        // typeWildCard for both class and id means "any Apple Event" — TCC
        // grant is per-(source, target) pair, not per-event-type.
        return OSStatus(AEDeterminePermissionToAutomateTarget(&targetDesc, typeWildCard, typeWildCard, true))
    }

    // MARK: AppleScript builder
    private func buildAppleScriptSource(
        bundleId: String,
        intent: String,
        parameters: [String: Any],
        target: String?,
        args: [Any]?
    ) -> String {
        var inner = intent
        if let args = args, !args.isEmpty {
            let argList = args.map { applescriptValue($0) }.joined(separator: ", ")
            inner += " " + argList
        }
        if let target = target, !target.isEmpty {
            // Caller already wrote AppleScript-shaped target like
            // 'first document' or 'window 1'. Pass through verbatim.
            inner += " " + target
        }
        if !parameters.isEmpty {
            inner += " with properties " + applescriptRecord(parameters)
        }
        // Wrap in tell-block addressed to the target app by bundle id.
        return """
        tell application id \"\(applescriptEscape(bundleId))\"
            \(inner)
        end tell
        """
    }

    private func applescriptValue(_ v: Any) -> String {
        if let s = v as? String { return "\"\(applescriptEscape(s))\"" }
        if let n = v as? NSNumber {
            // Bool vs Int/Double
            let typeStr = String(cString: n.objCType)
            if typeStr == "c" { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let arr = v as? [Any] {
            let inner = arr.map { applescriptValue($0) }.joined(separator: ", ")
            return "{\(inner)}"
        }
        if let dict = v as? [String: Any] {
            return applescriptRecord(dict)
        }
        return "missing value"
    }

    private func applescriptRecord(_ dict: [String: Any]) -> String {
        let parts = dict.map { (k, v) -> String in
            "\(applescriptKey(k)):\(applescriptValue(v))"
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    /// AppleScript record keys are bare identifiers; sanitize.
    private func applescriptKey(_ raw: String) -> String {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_"))
        let scrub = raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        if let first = scrub.first, first.isLetter { return scrub }
        return "_" + scrub
    }

    private func applescriptEscape(_ s: String) -> String {
        // Inside a "..." literal: escape backslashes and double quotes.
        var out = ""
        for ch in s.unicodeScalars {
            if ch == "\\" { out += "\\\\" }
            else if ch == "\"" { out += "\\\"" }
            else if ch == "\n" { out += "\\n" }
            else if ch == "\r" { out += "\\r" }
            else if ch == "\t" { out += "\\t" }
            else { out += String(ch) }
        }
        return out
    }

    // MARK: NSAppleScript executor
    private func executeAppleScript(_ source: String, targetBundleId: String?, completion: @escaping @Sendable ([String: Any]) -> Void) {
        // TCC consent dialogs need to render against a foreground run loop.
        // interceptor-bridge is an NSApplication.accessory agent, so the main run
        // loop IS active — but we have to make the request from the main
        // thread or TCC silently denies. So we dispatch to main, do the
        // permission check + the AppleScript execute synchronously there,
        // and reply via completion.
        DispatchQueue.main.async {
            if let bid = targetBundleId, !bid.isEmpty {
                let permStatus = self.requestAutomationPermission(for: bid)
                if permStatus != noErr {
                    let codeStr = String(permStatus)
                    let hint: String
                    if permStatus == -1743 {
                        hint = "User denied Apple Events permission for \(bid). " +
                               "Re-prompt with: tccutil reset AppleEvents com.interceptor.bridge"
                    } else {
                        hint = "AEDeterminePermissionToAutomateTarget returned \(codeStr) for \(bid)."
                    }
                    completion(WireFormat.error("app_intent: \(hint)\n--- script ---\n\(source)"))
                    return
                }
            }

            guard let script = NSAppleScript(source: source) else {
                completion(WireFormat.error("app_intent: failed to construct NSAppleScript"))
                return
            }
            var errInfo: NSDictionary?
            let result = script.executeAndReturnError(&errInfo)
            if let err = errInfo as? [String: Any] {
                let msg = (err[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
                let code = err[NSAppleScript.errorNumber] as? Int ?? -1
                let appName = (err[NSAppleScript.errorAppName] as? String) ?? ""

                // Common code -1743 = errAEEventNotPermitted (TCC denial).
                // Append clear instructions for the user to grant access.
                var hint = ""
                if code == -1743 {
                    hint = "\n\nTCC denial. To authorize interceptor-bridge to send Apple Events to this app:\n" +
                           "  System Settings → Privacy & Security → Automation → interceptor-bridge → toggle on for the target app.\n" +
                           "If interceptor-bridge does not appear under Automation, the first event dispatch should have prompted you.\n" +
                           "Reset the entry with: tccutil reset AppleEvents com.interceptor.bridge"
                }
                completion(WireFormat.error(
                    "app_intent failed (\(code)): \(msg)" +
                    (appName.isEmpty ? "" : " — app: \(appName)") +
                    hint +
                    "\n--- script ---\n\(source)"
                ))
                return
            }
            let serialized = self.descriptorToValue(result)
            completion(WireFormat.success([
                "result": serialized as Any,
                "raw": result.stringValue ?? "",
                "script": source
            ]))
        }
    }

    // MARK: OSAScript executor (JavaScript / JXA)
    // For v1, JXA is intentionally unsupported. AppleScript via NSAppleScript
    // covers 99 % of intent dispatch needs and is the universal Apple Event
    // bridge on macOS. JXA can be added later via OSAKit linkage if needed;
    // until then we fail loud rather than ship reflective Obj-C runtime code.
    private func executeOSAScript(_ source: String, language: String, completion: @escaping @Sendable ([String: Any]) -> Void) {
        completion(WireFormat.error(
            "app_intent: JavaScript-for-Automation is not supported in v1. " +
            "Use the structured `bundleId + intent + parameters` form, or pass raw AppleScript via `script:`. " +
            "JXA support requires linking OSAKit — file a follow-up if needed."
        ))
    }

    // MARK: result descriptor → Foundation value
    private func descriptorToValue(_ desc: NSAppleEventDescriptor?) -> Any? {
        guard let d = desc else { return nil }
        // Common scalar types first.
        if d.descriptorType == typeUnicodeText || d.descriptorType == typeUTF8Text || d.descriptorType == typeText {
            return d.stringValue
        }
        if d.descriptorType == typeBoolean {
            return d.booleanValue
        }
        if d.descriptorType == typeSInt32 || d.descriptorType == typeSInt16 {
            return d.int32Value
        }
        if d.descriptorType == typeIEEE64BitFloatingPoint {
            return d.doubleValue
        }
        // List → array.
        if d.descriptorType == typeAEList {
            var arr: [Any?] = []
            for i in 1...d.numberOfItems {
                let item = d.atIndex(i)
                arr.append(descriptorToValue(item))
            }
            return arr
        }
        // Record → dict.
        if d.descriptorType == typeAERecord {
            var dict: [String: Any?] = [:]
            for i in 1...d.numberOfItems {
                let key = d.keywordForDescriptor(at: i)
                let val = d.atIndex(i)
                let keyStr = String(format: "%c%c%c%c",
                    (key >> 24) & 0xff, (key >> 16) & 0xff, (key >> 8) & 0xff, key & 0xff)
                dict[keyStr] = descriptorToValue(val)
            }
            return dict
        }
        return d.stringValue
    }
}

