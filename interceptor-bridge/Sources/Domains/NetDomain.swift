// native networking primitive — url_fetch.
// Replaces curl shell-out and ad-hoc web fetch tools. Uses URLSession with
// shared cookies, redirect handling, content-type passthrough, and a default
// 30 s timeout (configurable per request).
//
// large bodies are spilled to a sidecar file under
// ~/.local/share/interceptor/url_fetch_cache/ and returned as
// `body: { kind: "bodyRef", ... }` so the next agent turn does not get
// the full payload back inline. The engine post-processor classifies the
// bodyRef shape through a context-artifact pipeline.

import Foundation
import CryptoKit

final class NetDomain: DomainHandler, @unchecked Sendable {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config)
    }()

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        switch command {
        case "fetch":
            handleFetch(action, completion: completion)
        default:
            completion(WireFormat.error("url: unknown command \(command)"))
        }
    }

    private func handleFetch(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let urlStr = action["url"] as? String, let url = URL(string: urlStr) else {
            completion(WireFormat.error("url_fetch: invalid url"))
            return
        }
        let method = (action["method"] as? String) ?? "GET"
        let headers = (action["headers"] as? [String: String]) ?? [:]
        let body = action["body"] as? String
        let timeoutMs = (action["timeoutMs"] as? Int) ?? 30000

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = body, !b.isEmpty {
            // If the body looks base64-encoded and is large, ship it as bytes.
            if let bytes = Data(base64Encoded: b), bytes.count > 0 {
                req.httpBody = bytes
            } else {
                req.httpBody = b.data(using: .utf8)
            }
        }

        let task = session.dataTask(with: req) { [weak self] data, response, err in
            if let e = err {
                completion(WireFormat.error("url_fetch failed: \(e.localizedDescription)"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(WireFormat.error("url_fetch: non-HTTP response"))
                return
            }
            var headerDict: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String { headerDict[ks] = vs }
            }
            let bytes = data ?? Data()
            let contentType = headerDict["Content-Type"] ?? "application/octet-stream"
            let isText = contentType.hasPrefix("text/") || contentType.contains("json") || contentType.contains("xml") || contentType.contains("javascript") || contentType.contains("html")

            let bodyOut = self?.assembleBody(bytes: bytes, contentType: contentType, isText: isText, requestedUrl: urlStr) ?? [:]

            completion(WireFormat.success([
                "status": http.statusCode,
                "headers": headerDict,
                "contentType": contentType,
                "body": bodyOut,
                "url": http.url?.absoluteString ?? urlStr
            ]))
        }
        task.resume()
    }

    // MARK: - large-body sidecar promotion

    /// Default 64 KB. Override with env `INTERCEPTOR_URL_FETCH_INLINE_THRESHOLD`.
    static let defaultInlineThreshold: Int = 65_536

    /// Resolves the inline-vs-sidecar threshold per call. Reads env each time
    /// so operators can tune it without restarting the bridge.
    func inlineThreshold() -> Int {
        if let raw = ProcessInfo.processInfo.environment["INTERCEPTOR_URL_FETCH_INLINE_THRESHOLD"],
           let parsed = Int(raw), parsed > 0 {
            return parsed
        }
        return Self.defaultInlineThreshold
    }

    /// Build the `body` field of the wire response.
    /// - Small payload: returns the existing inline shape (`kind:"text"` or `kind:"bytes"`).
    /// - Large payload: writes a sidecar file and returns `kind:"bodyRef"` with
    ///   metadata the engine post-processor can register as a context artifact.
    func assembleBody(bytes: Data, contentType: String, isText: Bool, requestedUrl: String) -> [String: Any] {
        let threshold = inlineThreshold()

        if bytes.count <= threshold {
            if isText, let s = String(data: bytes, encoding: .utf8) {
                return ["kind": "text", "text": s, "bytes": bytes.count]
            } else {
                return ["kind": "bytes", "base64": bytes.base64EncodedString(), "bytes": bytes.count]
            }
        }

        // Spill to sidecar. The engine layer will see `kind:"bodyRef"` and
        // route it through the context-artifact pipeline so the model sees a
        // handle + preview, not the full payload.
        let cacheDir = Self.urlFetchCacheDir()
        do {
            try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true, attributes: [
                FileAttributeKey.posixPermissions: 0o700
            ])
        } catch {
            // If we can't create the sidecar dir, fall back to inline so the
            // turn at least completes — the engine policy will demote it.
            if isText, let s = String(data: bytes, encoding: .utf8) {
                return ["kind": "text", "text": s, "bytes": bytes.count, "sidecarUnavailable": true]
            } else {
                return ["kind": "bytes", "base64": bytes.base64EncodedString(), "bytes": bytes.count, "sidecarUnavailable": true]
            }
        }

        let artifactId = Self.mintArtifactId()
        let ext = Self.extensionForContentType(contentType)
        let filename = "url_fetch-\(artifactId).\(ext)"
        let path = (cacheDir as NSString).appendingPathComponent(filename)

        do {
            try bytes.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            if isText, let s = String(data: bytes, encoding: .utf8) {
                return ["kind": "text", "text": s, "bytes": bytes.count, "sidecarUnavailable": true]
            } else {
                return ["kind": "bytes", "base64": bytes.base64EncodedString(), "bytes": bytes.count, "sidecarUnavailable": true]
            }
        }

        // Preview slice — first 4 KB of text, or empty for binary.
        var preview = ""
        if isText, let s = String(data: bytes.prefix(4096), encoding: .utf8) {
            preview = s
        }

        return [
            "kind": "bodyRef",
            "bytes": bytes.count,
            "preview": preview,
            "sidecarPath": path,
            "artifactRef": [
                "kind": "artifact",
                "artifactId": artifactId,
                "preview": preview,
                "bytes": bytes.count,
                "contentType": contentType,
                "url": requestedUrl
            ]
        ]
    }

    static func urlFetchCacheDir() -> String {
        if let override = ProcessInfo.processInfo.environment["INTERCEPTOR_URL_FETCH_CACHE_DIR"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".local/share/interceptor/url_fetch_cache")
    }

    static func mintArtifactId() -> String {
        // Short, content-stable identifier: time-stamp + random nibble, hashed.
        let nonce = UUID().uuidString + "-" + String(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data(nonce.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    static func extensionForContentType(_ ct: String) -> String {
        let lower = ct.lowercased()
        if lower.contains("html") { return "html" }
        if lower.contains("json") { return "json" }
        if lower.contains("xml") { return "xml" }
        if lower.contains("javascript") { return "js" }
        if lower.hasPrefix("text/") { return "txt" }
        if lower.contains("png") { return "png" }
        if lower.contains("jpeg") || lower.contains("jpg") { return "jpg" }
        if lower.contains("pdf") { return "pdf" }
        return "bin"
    }
}
