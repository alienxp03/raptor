import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorExecx
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

private final class ReviewFixture {
    var directories = ["/a/one", "/b/two"]
    var trees = ["/a/one": "/a", "/a/other": "/a", "/b/two": "/b"]
    var removed: [String] = []
    var dirty: Set<String> = []
    var unmerged: Set<String> = []
    var failedPath = ""
    var retainedBranch = ""
    var branchVerificationFails = false
    var fingerprintFails = false
    var nestedGitMetadata: [String: String] = [:]
    var head = "tip"
    var branches: [String: String] = [:]
    var fingerprints: [String: String] = [:]
    var recordFields: [String: String] = [:]
    var duplicateRegistration = false
    var blocks = ["block:one", "block:two"]
    var hostID = "identity"
    var closed = false
    var closeFails = false
    var afterRemove: (() -> Void)?
    var commands: [(String, String, [String])] = []

    func root(_ dir: String) -> String? {
        (Array(trees.keys) + Array(trees.values) + ["/a", "/b"]).sorted { $0.count > $1.count }
            .first { dir == $0 || dir.hasPrefix($0 + "/") }
    }

    func command(_ dir: String, _ name: String, _ args: [String]) throws -> ExecResult {
        commands.append((dir, name, args))
        if name == "test" { return ExecResult(code: removed.contains(args.last!) ? 1 : 0) }
        if name == "find" { return ExecResult(stdout: nestedGitMetadata[dir] ?? "") }
        if name == "/bin/bash" {
            return fingerprintFails ? ExecResult(stderr: "fingerprint failed: unreadable dependency", code: 1) : ExecResult(stdout: fingerprints[dir] ?? "digest")
        }
        if name == "wt" {
            if args.first != "remove" { return ExecResult(stdout: "{\"repo\":{\"default_branch\":\"main\"}}") }
            let path = args.last!
            if path == failedPath { return ExecResult(stderr: "remove failed", code: 1) }
            removed.append(path)
            afterRemove?()
            return ExecResult(stdout: "{\"path\":\"\(path)\",\"branch\":\"feat/\(URL(fileURLWithPath: path).lastPathComponent)\",\"branch_outcome\":\"\(path == retainedBranch ? "retained" : "deleted")\"}")
        }
        if args == ["rev-parse", "--show-toplevel"] {
            guard let path = root(dir), !removed.contains(path) else { return ExecResult(code: 1) }
            return ExecResult(stdout: path + "\n")
        }
        let repo = trees[root(dir) ?? dir] ?? dir
        if args.contains("--git-common-dir") { return ExecResult(stdout: repo + "/.git\n") }
        if args.first == "worktree" {
            var listing = "worktree \(repo)\0HEAD base\0branch refs/heads/main\0\0"
            for path in trees.keys.sorted() where trees[path] == repo && path != repo && !removed.contains(path) {
                let record = "worktree \(path)\0HEAD \(head)\0branch refs/heads/\(branches[path] ?? "feat/" + URL(fileURLWithPath: path).lastPathComponent)\0" + (recordFields[path].map { $0 + "\0" } ?? "") + "\0"
                listing += record
                if duplicateRegistration { listing += record }
            }
            return ExecResult(stdout: listing)
        }
        if args.first == "symbolic-ref" { return ExecResult(stdout: "refs/heads/" + (branches[dir] ?? "feat/" + URL(fileURLWithPath: dir).lastPathComponent) + "\n") }
        if args.first == "rev-parse" { return ExecResult(stdout: args.last == "refs/heads/main" ? "base\n" : head + "\n") }
        if args.first == "merge-base" { return ExecResult(code: unmerged.contains(dir) ? 1 : 0) }
        if args.first == "status" { return ExecResult(stdout: dirty.contains(dir) ? "?? file\0" : "") }
        if args.first == "diff" { return ExecResult() }
        if args.first == "show-ref" {
            if branchVerificationFails { throw MessageError("Branch verification failed") }
            let path = trees.keys.first { "refs/heads/feat/" + URL(fileURLWithPath: $0).lastPathComponent == args.last }
            return ExecResult(code: path.map { removed.contains($0) && $0 != retainedBranch ? 1 : 0 } ?? 0)
        }
        XCTFail("Unexpected command \(dir) \(name) \(args)")
        return ExecResult(code: 2)
    }
}

final class WorktreeReviewTests: APITestCase {
    private func handler(_ f: ReviewFixture, host: String = "") -> Handler {
        env.set("XDG_CACHE_HOME", FileManager.default.currentDirectoryPath + "/aux/review-" + UUID().uuidString)
        env.unset("REX_SESSION")
        let h = Handler(ctx: Ctx(session: "session:origin"), cfg: .default())
        h.loadDeletionSession = { selected, sid in
            XCTAssertEqual(selected, host)
            return DeletionSessionState(hostID: f.hostID, sessionID: sid, directories: f.directories, blocks: f.blocks)
        }
        h.runDeletionCommand = { selected, _, identity in
            XCTAssertEqual(selected, host)
            XCTAssertEqual(identity, "identity")
            return f.command
        }
        h.closeDeletedSession = { _, _ in
            if f.closeFails { throw MessageError("Close failed") }
            f.closed = true
        }
        return h
    }

