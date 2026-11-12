import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorExecx
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

private final class DeleteFixture {
    var head = "abc"
    var dirty = false
    var unmerged = false
    var primary = false
    var transportError = false
    var retainedBranch = false
    var removalFails = false
    var detached = false
    var closeFails = false
    var removed = false
    var closed = false
    var roots = ["/fixture/tree"]
    var calls: [(String, String, [String])] = []

    func command(_ dir: String, _ name: String, _ args: [String]) throws -> ExecResult {
        calls.append((dir, name, args))
        if transportError { throw MessageError("transport unavailable") }
        if name == "test" { return ExecResult(code: removed ? 1 : 0) }
        if name == "find" { return ExecResult() }
        if name == "/bin/bash" { return ExecResult(stdout: "fixture-file-digest") }
        if name == "wt" {
            if args.first == "remove" {
                if removalFails { return ExecResult(stderr: "arbitrary Worktrunk failure", code: 1) }
                removed = true
                return ExecResult(stdout: "{\"path\":\"/fixture/tree\",\"branch\":\"feat/task\",\"branch_outcome\":\"\(retainedBranch ? "retained_raced" : "deleted")\"}")
            }
            return ExecResult(stdout: "{\"repo\":{\"default_branch\":\"main\"}}")
        }
        if args == ["rev-parse", "--show-toplevel"] { return ExecResult(stdout: primary ? "/fixture/repo\n" : dir + "\n") }
        if args.contains("--git-common-dir") { return ExecResult(stdout: "/fixture/repo/.git\n") }
        if args.first == "worktree" {
            return ExecResult(stdout: "worktree /fixture/repo\0HEAD base\0branch refs/heads/main\0\0"
                + (removed ? "" : "worktree /fixture/tree\0HEAD \(head)\0branch refs/heads/feat/task\0\0"))
        }
        if args.first == "symbolic-ref" { return detached ? ExecResult(code: 1) : ExecResult(stdout: "refs/heads/feat/task\n") }
        if args.first == "rev-parse" { return ExecResult(stdout: args.last == "refs/heads/main" ? "base\n" : head + "\n") }
        if args.first == "merge-base" { return ExecResult(code: unmerged ? 1 : 0) }
        if args.first == "status" { return ExecResult(stdout: dirty ? "?? dirty\0" : "") }
        if args.first == "diff" || args.first == "ls-files" { return ExecResult() }
        if args.first == "show-ref" { return ExecResult(code: removed && !retainedBranch ? 1 : 0) }
        XCTFail("unexpected command: \(name) \(args)")
        return ExecResult(code: 2)
    }
}

final class SessionDeletionTests: APITestCase {
    private func handler(_ fixture: DeleteFixture, host: String = "") -> Handler {
        env.set("XDG_CACHE_HOME", FileManager.default.currentDirectoryPath + "/aux/delete-api-" + UUID().uuidString)
        env.unset("REX_SESSION")
        let h = Handler(ctx: Ctx(session: "session:origin"), cfg: .default())
        h.loadDeletionSession = { selected, sid in
            XCTAssertEqual(selected, host)
            return DeletionSessionState(hostID: "host-id", sessionID: sid, directories: fixture.roots, blocks: ["block:fixture"])
        }
        h.runDeletionCommand = { selected, sid, identity in
            XCTAssertEqual(selected, host)
            XCTAssertEqual(sid, "session:target")
            XCTAssertEqual(identity, "host-id")
            return fixture.command
        }
        h.closeDeletedSession = { selected, sid in
            XCTAssertTrue(fixture.removed)
            XCTAssertEqual(selected, host)
            if fixture.closeFails { throw MessageError("close transport failed") }
            fixture.closed = true
        }
        return h
    }

