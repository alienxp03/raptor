import XCTest
import RaptorPullrequest
import RaptorConfig
import RaptorRex
import RaptorWorktree
@testable import RaptorDispatch

/// Ported from setup_test.go: dispatch against a registered worktree whose
/// pre-start hooks must run visibly before any tab exists.
final class SetupTests: XCTestCase {
    func setupFixture(_ env: TestEnv) throws -> (path: String, log: String, ctx: Ctx) {
        let root = try makeTempDir()
        let repo = root + "/repo"
        let path = root + "/tree"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                       "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"])
        let cfg = root + "/wt.toml"
        try "[pre-start]\ninstall = \"true\"\n".write(toFile: cfg, atomically: true, encoding: .utf8)
        try "".write(toFile: root + "/empty.toml", atomically: true, encoding: .utf8)
        env.set("WORKTRUNK_CONFIG_PATH", root + "/empty.toml")
        env.set("WORKTRUNK_SYSTEM_CONFIG_PATH", root + "/empty.toml")
        env.set("WORKTRUNK_PROJECT_CONFIG_PATH", cfg)
        env.set("XDG_STATE_HOME", root + "/state")
        env.set("XDG_CACHE_HOME", root + "/cache")
        let plan = try Pullrequest.preflightLocal(source: repo)
        try git(repo, ["worktree", "add", "-b", "local", path])
        try plan.register(path: path, branch: "local", base: "main")
        let log = root + "/calls"
        env.set("LOCAL_REX_LOG", log)
        env.set("LOCAL_CWD", path)
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "$LOCAL_REX_LOG"
        case "$1" in
         split) echo '{"block_ids":["new-pane"]}';;
         focus) :;;
         api) echo '{"block":{"window_id":"new-window"}}';;
         session) echo '{"windows":[{"window_id":"new-window"}]}';;
         do) echo "$LOCAL_CWD";;
         -C) [ -z "$LOCAL_SELECT_FAIL" ];;
         *) exit 8;;
        esac
        """#
        let bin = root + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try writeExecutable(bin + "/rex", script)
        env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
        return (path, log, Ctx(session: "origin", block: "active-agent", client: "client"))
    }

    func testConfiguredHereNeverInjects() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (path, log, ctx) = try setupFixture(env)
        XCTAssertThrowsError(try RaptorDispatch.dispatch(target: "here", dir: path, ctx: ctx,
                                                         cfg: RaptorConfig.default())) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Session or Tab"), "\(error)")
            XCTAssertTrue(message.contains("preserved"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log), "Here called Rex")
    }

    func testConfiguredPaneStartupAndSelectionGate() throws {
        for failure in ["", "selection"] {
            subtest(failure) {
                let env = TestEnv()
                defer { env.restore() }
                let (path, log, ctx) = try setupFixture(env)
                env.set("LOCAL_SELECT_FAIL", failure)
                var caught: Error?
                do {
                    _ = try RaptorDispatch.dispatch(target: "pane_right", dir: path, ctx: ctx,
                                                    cfg: RaptorConfig.default())
                } catch {
                    caught = error
                }
                XCTAssertEqual(caught != nil, !failure.isEmpty, String(describing: caught))
                let calls = try readText(log)
                XCTAssertTrue(calls.contains("--json -- /bin/sh -c"), calls)
                XCTAssertTrue(calls.contains(" setup --path "), calls)
                XCTAssertFalse(calls.contains("send "), calls)
                let stateDir = (env.get("XDG_STATE_HOME") ?? "") + "/raptor/pullrequest"
                let files = try FileManager.default.contentsOfDirectory(atPath: stateDir).filter { $0.hasSuffix(".json") }
                XCTAssertEqual(files.count, 1, "\(files)")
                let data = try readText(stateDir + "/" + files[0])
                let obj = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
                let released = (obj?["released"] as? Bool) ?? false
                XCTAssertEqual(released, failure.isEmpty, "released=\(released)")
                env.set("LOCAL_SELECT_FAIL", "")
                _ = try RaptorDispatch.dispatch(target: "pane_right", dir: path, ctx: ctx,
                                                cfg: RaptorConfig.default())
                let retryCalls = try readText(log)
                XCTAssertEqual(countOccurrences(retryCalls, "split -s"), 1, "retry duplicated pane: \(retryCalls)")
            }
        }
    }
}
