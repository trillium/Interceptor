// native filesystem primitives — fs_read, fs_write, fs_search.
// Replaces the linux read / write / edit / grep primitives at the model
// boundary. Uses Foundation FileManager + UTType (where available) and
// NSMetadataQuery for indexed search via Spotlight.

import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

final class FsDomain: DomainHandler, @unchecked Sendable {
    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        switch command {
        case "read":
            handleRead(action, completion: completion)
        case "write":
            handleWrite(action, completion: completion)
        case "search":
            handleSearch(action, completion: completion)
        default:
            completion(WireFormat.error("fs: unknown command \(command)"))
        }
    }

    // MARK: fs_read
    private func handleRead(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let absolutePath = resolvePath(action) else {
            completion(WireFormat.error("fs_read: missing path or unresolvable ref"))
            return
        }
        let encoding = (action["encoding"] as? String) ?? "utf8"
        let byteRange = action["byteRange"] as? [String: Any]

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: absolutePath, isDirectory: &isDir) else {
            completion(WireFormat.error("fs_read: file not found: \(absolutePath)"))
            return
        }
        if isDir.boolValue {
            completion(WireFormat.error("fs_read: path is a directory: \(absolutePath)"))
            return
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: absolutePath)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.iso8601 ?? ""
            let url = URL(fileURLWithPath: absolutePath)
            var contentType: String = "public.data"
            #if canImport(UniformTypeIdentifiers)
            if #available(macOS 11.0, *) {
                if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                    contentType = type.identifier
                }
            }
            #endif

            let data: Data
            if let br = byteRange {
                let start = (br["start"] as? Int) ?? 0
                let length = (br["length"] as? Int) ?? max(0, size - start)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                data = (try? handle.read(upToCount: length)) ?? Data()
            } else {
                data = try Data(contentsOf: url)
            }

            let content: String
            switch encoding {
            case "base64":
                content = data.base64EncodedString()
            case "raw":
                content = data.base64EncodedString() // raw bytes shipped as base64 over JSON
            default: // utf8
                content = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
            }

            completion(WireFormat.success([
                "content": content,
                "encoding": encoding,
                "contentType": contentType,
                "attributes": [
                    "size": size,
                    "modified": modified,
                    "absolutePath": absolutePath
                ]
            ]))
        } catch {
            completion(WireFormat.error("fs_read failed: \(error.localizedDescription)"))
        }
    }

    // MARK: fs_write
    private func handleWrite(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let absolutePath = resolvePath(action) else {
            completion(WireFormat.error("fs_write: missing path or unresolvable ref"))
            return
        }
        guard let content = action["content"] as? String else {
            completion(WireFormat.error("fs_write: missing content"))
            return
        }
        // Defense in depth — never write to system paths regardless of permission rules.
        let denylist = ["/etc/", "/usr/", "/System/", "/private/var/"]
        for d in denylist {
            if absolutePath.hasPrefix(d) {
                completion(WireFormat.error("fs_write: refused — path is in protected denylist: \(absolutePath)"))
                return
            }
        }
        let encoding = (action["encoding"] as? String) ?? "utf8"
        let url = URL(fileURLWithPath: absolutePath)

        // Optional ifMatch precondition based on modified timestamp.
        if let ifMatch = action["ifMatch"] as? [String: Any],
           let expected = ifMatch["modified"] as? String {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: absolutePath),
               let actual = (attrs[.modificationDate] as? Date)?.iso8601, actual != expected {
                completion(WireFormat.error("fs_write: ifMatch precondition failed (file modified at \(actual))"))
                return
            }
        }

        let data: Data
        switch encoding {
        case "base64":
            guard let d = Data(base64Encoded: content) else {
                completion(WireFormat.error("fs_write: content is not valid base64"))
                return
            }
            data = d
        default:
            data = content.data(using: .utf8) ?? Data()
        }

        do {
            // Ensure parent directory exists.
            let parent = (absolutePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            let attrs = try FileManager.default.attributesOfItem(atPath: absolutePath)
            let written = (attrs[.size] as? NSNumber)?.intValue ?? data.count
            let modified = (attrs[.modificationDate] as? Date)?.iso8601 ?? ""
            completion(WireFormat.success([
                "written": written,
                "absolutePath": absolutePath,
                "modified": modified
            ]))
        } catch {
            completion(WireFormat.error("fs_write failed: \(error.localizedDescription)"))
        }
    }

    // MARK: fs_search
    //
    // Wire contract (input action fields):
    //   query   String — required, substring match. "*" / "**" → wildcard listing.
    //   scope   String — alias ("everywhere" | "cwd" | "workspace" | "home" |
    //                    "granted" | "path") OR an absolute path. Default: "everywhere".
    //   paths   [String]? — only honored when scope == "path"; multi-root search.
    //   cwd     String? — when scope is "cwd" or "workspace", root the search here.
    //                     If absent, falls back to the user's home directory.
    //   kinds   [String]? — additive UTI-style filter (e.g. "public.folder",
    //                       "directory", "file"). Empty/absent means "any".
    //   limit   Int — cap match count. Default: 20.
    //
    // Behavior:
    //   - "everywhere" uses NSMetadataQueryLocalComputerScope; BFS fallback is
    //     skipped because walking / unbounded would block this thread for
    //     minutes.
    //   - "cwd"/"workspace" route through the optional cwd field.
    //   - "path" with a non-empty paths array searches that multi-root set.
    //   - Wildcard-only queries on a rooted scope return a shallow native
    //     directory listing immediately (source: "direct_listing").
    //   - An unknown scope string is treated as an absolute path; if it isn't
    //     an existing absolute path, the caller gets a structured error
    //     instead of a silent override to home.
    private func handleSearch(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let query = action["query"] as? String, !query.isEmpty else {
            completion(WireFormat.error("fs_search: missing query"))
            return
        }
        let scope = (action["scope"] as? String) ?? "everywhere"
        let limit = (action["limit"] as? Int) ?? 20
        let sessionCwd = action["cwd"] as? String
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let requestedKinds = normalizedKinds(action["kinds"] as? [String])

        // Build the list of search roots. Spotlight accepts either path
        // strings or one of the well-known scope constants (e.g.
        // NSMetadataQueryLocalComputerScope = "kMDQueryScopeComputer"). The
        // BFS fallback only walks path roots; for "everywhere" it bails since
        // walking / unbounded would block this thread for minutes.
        let mqScopes: [Any]
        let bfsRoots: [String]
        let scopeLabel: String
        switch scope {
        case "everywhere":
            mqScopes = [NSMetadataQueryLocalComputerScope]
            bfsRoots = []
            scopeLabel = "everywhere"
        case "cwd":
            let root = sessionCwd ?? homePath
            mqScopes = [root]
            bfsRoots = [root]
            scopeLabel = root
        case "workspace":
            let root = sessionCwd ?? homePath
            mqScopes = [root]
            bfsRoots = [root]
            scopeLabel = root
        case "home":
            mqScopes = [homePath]
            bfsRoots = [homePath]
            scopeLabel = homePath
        case "granted":
            // Engine layer enforces the actual permission grant; the bridge
            // scopes to home as the broadest default.
            mqScopes = [homePath]
            bfsRoots = [homePath]
            scopeLabel = homePath
        case "path":
            let paths = (action["paths"] as? [String])?.filter { !$0.isEmpty } ?? []
            if paths.isEmpty {
                completion(WireFormat.error("fs_search: scope 'path' requires a non-empty paths array"))
                return
            }
            // Validate every path; reject the request rather than silently
            // dropping unreadable entries.
            for p in paths {
                if !p.hasPrefix("/") || !FileManager.default.fileExists(atPath: p) {
                    completion(WireFormat.error("fs_search: scope 'path' entry '\(p)' is not an absolute path that exists"))
                    return
                }
            }
            mqScopes = paths
            bfsRoots = paths
            scopeLabel = paths.joined(separator: ":")
        default:
            // Treat any non-alias scope as an absolute path. Validate via
            // FileManager.fileExists before adopting; on miss, return a
            // structured error so the caller sees the rejection instead of
            // a silent override to home.
            if scope.hasPrefix("/"), FileManager.default.fileExists(atPath: scope) {
                mqScopes = [scope]
                bfsRoots = [scope]
                scopeLabel = scope
            } else {
                completion(WireFormat.error("fs_search: scope '\(scope)' is not an alias (everywhere/cwd/workspace/home/granted/path) and not an absolute path that exists"))
                return
            }
        }

        // Finder-style wildcard listing should behave like a directory listing,
        // not a literal substring search for the `*` character. For rooted
        // path scopes, skip Spotlight entirely and return a shallow native
        // listing immediately.
        if isWildcardOnlyQuery(query), !bfsRoots.isEmpty {
            var allMatches: [[String: Any]] = []
            for root in bfsRoots {
                if allMatches.count >= limit { break }
                let remaining = limit - allMatches.count
                let chunk = self.directPathListing(root: root, limit: remaining, requestedKinds: requestedKinds)
                allMatches.append(contentsOf: chunk)
            }
            completion(WireFormat.success([
                "matches": allMatches,
                "indexed": false,
                "source": "direct_listing",
                "scope": scopeLabel,
                "query": query,
                "count": allMatches.count
            ]))
            return
        }

        // Try Spotlight (NSMetadataQuery) first. For machine-wide
        // ("everywhere") scope, only match filenames — kMDItemTextContent
        // across LocalComputerScope is unbounded and routinely blows past
        // the gather window. Narrower scopes can still use the compound
        // name+content predicate.
        let mq = NSMetadataQuery()
        mq.searchScopes = mqScopes
        if scope == "everywhere" {
            mq.predicate = NSPredicate(
                format: "(kMDItemDisplayName LIKE[cd] %@) OR (kMDItemFSName LIKE[cd] %@)",
                "*\(query)*", "*\(query)*"
            )
        } else {
            mq.predicate = NSPredicate(
                format: "(kMDItemDisplayName LIKE[cd] %@) OR (kMDItemFSName LIKE[cd] %@) OR (kMDItemTextContent LIKE[cd] %@)",
                "*\(query)*", "*\(query)*", "*\(query)*"
            )
        }
        mq.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]

        let lock = NSLock()
        var captured = false
        var observer: NSObjectProtocol?

        @Sendable func extractMatches(from query: NSMetadataQuery, max: Int) -> [[String: Any]] {
            var rows: [[String: Any]] = []
            for i in 0..<min(query.resultCount, max) {
                guard let item = query.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let pathUrl = URL(fileURLWithPath: path)
                let kindLabel = item.value(forAttribute: NSMetadataItemKindKey) as? String
                if !self.matchesKinds(requestedKinds, at: pathUrl, kindLabel: kindLabel) {
                    continue
                }
                var entry: [String: Any] = ["path": path]
                if let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ??
                              item.value(forAttribute: NSMetadataItemFSNameKey) as? String {
                    entry["name"] = name
                }
                if let kindLabel { entry["kind"] = kindLabel }
                if let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? Int { entry["size"] = size }
                if let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date {
                    entry["modified"] = ISO8601DateFormatter().string(from: modified)
                }
                rows.append(entry)
            }
            return rows
        }

        func finish(_ matches: [[String: Any]], indexed: Bool) {
            lock.lock(); if captured { lock.unlock(); return }; captured = true; lock.unlock()
            if let obs = observer { NotificationCenter.default.removeObserver(obs); observer = nil }
            mq.stop()
            completion(WireFormat.success([
                "matches": matches,
                "indexed": indexed,
                "source": indexed ? "spotlight" : "fallback",
                "scope": scopeLabel,
                "query": query,
                "count": matches.count
            ]))
        }

        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: mq,
            queue: nil
        ) { _ in
            mq.disableUpdates()
            let rows = extractMatches(from: mq, max: limit)
            finish(rows, indexed: true)
        }

        if !mq.start() {
            finish([], indexed: false)
            return
        }

        // Bound the wait — Spotlight should respond in <2s for indexed scopes.
        // If empty after 2s, also kick off the fallback breadth-first scan;
        // whichever produces a non-empty result first wins.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [self] in
            if captured { return }
            // Snapshot whatever Spotlight has so far; if non-empty, take it.
            mq.disableUpdates()
            let snap = extractMatches(from: mq, max: limit)
            if !snap.isEmpty {
                finish(snap, indexed: true)
                return
            }
            // Spotlight had nothing. Run the breadth-first enumerator fallback
            // across every BFS root (skip when scope is "everywhere" since
            // walking / unbounded would block this thread for minutes).
            var allMatches: [[String: Any]] = []
            for root in bfsRoots {
                if allMatches.count >= limit { break }
                let remaining = limit - allMatches.count
                let chunk = self.fallbackBfsSearch(query: query, root: root, limit: remaining, requestedKinds: requestedKinds)
                allMatches.append(contentsOf: chunk)
            }
            finish(allMatches, indexed: false)
        }
    }

    /// Breadth-first fallback that visits the workspace root's top-level
    /// children FIRST (so `Downloads` is hit before `Library` swallows the
    /// scan budget). Walks one level deep by default; matches against
    /// filename substrings (case-insensitive). Bounded at 10k items.
    private func fallbackBfsSearch(query: String, root: String, limit: Int, requestedKinds: Set<String>) -> [[String: Any]] {
        let fm = FileManager.default
        let lower = query.lowercased()
        var matches: [[String: Any]] = []
        var queue: [URL] = []
        let rootUrl = URL(fileURLWithPath: root)
        queue.append(rootUrl)
        var scanned = 0
        let maxScanned = 10_000
        let maxDepth = 4
        let isoFmt = ISO8601DateFormatter()

        func depth(of url: URL) -> Int {
            return url.pathComponents.count - rootUrl.pathComponents.count
        }

        while !queue.isEmpty && matches.count < limit && scanned < maxScanned {
            let dir = queue.removeFirst()
            let d = depth(of: dir)
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [
                .nameKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey
            ], options: [.skipsHiddenFiles]) else { continue }

            for child in children {
                scanned += 1
                if scanned >= maxScanned { break }
                let name = child.lastPathComponent
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if matchesQuery(name: name, normalizedQuery: lower) && matchesKinds(requestedKinds, at: child, kindLabel: isDir ? "directory" : "file") {
                    var entry: [String: Any] = [
                        "path": child.path,
                        "name": name,
                        "kind": isDir ? "directory" : "file"
                    ]
                    if let attrs = try? child.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                        if let size = attrs.fileSize { entry["size"] = size }
                        if let modified = attrs.contentModificationDate {
                            entry["modified"] = isoFmt.string(from: modified)
                        }
                    }
                    matches.append(entry)
                    if matches.count >= limit { break }
                }
                if d < maxDepth, isDir {
                    // Skip noisy system-managed subtrees.
                    let bn = child.lastPathComponent
                    if bn == "Library" && d == 0 { continue }
                    if bn == ".Trash" || bn == "node_modules" || bn == ".git" { continue }
                    queue.append(child)
                }
            }
        }
        return matches
    }

    /// Shallow rooted listing used for wildcard path-scoped searches.
    /// This matches what users expect from Finder-style `*` searches: return
    /// the immediate contents of the folder, filtered by kind.
    private func directPathListing(root: String, limit: Int, requestedKinds: Set<String>) -> [[String: Any]] {
        let fm = FileManager.default
        let rootUrl = URL(fileURLWithPath: root)
        let isoFmt = ISO8601DateFormatter()
        guard let children = try? fm.contentsOfDirectory(
            at: rootUrl,
            includingPropertiesForKeys: [.nameKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var out: [[String: Any]] = []
        for child in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            if out.count >= limit { break }
            let isDir = isDirectory(at: child)
            if !matchesKinds(requestedKinds, at: child, kindLabel: isDir ? "directory" : "file") {
                continue
            }
            var entry: [String: Any] = [
                "path": child.path,
                "name": child.lastPathComponent,
                "kind": isDir ? "directory" : "file",
            ]
            if let attrs = try? child.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                if let size = attrs.fileSize { entry["size"] = size }
                if let modified = attrs.contentModificationDate {
                    entry["modified"] = isoFmt.string(from: modified)
                }
            }
            out.append(entry)
        }
        return out
    }

    /// Treat shell-style wildcard-only queries like `*` / `**` as "match all"
    /// in the enumerator fallback. Spotlight's predicate language can use `*`
    /// as a wildcard, but the fallback is plain filename substring matching.
    private func matchesQuery(name: String, normalizedQuery: String) -> Bool {
        let trimmed = normalizedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if isWildcardOnlyQuery(trimmed) {
            return true
        }
        return name.lowercased().contains(trimmed)
    }

    private func isWildcardOnlyQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "*" || $0 == "?" }
    }

    /// Normalize kind filters to a lowercase set. These filters are additive
    /// over Spotlight/fallback search and intentionally broad so callers can
    /// ask for directory/file classes or pass UTI-style labels like
    /// `public.folder`.
    private func normalizedKinds(_ kinds: [String]?) -> Set<String> {
        Set((kinds ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    private func matchesKinds(_ requestedKinds: Set<String>, at url: URL, kindLabel: String?) -> Bool {
        if requestedKinds.isEmpty {
            return true
        }
        let isDir = isDirectory(at: url)
        let normalizedKindLabel = kindLabel?.lowercased() ?? ""
        for requested in requestedKinds {
            switch requested {
            case "directory", "directories", "dir", "folder", "folders", "public.folder", "public.directory":
                if isDir { return true }
            case "file", "files", "public.data", "public.item":
                if !isDir { return true }
            default:
                if requested.hasSuffix(".folder") || requested.hasSuffix(".directory") {
                    if isDir { return true }
                    continue
                }
                if !normalizedKindLabel.isEmpty && normalizedKindLabel.contains(requested) {
                    return true
                }
            }
        }
        return false
    }

    private func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: shared helpers
    private func resolvePath(_ action: [String: Any]) -> String? {
        if let p = action["path"] as? String, !p.isEmpty {
            return (p as NSString).expandingTildeInPath
        }
        if let ref = action["ref"] as? [String: Any] {
            if let kind = ref["kind"] as? String {
                if kind == "path", let path = ref["path"] as? String {
                    return (path as NSString).expandingTildeInPath
                }
                // Bookmark resolution would happen here once the engine ships
                // the bookmarkB64 payload form; specifies the wire.
                if kind == "bookmark", let b64 = ref["bookmarkB64"] as? String,
                   let data = Data(base64Encoded: b64) {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        if url.startAccessingSecurityScopedResource() {
                            // NOTE: caller is responsible for ending the scope after use.
                            // For v1 we end immediately after returning the path.
                            defer { url.stopAccessingSecurityScopedResource() }
                            return url.path
                        }
                    }
                }
            }
        }
        return nil
    }
}

private extension Date {
    var iso8601: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: self)
    }
}