    func request(_ h: Handler, _ method: String, token: String = "", force: Bool = false,
                 host: String = "", sid: String = "session:target") throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["kind": "session", "session_id": sid, "host": host,
                                                             "delete_token": token, "force": force])
        let (result, error) = h.call(CancelToken(), method, Array(data))
        if let error { throw error }
        return try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result).encode().utf8)) as! [String: Any]
    }

    func testLocalAndRemoteRoutingAndCacheTombstones() throws {
        for host in ["", "devbox"] {
            let f = DeleteFixture()
            // Each handler's injected runner is host-specific; no local fallback.
            let subject = handler(f, host: host)
            let preview = try request(subject, "sessions.delete.preview", host: host)
            let token = try XCTUnwrap(preview["delete_token"] as? String)
            XCTAssertEqual(preview["repo"] as? String, "/fixture/repo")
            XCTAssertEqual(preview["path"] as? String, "/fixture/tree")
            XCTAssertEqual(preview["branch"] as? String, "feat/task")
            let result = try request(subject, "sessions.delete", token: token, host: host)
            XCTAssertEqual(result["session_closed"] as? Bool, true)
            XCTAssertTrue(f.closed)
            XCTAssertFalse(f.calls.contains { $0.2.contains("push") || $0.2.contains("branch") })
            XCTAssertThrowsError(try request(subject, "sessions.delete", token: token, host: host))
            let stale = LauncherItem(kind: "session", id: "session:target", sessionID: "session:target", host: host, local: host.isEmpty)
            let folder = LauncherItem(kind: "directory", path: "/fixture/tree", host: host, local: host.isEmpty)
            subject.storeLauncher(subject.cacheGeneration(), [stale, folder], [])
            XCTAssertEqual(subject.readLauncherCache().0.items?.count, 0)
            let restarted = Handler(ctx: Ctx(), cfg: .default())
            XCTAssertEqual(restarted.filterDeleted(LauncherCacheEntry(items: [stale, folder])).items?.count, 0)
        }
    }

    func testDirtyAndUnmergedNeedSeparateForce() throws {
        for dirty in [true, false] {
            let f = DeleteFixture()
            f.dirty = dirty
            f.unmerged = !dirty
            let h = handler(f)
            let token = try XCTUnwrap(try request(h, "sessions.delete.preview")["delete_token"] as? String)
            XCTAssertNotNil(try request(h, "sessions.delete", token: token, force: true)["error"])
            XCTAssertFalse(f.removed)
            let normal = try request(h, "sessions.delete", token: token)
            XCTAssertEqual(normal["force_available"] as? Bool, true)
            XCTAssertFalse(f.closed)
            let forced = try request(h, "sessions.delete", token: token, force: true)
            XCTAssertNil(forced["error"])
            let remove = try XCTUnwrap(f.calls.first { $0.1 == "wt" && $0.2.first == "remove" })
            XCTAssertTrue(remove.2.contains("--force"))
            XCTAssertTrue(remove.2.contains("--force-delete"))
        }
    }

    func testStaleHeadAndTransportNeverOfferForce() throws {
        for transport in [false, true] {
            let f = DeleteFixture()
            let subject = handler(f)
            let token = try XCTUnwrap(try request(subject, "sessions.delete.preview")["delete_token"] as? String)
            if transport { f.transportError = true } else { f.head = "changed" }
            let result = try request(subject, "sessions.delete", token: token, force: true)
            XCTAssertEqual(result["force_available"] as? Bool, false)
            XCTAssertNotNil(result["error"])
            XCTAssertFalse(f.removed)
            XCTAssertFalse(f.closed)
        }
    }

    func testPrimaryOriginUnknownAndMultipleWorktreeRefusal() throws {
        let f = DeleteFixture(), h = handler(DeleteFixture())
        XCTAssertThrowsError(try request(h, "sessions.delete.preview", sid: "session:origin"))
        f.primary = true
        XCTAssertThrowsError(try request(handler(f), "sessions.delete.preview"))
        f.primary = false
        f.roots = []
        XCTAssertThrowsError(try request(handler(f), "sessions.delete.preview"))
        f.roots = ["/fixture/tree", "/fixture/other"]
        XCTAssertThrowsError(try request(handler(f), "sessions.delete.preview"))
        f.roots = ["/fixture/tree"]
        f.detached = true
        XCTAssertThrowsError(try request(handler(f), "sessions.delete.preview"))
        XCTAssertFalse(f.removed)
    }

    func testWrongHostOriginChangeAndRemovalFailureNeverForce() throws {
        let f = DeleteFixture()
        let subject = handler(f)
        let token = try XCTUnwrap(try request(subject, "sessions.delete.preview")["delete_token"] as? String)
        XCTAssertThrowsError(try request(subject, "sessions.delete", token: token, force: true, host: "different-host"))
        subject.ctx.session = "session:target"
        XCTAssertThrowsError(try request(subject, "sessions.delete", token: token, force: true))
        subject.ctx.session = "session:origin"
        f.removalFails = true
        let result = try request(subject, "sessions.delete", token: token)
        XCTAssertEqual(result["force_available"] as? Bool, false)
        XCTAssertEqual(result["worktree_removed"] as? Bool, false)
        XCTAssertFalse(f.closed)
        XCTAssertFalse(f.removed)
    }

    func testRemovalPartialAndCloseFailure() throws {
        for retain in [true, false] {
            let f = DeleteFixture()
            f.retainedBranch = retain
            f.closeFails = !retain
            let h = handler(f)
            let token = try XCTUnwrap(try request(h, "sessions.delete.preview")["delete_token"] as? String)
            let result = try request(h, "sessions.delete", token: token)
            XCTAssertEqual(result["worktree_removed"] as? Bool, true)
            XCTAssertEqual(result["branch_removed"] as? Bool, !retain)
            XCTAssertEqual(result["session_closed"] as? Bool, false)
            XCTAssertEqual(result["force_available"] as? Bool, false)
            XCTAssertNotNil(result["error"])
            XCTAssertFalse(f.closed)
        }
    }
}
