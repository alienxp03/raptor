import XCTest
import RaptorExecx
import RaptorRex
@testable import RaptorPullrequest

/// Ported from internal/pullrequest/local_test.go.
final class LocalTests: XCTestCase {
    func testLocalPreflightAndRegistration() {
        for phase in ["", "pre-start", "post-start", "post-switch"] {
            subtest(phase.isEmpty ? "(none)" : phase) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, path) = try localFixture(env)
                env.set("LOCAL_PHASE", phase)
                let plan = try Pullrequest.preflightLocal(source: repo)
                XCTAssertEqual(plan.hooks, phase != "", "hooks")
                _ = try git(repo, ["worktree", "add", "-b", "local", path])
                try plan.register(path: path, branch: "local", base: "main")
                let pending = try Pullrequest.localPending(path)
                XCTAssertEqual(pending, plan.hooks, "pending")
                let s = try RaptorPullrequest.load(path)
                if phase.isEmpty {
                    XCTAssertTrue(s.path.isEmpty, "no-hook creation wrote setup state")
                    return
                }
                XCTAssertTrue(s.new)
                XCTAssertEqual(s.source, repo)
                XCTAssertEqual(s.base, "main")
                XCTAssertEqual(s.url, "")
                XCTAssertFalse(s.released)
                XCTAssertTrue(validState(path, s), "\(s)")
                var mutated = s
                mutated.stage = 1
                try RaptorPullrequest.save(path, mutated)
                try plan.register(path: path, branch: "local", base: "main")
                let again = try RaptorPullrequest.load(path)
                XCTAssertEqual(again.stage, 1, "registration reset setup")
            }
        }
    }

    func testLocalStateSupportsSessionAndTabOpen() {
        for target in ["session", "tab"] {
            subtest(target) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, path) = try localFixture(env)
                env.set("LOCAL_PHASE", "pre-start")
                let plan = try Pullrequest.preflightLocal(source: repo)
                _ = try git(repo, ["worktree", "add", "-b", "local", path])
                try plan.register(path: path, branch: "local", base: "main")
                let (result, err) = openResult(path, target, Ctx(session: "s1", client: "client"))
                XCTAssertNil(err, "\(result): \(String(describing: err))")
                XCTAssertEqual(result.blockID ?? "", "b1")
                let s = try RaptorPullrequest.load(path)
                XCTAssertTrue(s.released, "successful selection did not release setup")
            }
        }
    }

    func testLocalPreSwitchRefusesBeforeMutation() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try localFixture(env)
        env.set("PR_PRE_SWITCH", "1")
        XCTAssertThrowsError(try Pullrequest.preflightLocal(source: repo)) { error in
            XCTAssertTrue(String(describing: error).contains("pre-switch"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "preflight created worktree")
    }

    func testLocalStartupFailureKeepsShellAndSkipsPi() {
        for status in ["0", "7"] {
            subtest(status) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, path) = try localFixture(env)
                env.set("LOCAL_PHASE", "pre-start")
                let plan = try Pullrequest.preflightLocal(source: repo)
                _ = try git(repo, ["worktree", "add", "-b", "local", path])
                try plan.register(path: path, branch: "local", base: "main")
                let log = (try makeTempDir()) + "/startup"
                env.set("LOCAL_START_LOG", log)
                let bin = try makeTempDir()
                let runner = bin + "/raptor"
                let pi = bin + "/pi"
                let shell = bin + "/shell"
                try put(runner, "#!/bin/sh\necho setup >> \"$LOCAL_START_LOG\"\nexit " + status + "\n")
                try put(pi, "#!/bin/sh\necho pi >> \"$LOCAL_START_LOG\"\n")
                try put(shell, "#!/bin/sh\necho shell >> \"$LOCAL_START_LOG\"\n")
                env.set("SHELL", shell)
                let args = try Pullrequest.localStartup(path: path, target: "task", after: pi)
                let s = try RaptorPullrequest.load(path)
                XCTAssertFalse(s.released, "runner released before selection")
                XCTAssertThrowsError(try Pullrequest.localStartup(path: path, target: "task", after: pi),
                                     "duplicate runner accepted")
                let exe = executablePath()
                var argv = args
                argv[2] = argv[2].replacingOccurrences(of: quote(exe), with: quote(runner))
                let r = try Execx.run(dir: "", timeout: 30, name: argv[0], args: Array(argv[1...]))
                XCTAssertEqual(r.code, 0, "runner: \(r.stderr)")
                let data = try String(contentsOfFile: log, encoding: .utf8)
                let want = status == "0" ? "setup\npi\n" : "setup\nshell\n"
                XCTAssertEqual(data, want, "got \(data), want \(want)")
            }
        }
    }
}
