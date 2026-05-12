import XCTest
@testable import interceptor_bridge

// fs_search rich-contract regression. Pre-fix, FsDomain.handleSearch only
// honored {query, scope, limit} and silently dropped {paths, cwd, kinds}.
// The fix wires up:
//   - scope: "path" + paths:[abs...]   → multi-root Spotlight + BFS
//   - scope: "cwd" / "workspace" + cwd → root the search at cwd
//   - kinds:["public.folder", ...]      → additive filter
//   - query:"*" wildcard fast path on rooted scopes → source:"direct_listing"
// Verifies the dispatch_table the Cy adapter ships against.

private final class _FsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any]?
    func set(_ v: [String: Any]) { lock.lock(); storage = v; lock.unlock() }
    func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return storage }
}

final class FsDomainSearchTests: XCTestCase {

    private func makeScratchTree() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("interceptor-fs-search-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("alpha", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("beta", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".hidden-dir", isDirectory: true), withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        return root
    }

    private func dispatch(_ action: [String: Any]) -> [String: Any] {
        let domain = FsDomain()
        let exp = expectation(description: "fs_search completion")
        let box = _FsBox()
        domain.handle("search", action: action) { r in
            box.set(r)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 8.0)
        return box.get() ?? [:]
    }

    // Mirrors the reflog 27c6be6 contract test — the scenario the original
    // Cy session was failing on: scope:"path" + paths + kinds + wildcard.
    func testWildcardPathSearchReturnsVisibleDirectoriesOnly() throws {
        let root = try makeScratchTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = dispatch([
            "type": "macos_fs_search",
            "query": "*",
            "scope": "path",
            "paths": [root.path],
            "limit": 50,
            "kinds": ["public.folder"],
        ])

        XCTAssertEqual(result["success"] as? Bool, true, "should succeed; got: \(result)")
        let data = result["data"] as? [String: Any]
        XCTAssertEqual(data?["indexed"] as? Bool, false)
        XCTAssertEqual(data?["source"] as? String, "direct_listing")
        XCTAssertEqual(data?["count"] as? Int, 2)

        let matches = data?["matches"] as? [[String: Any]] ?? []
        let names = Set(matches.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, Set(["alpha", "beta"]))
        XCTAssertFalse(names.contains(".hidden-dir"))
        XCTAssertFalse(names.contains("note.txt"))
    }

    func testCwdRoutingLandsAtCwdNotHome() throws {
        let root = try makeScratchTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = dispatch([
            "type": "macos_fs_search",
            "query": "*",
            "scope": "cwd",
            "cwd": root.path,
            "limit": 50,
        ])

        XCTAssertEqual(result["success"] as? Bool, true)
        let data = result["data"] as? [String: Any]
        XCTAssertEqual(data?["scope"] as? String, root.path,
                       "scope label must reflect cwd, not home")
        XCTAssertEqual(data?["source"] as? String, "direct_listing")
    }

    func testWorkspaceRoutingLandsAtCwdNotHome() throws {
        let root = try makeScratchTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = dispatch([
            "type": "macos_fs_search",
            "query": "*",
            "scope": "workspace",
            "cwd": root.path,
            "limit": 50,
        ])

        XCTAssertEqual(result["success"] as? Bool, true)
        let data = result["data"] as? [String: Any]
        XCTAssertEqual(data?["scope"] as? String, root.path,
                       "workspace must honor cwd field, not silently fall back to home")
    }

    func testEmptyPathsArrayInPathScopeRejects() throws {
        let result = dispatch([
            "type": "macos_fs_search",
            "query": "anything",
            "scope": "path",
            "paths": [],
        ])
        let err = (result["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("non-empty paths"),
                      "empty paths array must produce a structured error, got: \(err)")
    }

    func testPathsScopeRejectsNonexistentEntry() throws {
        let result = dispatch([
            "type": "macos_fs_search",
            "query": "anything",
            "scope": "path",
            "paths": ["/this/path/does/not/exist/PRD66"],
        ])
        let err = (result["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("not an absolute path that exists"),
                      "non-existent path entry must produce a structured error, got: \(err)")
    }

    func testFileKindFilterExcludesDirectories() throws {
        let root = try makeScratchTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = dispatch([
            "type": "macos_fs_search",
            "query": "*",
            "scope": "path",
            "paths": [root.path],
            "kinds": ["file"],
            "limit": 50,
        ])

        XCTAssertEqual(result["success"] as? Bool, true)
        let data = result["data"] as? [String: Any]
        let matches = data?["matches"] as? [[String: Any]] ?? []
        let names = Set(matches.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, Set(["note.txt"]),
                       "kinds:[file] should return note.txt only, got \(names)")
    }
}