    private func request(_ h: Handler, token: String? = nil, paths: Any = ["/a/one", "/b/two"],
                         consent: Bool = true, force: Bool = false, host: String = "", sid: String = "session:target") throws -> [String: Any] {
        let params: [String: Any] = ["kind": "session", "session_id": sid, "host": host,
            "review_worktrees": true, "delete_token": token ?? "", "selected_paths": paths,
            "close_session": consent, "force": force]
        let bytes = try JSONSerialization.data(withJSONObject: params)
        let (result, error) = h.call(CancelToken(), token == nil ? "sessions.delete.preview" : "sessions.delete", Array(bytes))
        XCTAssertNil(error)
        return try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result).encode().utf8)) as! [String: Any]
    }

    private func preview(_ h: Handler, host: String = "") throws -> String {
        try XCTUnwrap(request(h, host: host)["delete_token"] as? String)
    }

    private func progressive(_ h: Handler, token: String? = nil, path: String = "", host: String = "",
                             sid: String = "session:target", metadataOnly: Bool = false) throws -> [String: Any] {
        let params: [String: Any] = ["kind": "session", "session_id": sid, "host": host,
            "review_worktrees": true, "discover_only": true, "delete_token": token ?? "", "path": path,
            "metadata_only": metadataOnly]
        let (result, error) = h.call(CancelToken(), token == nil ? "sessions.delete.preview" : "sessions.delete.check",
                                    Array(try JSONSerialization.data(withJSONObject: params)))
        XCTAssertNil(error)
        return try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result).encode().utf8)) as! [String: Any]
    }

    private func metadataPreview(_ h: Handler) throws -> String {
        let token = try XCTUnwrap(progressive(h, metadataOnly: true)["delete_token"] as? String)
        for source in try XCTUnwrap(h.worktreeReviewTickets[token]?.discoveryPaths).sorted() {
            _ = try progressive(h, token: token, path: source, metadataOnly: true)
        }
        return token
    }

    private func prepare(_ h: Handler, _ token: String, path: String = "/a/one",
                         paths: Any = ["/a/one"]) throws -> [String: Any] {
        let params: [String: Any] = ["kind": "session", "session_id": "session:target", "host": "",
            "review_worktrees": true, "delete_token": token, "path": path, "selected_paths": paths]
        let (result, error) = h.call(CancelToken(), "sessions.delete.prepare",
                                    Array(try JSONSerialization.data(withJSONObject: params)))
        XCTAssertNil(error)
        return try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result).encode().utf8)) as! [String: Any]
    }

    private func heavyweight(_ command: (String, String, [String])) -> Bool {
        command.1 != "git" || !["rev-parse", "worktree"].contains(command.2.first ?? "")
    }

    func testMetadataDiscoveryAndChecksNeverRunHeavyweightCommands() throws {
        let f = ReviewFixture(), h = handler(f)
        let discovery = try progressive(h, metadataOnly: true)
        XCTAssertTrue(f.commands.isEmpty)
        XCTAssertTrue((discovery["worktrees"] as! [[String: Any]]).allSatisfy {
            $0["checked"] as? Bool == false && $0["prepared"] as? Bool == false
        })
        let token = discovery["delete_token"] as! String
        for source in f.directories { _ = try progressive(h, token: token, path: source, metadataOnly: true) }
        let rows = try XCTUnwrap(h.worktreeReviewTickets[token]?.rows)
        XCTAssertTrue(rows.allSatisfy { $0.checked && !$0.prepared && $0.plan == nil && $0.eligible })
        XCTAssertFalse(f.commands.contains(where: heavyweight))
        XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
        XCTAssertTrue(f.removed.isEmpty)
    }

    func testMetadataOnlyPreviewAlsoAvoidsHeavyweightCommands() throws {
        let f = ReviewFixture(), h = handler(f)
        let params = "{\"kind\":\"session\",\"session_id\":\"session:target\",\"review_worktrees\":true,\"metadata_only\":true}"
        let (result, error) = h.call(CancelToken(), "sessions.delete.preview", Array(params.utf8))
        XCTAssertNil(error)
        XCTAssertNotNil(result)
        XCTAssertTrue(h.worktreeReviewTickets.values.first?.rows.allSatisfy { $0.eligible && !$0.prepared } == true)
        XCTAssertFalse(f.commands.contains(where: heavyweight))
    }

    func testMetadataAliasesCacheOnlyAfterResolvingEachSourceAndProtectNestedParent() throws {
        let f = ReviewFixture()
        f.directories = ["/a/one/subdir", "/a/one/another", "/a/one/nested", "/a", "/unknown"]
        f.trees["/a/one/nested"] = "/b"
        let h = handler(f), token = try metadataPreview(h)
        let rows = try XCTUnwrap(h.worktreeReviewTickets[token]?.rows)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first { $0.path == "/a/one" }?.error,
                       "Cannot delete this worktree: it contains `/a/one/nested`.")
        XCTAssertTrue(rows.first { $0.path == "/a" }?.isPrimary == true)
        XCTAssertNotNil(rows.first { $0.path == "/unknown" }?.error)
        XCTAssertEqual(f.commands.filter { $0.0 == "/a/one" && $0.2.first == "worktree" }.count, 1)
        XCTAssertTrue(f.commands.contains { $0.0 == "/a/one/nested" && $0.2 == ["rev-parse", "--show-toplevel"] })
        XCTAssertFalse(f.commands.contains(where: heavyweight))
        XCTAssertNotNil(try prepare(h, token)["error"])
        XCTAssertTrue(f.removed.isEmpty)
    }

    func testMetadataRejectsLockedPrunableAndDuplicateRegistrations() throws {
        for field in ["locked", "locked reason", "prunable reason", "duplicate"] {
            let f = ReviewFixture(), h = handler(f)
            if field == "duplicate" { f.duplicateRegistration = true }
            else { f.recordFields["/a/one"] = field }
            let token = try metadataPreview(h)
            XCTAssertNotNil(h.worktreeReviewTickets[token]?.rows.first { $0.path == "/a/one" }?.error)
            XCTAssertNotNil(try prepare(h, token)["error"])
            XCTAssertFalse(f.commands.contains(where: heavyweight))
        }
    }

    func testPreparationIsSelectedOnlyReadOnlyAndRequiresFinalConsent() throws {
        let f = ReviewFixture(), h = handler(f), token = try metadataPreview(h)
        f.commands.removeAll()
        let result = try prepare(h, token)
        XCTAssertNil(result["error"])
        let rows = result["worktrees"] as! [[String: Any]]
        XCTAssertEqual(rows.map { $0["prepared"] as? Bool }, [true, false])
        XCTAssertEqual(f.commands.filter { $0.1 == "/bin/bash" }.map { $0.0 }, ["/a/one"])
        XCTAssertFalse(f.commands.contains { $0.0 == "/b/two" })
        XCTAssertTrue(f.removed.isEmpty)
        XCTAssertFalse(f.closed)
        XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"], consent: false)["error"])
        XCTAssertTrue(f.removed.isEmpty)
        XCTAssertNil(try request(h, token: token, paths: ["/a/one"])["error"])
        XCTAssertEqual(f.removed, ["/a/one"])
        XCTAssertTrue(f.closed)
    }

    func testPreparationFreezesExactSelectionAndSuccessfulPlan() throws {
        let f = ReviewFixture(), h = handler(f), token = try metadataPreview(h)
        let selected = ["/a/one", "/b/two"]
        XCTAssertNil(try prepare(h, token, paths: selected)["error"])
        let before = f.commands.count
        let plan = h.worktreeReviewTickets[token]?.rows.first?.plan
        f.fingerprints["/a/one"] = "changed"
        XCTAssertNil(try prepare(h, token, paths: selected.reversed().map { $0 })["error"])
        XCTAssertEqual(f.commands.count, before)
        XCTAssertEqual(h.worktreeReviewTickets[token]?.rows.first?.plan, plan)
        XCTAssertNotNil(try prepare(h, token, path: "/b/two", paths: ["/b/two"])["error"])
        XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
        XCTAssertNotNil(try request(h, token: token, paths: selected)["error"])
        XCTAssertNotNil(try progressive(h, token: token, path: "/a/one", metadataOnly: true)["error"])
        XCTAssertTrue(f.removed.isEmpty)
    }

    func testPreparationRejectsBranchHeadAndRegistrationChangesBeforeHashing() throws {
        for change in 0..<3 {
            let f = ReviewFixture(), h = handler(f), token = try metadataPreview(h)
            switch change {
            case 0: f.head = "changed"
            case 1: f.branches["/a/one"] = "feat/new"
            default: f.recordFields["/a/one"] = "locked reason"
            }
            f.commands.removeAll()
            let result = try prepare(h, token)
            let rows = result["worktrees"] as! [[String: Any]]
            XCTAssertNotNil(rows.first?["error"])
            XCTAssertEqual(rows.first?["prepared"] as? Bool, false)
            XCTAssertFalse(f.commands.contains(where: heavyweight))
            XCTAssertNotNil(h.worktreeReviewTickets[token])
            XCTAssertTrue(f.removed.isEmpty)
        }
    }

    func testPreparationFailureRetainsBaselineTokenAndExactSelectionForRetry() throws {
        let f = ReviewFixture(), h = handler(f), token = try metadataPreview(h)
        f.fingerprintFails = true
        let failed = try prepare(h, token)
        XCTAssertTrue(((failed["worktrees"] as! [[String: Any]]).first?["error"] as? String ?? "").contains("fingerprint failed: unreadable dependency"))
        XCTAssertEqual(h.worktreeReviewTickets[token]?.frozenSelection, ["/a/one"])
        XCTAssertNotNil(try prepare(h, token, path: "/b/two", paths: ["/b/two"])["error"])
        f.fingerprintFails = false
        h.worktreeReviewTickets[token]?.expires = Date().addingTimeInterval(1)
        let retry = try prepare(h, token)
        XCTAssertNil((retry["worktrees"] as! [[String: Any]]).first?["error"])
        XCTAssertGreaterThan(try XCTUnwrap(h.worktreeReviewTickets[token]?.expires), Date().addingTimeInterval(200))
        XCTAssertNil(try request(h, token: token, paths: ["/a/one"])["error"])
        XCTAssertEqual(f.removed, ["/a/one"])
    }

    func testUnselectedContentChangesNeverCauseContentScansButSelectedChangesBlockDelete() throws {
        for selectedChanged in [false, true] {
            let f = ReviewFixture(), h = handler(f), token = try metadataPreview(h)
            _ = try prepare(h, token)
            f.commands.removeAll()
            f.fingerprints[selectedChanged ? "/a/one" : "/b/two"] = "new content"
            let result = try request(h, token: token, paths: ["/a/one"])
            XCTAssertEqual(result["error"] != nil, selectedChanged)
            XCTAssertFalse(f.commands.contains { $0.0 == "/b/two" && heavyweight($0) })
            XCTAssertEqual(f.removed, selectedChanged ? [] : ["/a/one"])
        }
    }

    func testPreparedDeleteRevalidatesUnselectedRootStructureAndMetadata() throws {
        for change in 0..<3 {
            let f = ReviewFixture(), h = handler(f), token = try metadataPreview(h)
            _ = try prepare(h, token)
            switch change {
            case 0: f.branches["/b/two"] = "feat/changed"
            case 1: f.trees.removeValue(forKey: "/b/two")
            default: f.recordFields["/b/two"] = "locked"
            }
            f.commands.removeAll()
            XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
            XCTAssertFalse(f.commands.contains(where: heavyweight))
            XCTAssertTrue(f.removed.isEmpty)
            XCTAssertNil(h.worktreeReviewTickets[token])
        }
    }

    func testPreparedSubsetKeepsUnknownRowsAndDeduplicatedAliasesSafe() throws {
        let f = ReviewFixture()
        f.directories = ["/a/one/subdir", "/a/one/another", "/unknown"]
        let h = handler(f), token = try metadataPreview(h)
        XCTAssertEqual(h.worktreeReviewTickets[token]?.rows.count, 2)
        _ = try prepare(h, token)
        XCTAssertTrue(h.worktreeReviewTickets[token]?.sourceRows.values.filter { $0.path == "/a/one" }
            .allSatisfy { $0.prepared && $0.plan != nil } == true)
        XCTAssertNil(try request(h, token: token, paths: ["/a/one"])["error"])
        XCTAssertEqual(f.removed, ["/a/one"])
        XCTAssertTrue(f.closed)
    }

    func testFailedPreparationCannotAcquireNewIdentityOnRetry() throws {
        let f = ReviewFixture(), h = handler(f), token = try metadataPreview(h)
        f.head = "changed"
        _ = try prepare(h, token)
        f.fingerprintFails = false
        _ = try prepare(h, token)
        XCTAssertFalse(h.worktreeReviewTickets[token]?.rows.first?.prepared ?? true)
        XCTAssertFalse(f.commands.contains(where: heavyweight))
        f.head = "tip"
        _ = try prepare(h, token)
        XCTAssertTrue(h.worktreeReviewTickets[token]?.rows.first?.prepared == true)
        XCTAssertNil(try request(h, token: token, paths: ["/a/one"])["error"])
    }

    func testPrepareAndPreparedDeleteKeepSessionHostOriginAndExpiryGuards() throws {
        for prepareFirst in [false, true] {
            for change in 0..<5 {
                let f = ReviewFixture(), h = handler(f), token = try metadataPreview(h)
                if prepareFirst { _ = try prepare(h, token) }
                switch change {
                case 0: f.hostID = "changed"
                case 1: f.blocks.append("new")
                case 2: f.directories.append("/a/other")
                case 3: h.ctx.session = "session:target"
                default: h.worktreeReviewTickets[token]?.expires = Date().addingTimeInterval(-1)
                }
                f.commands.removeAll()
                let result = try prepareFirst ? request(h, token: token, paths: ["/a/one"]) : prepare(h, token)
                XCTAssertNotNil(result["error"])
                XCTAssertTrue(f.commands.isEmpty)
                XCTAssertTrue(f.removed.isEmpty)
                XCTAssertFalse(f.closed)
            }
        }
    }

    func testPreparedForceAndPartialOutcomeKeepExistingGuards() throws {
        for partial in [false, true] {
            let f = ReviewFixture(), h = handler(f)
            f.dirty = ["/a/one"]
            let token = try metadataPreview(h), selected = ["/a/one", "/b/two"]
            for path in selected { _ = try prepare(h, token, path: path, paths: selected) }
            XCTAssertNotNil(try request(h, token: token, force: true)["error"])
            XCTAssertEqual(try request(h, token: token)["force_available"] as? Bool, true)
            XCTAssertTrue(f.removed.isEmpty)
            XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"], force: true)["error"])
            if partial { f.failedPath = "/b/two" }
            let result = try request(h, token: token, force: true)
            XCTAssertEqual(result["error"] != nil, partial)
            XCTAssertEqual(f.removed, partial ? ["/a/one"] : selected)
            XCTAssertEqual(f.closed, !partial)
            XCTAssertNil(h.worktreeReviewTickets[token])
            XCTAssertEqual(h.deletionTombstones.filter { !$0.path.isEmpty }.map { $0.path }, f.removed)
        }
    }

    func testPrepareRequiresReviewFlagAndCompleteDiscoveryAndValidSubset() throws {
        let f = ReviewFixture(), h = handler(f)
        let token = try XCTUnwrap(progressive(h, metadataOnly: true)["delete_token"] as? String)
        XCTAssertNotNil(try prepare(h, token)["error"])
        for path in f.directories { _ = try progressive(h, token: token, path: path, metadataOnly: true) }
        for paths: Any in [[], ["/a/one", "/a/one"], ["/a/other"], [1], "bad"] {
            XCTAssertNotNil(try prepare(h, token, paths: paths)["error"])
        }
        XCTAssertNotNil(try prepare(h, token, path: "/b/two")["error"])
        let (_, error) = h.call(CancelToken(), "sessions.delete.prepare", Array("{\"kind\":\"session\"}".utf8))
        XCTAssertNotNil(error)
        XCTAssertFalse(f.commands.contains(where: heavyweight))
    }

    func testNestedCheckoutsWithoutRexPanesRemainProtected() throws {
        let registered = ReviewFixture()
        registered.directories = ["/a/one"]
        registered.trees["/a/one/nested"] = "/a"
        let registeredHandler = handler(registered)
        let token = try metadataPreview(registeredHandler)
        XCTAssertEqual(registeredHandler.worktreeReviewTickets[token]?.rows.first?.error,
                       "Cannot delete this worktree: it contains `/a/one/nested`.")
        XCTAssertNotNil(try prepare(registeredHandler, token)["error"])
        XCTAssertFalse(registered.commands.contains { $0.1 == "find" }, "Metadata preview must not traverse files")
        XCTAssertTrue(registered.removed.isEmpty)

        let unregistered = ReviewFixture()
        unregistered.directories = ["/a/one"]
        unregistered.nestedGitMetadata["/a/one"] = "./nested/.git\n"
        let h = handler(unregistered)
        let otherToken = try metadataPreview(h)
        XCTAssertTrue(h.worktreeReviewTickets[otherToken]?.rows.first?.eligible == true)
        let prepared = try prepare(h, otherToken)
        let rows = try XCTUnwrap(prepared["worktrees"] as? [[String: Any]])
        XCTAssertTrue((rows.first?["error"] as? String ?? "").contains("nested Git metadata found"))
        XCTAssertEqual(rows.first?["prepared"] as? Bool, false)
        XCTAssertNotNil(try request(h, token: otherToken, paths: ["/a/one"])["error"])
        XCTAssertTrue(unregistered.removed.isEmpty)
        XCTAssertFalse(unregistered.closed)
    }

    func testSuccessfulMetadataAliasReplacesAnEarlierRootError() throws {
        let f = ReviewFixture(), h = handler(f)
        let identity = WorktreeReviewIdentity(path: "/a/one", repo: "/a", branch: "feature", head: "head", registration: "record")
        let failed = WorktreeReviewRow(repo: "", path: "/a/one", branch: "", error: "Temporary listing failure", prepared: false)
        let ready = WorktreeReviewRow(repo: "/a", path: "/a/one", branch: "feature", prepared: false, metadata: identity)
        let ticket = WorktreeReviewTicket(host: "", session: DeletionSessionState(hostID: "identity", sessionID: "session:target",
            directories: ["/a/one/first", "/a/one/second"], blocks: []), rows: [], expires: Date().addingTimeInterval(300),
            discoveryPaths: ["/a/one/first", "/a/one/second"], sourceRows: ["/a/one/first": failed, "/a/one/second": ready], metadataOnly: true)
        let rows = h.accumulatedReviewRows(ticket)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].eligible)
        XCTAssertNil(rows[0].error)
        XCTAssertFalse(rows[0].prepared)
    }

    func testProgressiveDiscoveryChecksAndFinalDeletion() throws {
        let f = ReviewFixture(), h = handler(f)
        let discovery = try progressive(h)
        let token = try XCTUnwrap(discovery["delete_token"] as? String)
        XCTAssertTrue(f.commands.isEmpty)
        let initial = try XCTUnwrap(discovery["worktrees"] as? [[String: Any]])
        XCTAssertEqual(initial.compactMap { $0["path"] as? String }, f.directories)
        XCTAssertTrue(initial.allSatisfy { $0["checked"] as? Bool == false && $0["repo"] as? String == "" })
        XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
        let first = try progressive(h, token: token, path: "/a/one")
        let rows = try XCTUnwrap(first["worktrees"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["checked"] as? Bool }, [true, false])
        XCTAssertFalse(f.commands.contains { $0.0 == "/b/two" })
        XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
        _ = try progressive(h, token: token, path: "/b/two")
        XCTAssertTrue(f.removed.isEmpty)
        XCTAssertNil(try request(h, token: token)["error"])
        XCTAssertTrue(f.closed)
    }

    func testProgressiveSubdirectoriesReuseFingerprintAndKeepNestedRepositories() throws {
        let f = ReviewFixture()
        f.directories = ["/a/one/subdir", "/a/one/another", "/a/one/nested"]
        f.trees["/a/one/nested"] = "/b"
        let h = handler(f)
        let token = try XCTUnwrap(progressive(h)["delete_token"] as? String)
        _ = try progressive(h, token: token, path: f.directories[0])
        _ = try progressive(h, token: token, path: f.directories[1])
        XCTAssertEqual(f.commands.filter { $0.1 == "/bin/bash" }.count, 1)
        let final = try progressive(h, token: token, path: f.directories[2])
        let rows = try XCTUnwrap(final["worktrees"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0["checked"] as? Bool == true })
        XCTAssertEqual(rows.first?["error"] as? String, "Cannot delete this worktree: it contains `/a/one/nested`.")
        XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
        XCTAssertTrue(f.removed.isEmpty)
    }

    func testProgressiveErrorRetryByResolvedRoot() throws {
        let f = ReviewFixture()
        f.directories = ["/a/one/subdir"]
        f.fingerprintFails = true
        let h = handler(f)
        let token = try XCTUnwrap(progressive(h)["delete_token"] as? String)
        let failed = try progressive(h, token: token, path: f.directories[0])
        let rows = try XCTUnwrap(failed["worktrees"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["checked"] as? Bool, true)
        XCTAssertTrue((rows.first?["error"] as? String ?? "").contains("fingerprint failed: unreadable dependency"))
        f.fingerprintFails = false
        let retried = try progressive(h, token: token, path: "/a/one")
        XCTAssertNil((retried["worktrees"] as? [[String: Any]])?.first?["error"])
        XCTAssertNil(try request(h, token: token, paths: ["/a/one"])["error"])
    }

    func testProgressiveExactRootPendingAndCompletedChecksReusePlans() throws {
        let f = ReviewFixture()
        f.directories = ["/a/one/subdir", "/a/one"]
        let h = handler(f)
        let token = try XCTUnwrap(progressive(h)["delete_token"] as? String)
        _ = try progressive(h, token: token, path: f.directories[0])
        XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
        h.worktreeReviewTickets[token]?.expires = Date().addingTimeInterval(1)
        let checked = try progressive(h, token: token, path: "/a/one")
        XCTAssertEqual((checked["worktrees"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(f.commands.filter { $0.1 == "/bin/bash" }.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(h.worktreeReviewTickets[token]?.expires), Date().addingTimeInterval(200))
        let before = f.commands.count
        _ = try progressive(h, token: token, path: "/a/one")
        XCTAssertEqual(f.commands.count, before)
        XCTAssertNil(try request(h, token: token, paths: ["/a/one"])["error"])
    }

    func testProgressiveFailedRootResolutionRetryUsesOriginalMembership() throws {
        let f = ReviewFixture()
        f.directories = ["/unknown"]
        let h = handler(f)
        let token = try XCTUnwrap(progressive(h)["delete_token"] as? String)
        let failed = try progressive(h, token: token, path: "/unknown")
        XCTAssertNotNil((failed["worktrees"] as? [[String: Any]])?.first?["error"])
        f.trees["/unknown"] = "/a"
        let retried = try progressive(h, token: token, path: "/unknown")
        XCTAssertNil((retried["worktrees"] as? [[String: Any]])?.first?["error"])
        XCTAssertNil(try request(h, token: token, paths: ["/unknown"])["error"])
    }

    func testProgressiveForceKeepsCompletedPlansAndExactSelection() throws {
        let f = ReviewFixture(), h = handler(f)
        f.dirty = ["/a/one"]
        let token = try XCTUnwrap(progressive(h)["delete_token"] as? String)
        for path in f.directories { _ = try progressive(h, token: token, path: path) }
        let rows = try XCTUnwrap(h.worktreeReviewTickets[token]?.rows)
        let offer = try request(h, token: token, paths: ["/a/one"])
        XCTAssertEqual(offer["force_available"] as? Bool, true)
        _ = try progressive(h, token: token, path: "/a/one")
        XCTAssertEqual(h.worktreeReviewTickets[token]?.rows, rows)
        XCTAssertNotNil(try request(h, token: token, paths: ["/b/two"], force: true)["error"])
        XCTAssertNil(try request(h, token: token, paths: ["/a/one"], force: true)["error"])
        XCTAssertEqual(f.removed, ["/a/one"])
    }

    func testProgressiveIdentityMembershipOriginAndExpiryGuards() throws {
        for change in 0..<7 {
            let f = ReviewFixture(), h = handler(f)
            let token = try XCTUnwrap(progressive(h)["delete_token"] as? String)
            var path = "/a/one", host = "", sid = "session:target"
            switch change {
            case 0: path = "/a/one/arbitrary"
            case 1: host = "elsewhere"
            case 2: sid = "session:other"
            case 3: f.hostID = "changed"
            case 4: f.blocks.append("new")
            case 5: h.ctx.session = "session:target"
            default: h.worktreeReviewTickets[token]?.expires = Date().addingTimeInterval(-1)
            }
            let result = try progressive(h, token: token, path: path, host: host, sid: sid)
            XCTAssertNotNil(result["error"])
            XCTAssertEqual((result["worktrees"] as? [[String: Any]])?.count, 2)
            XCTAssertTrue(f.commands.isEmpty)
            XCTAssertTrue(f.removed.isEmpty)
        }
    }

    func testProgressiveErrorRowAllowsSafeSubsetDeletion() throws {
        let f = ReviewFixture()
        f.directories = ["/a/one", "/unknown"]
        let h = handler(f)
        let token = try XCTUnwrap(progressive(h)["delete_token"] as? String)
        for path in f.directories { _ = try progressive(h, token: token, path: path) }
        let result = try request(h, token: token, paths: ["/a/one"])
        XCTAssertNil(result["error"])
        XCTAssertEqual(f.removed, ["/a/one"])
        XCTAssertTrue(f.closed)
    }

    func testProgressiveTicketBoundAndUnknownToken() throws {
        let f = ReviewFixture(), h = handler(f)
        let oldest = try XCTUnwrap(progressive(h)["delete_token"] as? String)
        for _ in 0..<64 { _ = try progressive(h) }
        XCTAssertEqual(h.worktreeReviewTickets.count, 1)
        XCTAssertNotNil(try progressive(h, token: oldest, path: "/a/one")["error"])
        XCTAssertNotNil(try progressive(h, token: "unknown", path: "/a/one")["error"])
        XCTAssertTrue(f.commands.isEmpty)
    }

    func testProgressiveEmptyDiscoveryAndCheckRequiresReviewFlag() throws {
        let f = ReviewFixture()
        f.directories = []
        let h = handler(f)
        let discovery = try progressive(h)
        let rows = try XCTUnwrap(discovery["worktrees"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["checked"] as? Bool, true)
        XCTAssertNotNil(rows.first?["error"])
        XCTAssertTrue(f.commands.isEmpty)
        let (_, error) = h.call(CancelToken(), "sessions.delete.check", Array("{\"kind\":\"session\"}".utf8))
        XCTAssertNotNil(error)
        XCTAssertTrue(f.commands.isEmpty)
    }

    func testMultiRepoAndSameRepoSequentialRemoval() throws {
        for paths in [["/a/one", "/b/two"], ["/a/one", "/a/other"]] {
            for host in ["", "devbox"] {
                let f = ReviewFixture()
                f.directories = paths
                let h = handler(f, host: host)
                let result = try request(h, token: preview(h, host: host), paths: paths, host: host)
                XCTAssertNil(result["error"])
                XCTAssertEqual(Set(result["deleted_paths"] as! [String]), Set(paths))
                XCTAssertTrue(f.closed)
                XCTAssertFalse(f.removed.contains(paths.contains("/a/other") ? "/b/two" : "/a/other"))
                XCTAssertEqual((result["worktrees"] as? [[String: Any]])?.count, 2)
                XCTAssertFalse(f.commands.contains { $0.2.contains("push") || $0.2.contains("branch") })
                XCTAssertNotNil(try request(h, token: result["delete_token"] as? String, paths: paths, host: host)["error"])
            }
        }
    }

    func testPaneSubdirectoriesDeduplicatedAndProtectedRowsLocked() throws {
        let f = ReviewFixture()
        f.directories = ["/a/one/subdir", "/a/one/another", "/a", "/a/subdir", "/unknown"]
        let h = handler(f)
        let p = try request(h)
        let rows = try XCTUnwrap(p["worktrees"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        let primary = try XCTUnwrap(rows.first { $0["path"] as? String == "/a" })
        XCTAssertEqual(primary["branch"] as? String, "main")
        XCTAssertEqual(primary["is_primary"] as? Bool, true)
        XCTAssertEqual(primary["error"] as? String, "Cannot delete branch `main`.")
        XCTAssertNotNil(rows.first { $0["path"] as? String == "/unknown" }?["error"])
        let token = try XCTUnwrap(p["delete_token"] as? String)
        XCTAssertNotNil(try request(h, token: token, paths: ["/a"])["error"])
        let result = try request(h, token: token, paths: ["/a/one"])
        XCTAssertNil(result["error"])
        XCTAssertEqual(f.removed, ["/a/one"])
        XCTAssertTrue(f.closed)
    }

    func testParentWorktreeCannotRemoveNestedCheckout() throws {
        for repo in ["/a/one/nested", "/b"] {
            let f = ReviewFixture()
            f.directories = ["/a/one", "/a/one/nested"]
            f.trees["/a/one/nested"] = repo
            let h = handler(f)
            let p = try request(h)
            let rows = try XCTUnwrap(p["worktrees"] as? [[String: Any]])
            let parent = try XCTUnwrap(rows.first { $0["path"] as? String == "/a/one" })
            XCTAssertEqual(parent["error"] as? String, "Cannot delete this worktree: it contains `/a/one/nested`.")
            let token = try XCTUnwrap(p["delete_token"] as? String)
            XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
            XCTAssertTrue(f.removed.isEmpty)
            XCTAssertFalse(f.closed)
        }
    }

    func testReviewPreservesTheActualSafetyScanError() throws {
        let f = ReviewFixture()
        f.directories = ["/a/one"]
        f.fingerprintFails = true
        let h = handler(f)
        let p = try request(h)
        let rows = try XCTUnwrap(p["worktrees"] as? [[String: Any]])
        let error = try XCTUnwrap(rows.first?["error"] as? String)
        XCTAssertTrue(error.contains("fingerprint failed: unreadable dependency"), error)
        XCTAssertFalse(error.contains("Worktree cannot be safely deleted"))
        let token = try XCTUnwrap(p["delete_token"] as? String)
        XCTAssertNotNil(try request(h, token: token, paths: ["/a/one"])["error"])
        XCTAssertTrue(f.removed.isEmpty)
        XCTAssertFalse(f.closed)
    }

    func testSelectionConsentAndTokenIdentity() throws {
        let f = ReviewFixture(), h = handler(ReviewFixture())
        let token = try preview(h)
        for paths: Any in [[], ["/a/one", "/a/one"], ["/a/other"], ["/unknown"], [1], "bad"] {
            XCTAssertNotNil(try request(h, token: token, paths: paths)["error"])
        }
        XCTAssertNotNil(try request(h, token: token, consent: false)["error"])
        XCTAssertFalse(h.worktreeReviewTickets.isEmpty)
        XCTAssertNotNil(try request(h, token: token, host: "elsewhere")["error"])
        XCTAssertNotNil(try request(h, token: token, sid: "session:other")["error"])
        let subject = handler(f)
        XCTAssertNotNil(try request(subject, token: token)["error"])
        let localToken = try preview(subject)
        subject.ctx.session = "session:target"
        XCTAssertNotNil(try request(subject, token: localToken)["error"])
        XCTAssertTrue(f.removed.isEmpty)
    }

    func testForceOfferIsNonmutatingAndBoundToExactSelection() throws {
        for unmerged in [false, true] {
            let f = ReviewFixture()
            if unmerged { f.unmerged = ["/a"] } else { f.dirty = ["/a/one"] }
            let h = handler(f), paths = ["/a/one"]
            let token = try preview(h)
            XCTAssertNotNil(try request(h, token: token, paths: paths, force: true)["error"])
            let offer = try request(h, token: token, paths: paths)
            XCTAssertEqual(offer["force_available"] as? Bool, true)
            XCTAssertTrue(f.removed.isEmpty)
            XCTAssertFalse(f.closed)
            XCTAssertNotNil(try request(h, token: token, force: true)["error"])
            XCTAssertNotNil(try request(h, token: token, paths: ["/b/two"], force: true)["error"])
            let result = try request(h, token: token, paths: paths, force: true)
            XCTAssertNil(result["error"])
            XCTAssertEqual(f.removed, paths)
            let removal = try XCTUnwrap(f.commands.first { $0.1 == "wt" && $0.2.first == "remove" })
            XCTAssertTrue(removal.2.contains("--force"))
            XCTAssertTrue(removal.2.contains("--force-delete"))
        }
    }

    func testStaleSnapshotInvalidatesTokenBeforeAnyMutation() throws {
        for change in 0..<4 {
            let f = ReviewFixture(), h = handler(f)
            let token = try preview(h)
            switch change {
            case 0: f.head = "changed"
            case 1: f.blocks.append("block:new")
            case 2: f.directories.append("/a/other")
            default: f.hostID = "changed"
            }
            let result = try request(h, token: token)
            XCTAssertNotNil(result["error"])
            XCTAssertEqual(result["force_available"] as? Bool, false)
            XCTAssertTrue(f.removed.isEmpty)
            XCTAssertFalse(f.closed)
            XCTAssertNil(h.worktreeReviewTickets[token])
        }
    }

    func testPartialFailureReportsExactPathsKeepsSessionAndConsumesToken() throws {
        for failure in 0..<5 {
            let f = ReviewFixture(), h = handler(f)
            switch failure {
            case 0: f.failedPath = "/b/two"
            case 1: f.retainedBranch = "/a/one"
            case 2: f.afterRemove = { f.directories = ["/b/two"] }
            case 3: f.afterRemove = { f.head = "changed" }
            default: f.branchVerificationFails = true
            }
            let token = try preview(h)
            let result = try request(h, token: token)
            XCTAssertNotNil(result["error"])
            XCTAssertEqual(result["deleted_paths"] as? [String], ["/a/one"])
            XCTAssertEqual(result["session_closed"] as? Bool, false)
            XCTAssertEqual(result["force_available"] as? Bool, false)
            XCTAssertFalse(f.closed)
            XCTAssertEqual(f.removed, ["/a/one"])
            XCTAssertEqual(h.deletionTombstones.map { $0.path }, ["/a/one"])
            XCTAssertTrue(h.deletionTombstones.allSatisfy { $0.sessionID.isEmpty })
            XCTAssertNotNil(try request(h, token: token, force: true)["error"])
            XCTAssertEqual(f.removed, ["/a/one"])
        }
    }

    func testExpiredPreviewAndChangedForceSnapshotCannotMutate() throws {
        let f = ReviewFixture(), h = handler(f)
        let expired = try preview(h)
        h.worktreeReviewTickets[expired]?.expires = Date().addingTimeInterval(-1)
        XCTAssertNotNil(try request(h, token: expired)["error"])
        f.dirty = ["/a/one"]
        let token = try preview(h)
        XCTAssertEqual(try request(h, token: token)["force_available"] as? Bool, true)
        f.head = "changed-after-offer"
        XCTAssertNotNil(try request(h, token: token, force: true)["error"])
        XCTAssertNil(h.worktreeReviewTickets[token])
        XCTAssertTrue(f.removed.isEmpty)
        XCTAssertFalse(f.closed)
    }

    func testCloseRevalidatesHostAndOriginAfterLastRemoval() throws {
        for origin in [true, false] {
            let f = ReviewFixture(), h = handler(f)
            let token = try preview(h)
            f.afterRemove = {
                if origin { h.ctx.session = "session:target" }
                else { f.hostID = "different-host" }
            }
            let result = try request(h, token: token, paths: ["/a/one"])
            XCTAssertNotNil(result["error"])
            XCTAssertEqual(result["deleted_paths"] as? [String], ["/a/one"])
            XCTAssertEqual(result["session_closed"] as? Bool, false)
            XCTAssertFalse(f.closed)
        }
    }

    func testCloseFailureAndCloseTombstones() throws {
        for fails in [false, true] {
            let f = ReviewFixture(), h = handler(f)
            f.closeFails = fails
            let result = try request(h, token: preview(h), paths: ["/a/one"])
            XCTAssertEqual(result["deleted_paths"] as? [String], ["/a/one"])
            XCTAssertEqual(result["session_closed"] as? Bool, !fails)
            XCTAssertEqual(h.deletionTombstones.contains { $0.sessionID == "session:target" }, !fails)
            XCTAssertEqual(f.removed, ["/a/one"])
        }
    }
}
