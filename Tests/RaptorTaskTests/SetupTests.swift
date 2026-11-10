import XCTest
import RaptorConfig
import RaptorExecx
import RaptorPullrequest
import RaptorWorktree
@testable import RaptorTask

/// Ported from setup_test.go: configured hooks must run visibly inside the
/// created tab, before Pi, with selection failures recoverable.
final class SetupTests: XCTestCase {
    func testTaskConfiguredSetupRunsBeforePi() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, log) = try fixture(env)
        env.set("XDG_STATE_HOME", try makeTempDir())
        let configPath = env.get("WORKTRUNK_PROJECT_CONFIG_PATH") ?? ""
        try "[pre-start]\ninstall = \"true\"\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        let (result, error) = startResult(ctx, cfg, repo, "")
        if let error { throw error }
        let (pending, pendingErr) = localPendingSafe(result.path)
        XCTAssertNil(pendingErr, "\(String(describing: pendingErr))")
        XCTAssertTrue(pending, "pending=\(pending)")
        let calls = try readText(log)
        XCTAssertTrue(calls.contains("--\n/bin/sh\n-c\n"), calls)
        XCTAssertTrue(calls.contains(" setup --path "), calls)
        XCTAssertTrue(calls.contains(" && { "), calls)
        XCTAssertTrue(calls.contains("exec \"${SHELL:-/bin/sh}\" -l"), calls)
        XCTAssertFalse(calls.contains("--yes"), "approval bypassed")
        XCTAssertEqual(WorktreeKit.list(repo: repo).count, 2, "wrong worktree count")
    }

    func testTaskConfiguredSelectionRetryReusesTab() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, log) = try fixture(env)
        env.set("XDG_STATE_HOME", try makeTempDir())
        try "[pre-start]\ninstall = \"true\"\n".write(toFile: env.get("WORKTRUNK_PROJECT_CONFIG_PATH") ?? "",
                                                      atomically: true, encoding: .utf8)
        guard let rexPath = Execx.lookup(name: "rex") else {
            XCTFail("fake rex not on PATH")
            return
        }
        let script = try readText(rexPath)
        let replacement = "case \"$1\" in\n session) echo '{\"windows\":[{\"window_id\":\"new-window\"}]}' ;;\n do) echo \"$LOCAL_TASK_PATH\" ;;"
        guard let range = script.range(of: "case \"$1\" in") else {
            XCTFail("fake rex lost its case dispatch")
            return
        }
        try script.replacingCharacters(in: range, with: replacement)
            .write(toFile: rexPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rexPath)
        env.set("TASK_FAIL", "focus")
        let (first, error) = startResult(ctx, cfg, repo, "")
        guard error != nil else {
            XCTFail("\(first)")
            return
        }
        XCTAssertEqual(first.windowID, "new-window", "\(first)")
        env.set("LOCAL_TASK_PATH", first.path)
        env.set("TASK_FAIL", "")
        let (second, secondErr) = startResult(ctx, cfg, repo, first.path)
        if let secondErr { throw secondErr }
        XCTAssertEqual(second.windowID, first.windowID, "\(second)")
        XCTAssertEqual(second.path, first.path, "\(second)")
        let calls = try readText(log)
        XCTAssertEqual(countOccurrences(calls, "window\nnew\n"), 1, "retry duplicated tab: \(calls)")
    }

    func testTaskPreSwitchStopsBeforeCreation() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, log) = try fixture(env)
        try "[pre-switch]\ncheck = \"true\"\n".write(toFile: env.get("WORKTRUNK_PROJECT_CONFIG_PATH") ?? "",
                                                     atomically: true, encoding: .utf8)
        let (_, error) = startResult(ctx, cfg, repo, "")
        guard let error else {
            XCTFail("pre-switch refusal ignored")
            return
        }
        XCTAssertTrue(String(describing: error).contains("pre-switch"), "\(error)")
        XCTAssertEqual(WorktreeKit.list(repo: repo).count, 1, "pre-switch refusal created a worktree")
        let calls = (try? readText(log)) ?? ""
        XCTAssertFalse(calls.contains("window\nnew"), "opened a tab before refusal")
    }
}

/// localPending's (bool, error) shape for tests.
func localPendingSafe(_ path: String) -> (pending: Bool, error: Error?) {
    do {
        return (try Pullrequest.localPending(path), nil)
    } catch {
        return (false, error)
    }
}
