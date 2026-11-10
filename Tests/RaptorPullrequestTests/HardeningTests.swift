import XCTest
import RaptorRex
@testable import RaptorPullrequest

/// Ported from internal/pullrequest/hardening_test.go.
final class HardeningTests: XCTestCase {
    func testRegistrationIdentityAndReady() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        XCTAssertFalse(Pullrequest.ready(path: path), "ready before Prepare")
        _ = try git(repo, ["worktree", "add", "-b", "feat/fix", path])
        XCTAssertFalse(Pullrequest.ready(path: path), "registration without journal is ready")
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        XCTAssertTrue(Pullrequest.ready(path: path), "prepared destination is not ready")
        var s = try RaptorPullrequest.load(path)
        let old = s.instance
        s.complete = true
        s.stage = 3
        s.released = true
        s.opening = true
        s.result = OpenResult(path: path, sessionID: "stale", windowID: "stale", blockID: "stale")
        try RaptorPullrequest.save(path, s)
        _ = try git(repo, ["worktree", "remove", path])
        XCTAssertFalse(Pullrequest.ready(path: path), "removed worktree ready")
        _ = try git(repo, ["worktree", "add", path, "feat/fix"])
        XCTAssertFalse(Pullrequest.ready(path: path), "new registration reused old journal")
        let (result, err) = openResult(path, "session", Ctx(client: "client"))
        XCTAssertNotNil(err)
        XCTAssertEqual(result.sessionID ?? "", "", "stale open: \(result) \(String(describing: err))")
        XCTAssertThrowsError(try Pullrequest.setup(path: path, retry: true), "stale setup succeeded")
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        s = try RaptorPullrequest.load(path)
        XCTAssertNotEqual(s.instance, old)
        XCTAssertFalse(s.complete)
        XCTAssertEqual(s.stage, 0)
        XCTAssertFalse(s.opening)
        XCTAssertFalse(s.released)
        XCTAssertEqual(s.result.sessionID ?? "", "", "stale state: \(s)")
        XCTAssertTrue(Pullrequest.ready(path: path), "new journal not ready")
    }

    func testUnboundJournalCrashRecovery() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        var s = try RaptorPullrequest.load(path)
        s.instance = nil // crash after switch, before binding registration
        try RaptorPullrequest.save(path, s)
        XCTAssertFalse(Pullrequest.ready(path: path), "unbound journal ready")
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        s = try RaptorPullrequest.load(path)
        XCTAssertTrue(s.new)
        XCTAssertNotEqual(s.instance ?? "", "")
        XCTAssertTrue(Pullrequest.ready(path: path), "lost recovery: \(s)")
    }

    func testDefiniteCreateFailureRetriesAfterZeroScan() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        let bin = firstPathDir(env)
        let rexPath = bin + "/rex"
        let original = try String(contentsOfFile: rexPath, encoding: .utf8)
        try put(rexPath, #"""
#!/bin/sh
printf 'rex %s\n' "$*" >> "$PR_LOG"
case "$1" in
 new) exit 7;;
 ls) echo '{"sessions":[]}';;
 *) exit 8;;
esac
"""#)
        XCTAssertThrowsError(try Pullrequest.open(path: path, target: "session", ctx: Ctx(client: "client")),
                             "create succeeded")
        var s = try RaptorPullrequest.load(path)
        XCTAssertTrue(s.retryCreate ?? false, "definite failure not recorded")
        // Zero scan is authoritative, then the normal create succeeds.
        try put(rexPath, original.replacingOccurrences(
            of: #"ls) echo '{"sessions":[{"session_id":"s1"}]}';;"#,
            with: #"ls) echo '{"sessions":[]}';;"#))
        let (_, err) = openResult(path, "session", Ctx(client: "client"))
        XCTAssertNil(err, "\(String(describing: err))")
        let calls = try readLog(env)
        XCTAssertEqual(calls.components(separatedBy: "rex new ").count - 1, 2, calls)
    }

    func testUncertainCreateResponsesStayBlockedAfterZeroScan() {
        for response in [
            #"printf '{"session_id":'; exit 7"#,
            #"echo '{}'; exit 0"#,
            #"echo 'connection closed before response' >&2; exit 7"#,
            #"echo '{"session_id":"partial"}'; exit 7"#,
        ] {
            subtest(response) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, path) = try fixture(env)
                XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
                let bin = firstPathDir(env)
                let script = "#!/bin/sh\nprintf 'rex %s\\n' \"$*\" >> \"$PR_LOG\"\ncase \"$1\" in\nnew) "
                    + response
                    + ";;\nls) echo '{\"sessions\":[]}';;\n*) exit 8;;\nesac\n"
                try put(bin + "/rex", script)
                XCTAssertThrowsError(try Pullrequest.open(path: path, target: "session", ctx: Ctx(client: "client")),
                                     "create succeeded")
                let s = try RaptorPullrequest.load(path)
                XCTAssertFalse(s.retryCreate ?? false, "uncertain response permits retry")
                XCTAssertThrowsError(try Pullrequest.open(path: path, target: "session", ctx: Ctx(client: "client")),
                                     "uncertain response retried")
                let calls = try readLog(env)
                XCTAssertEqual(calls.components(separatedBy: "rex new ").count - 1, 1, calls)
            }
        }
    }

    func testReconciliationRetainsIDsOnIncompleteScan() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        var s = try RaptorPullrequest.load(path)
        s.opening = true
        s.retryCreate = true
        s.result = OpenResult(path: path, sessionID: "preserve")
        try RaptorPullrequest.save(path, s)
        let bin = firstPathDir(env)
        try put(bin + "/rex", "#!/bin/sh\necho '{}'\n")
        let (result, err) = openResult(path, "session", Ctx(client: "client"))
        XCTAssertNotNil(err)
        XCTAssertEqual(result.sessionID ?? "", "preserve", "lost IDs: \(result) \(String(describing: err))")
    }

    func testAmbiguousZeroScanDoesNotRetry() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        var s = try RaptorPullrequest.load(path)
        s.opening = true // a crash or lost response, not a definite failure
        try RaptorPullrequest.save(path, s)
        let bin = firstPathDir(env)
        try put(bin + "/rex", "#!/bin/sh\n[ \"$1\" = ls ] || exit 9\necho '{\"sessions\":[]}'\n")
        XCTAssertThrowsError(try Pullrequest.open(path: path, target: "session", ctx: Ctx(client: "client")),
                             "ambiguous creation retried")
    }

    func testOwnedEmptyCloneRetry() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (source, _) = try fixture(env)
        env.set("PR_CLONE_SOURCE", source)
        let bin = firstPathDir(env)
        let ghPath = bin + "/gh"
        let original = try String(contentsOfFile: ghPath, encoding: .utf8)
        try put(ghPath, original.replacingOccurrences(
            of: "'repo clone')",
            with: "'repo clone') mkdir \"$4/.git\"; rmdir \"$4/.git\"; exit 7;"))
        XCTAssertThrowsError(try Pullrequest.prepare(repo: "", input: "https://github.com/acme/project/pull/42"),
                             "clone succeeded")
        try put(ghPath, original)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: "", input: "https://github.com/acme/project/pull/42"))
    }

    func testCloneCompletedBeforeErrorResumesWithoutClone() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (source, _) = try fixture(env)
        env.set("PR_CLONE_SOURCE", source)
        let bin = firstPathDir(env)
        let ghPath = bin + "/gh"
        let original = try String(contentsOfFile: ghPath, encoding: .utf8)
        try put(ghPath, original.replacingOccurrences(
            of: "remote set-url origin https://github.com/acme/project.git;;",
            with: "remote set-url origin https://github.com/acme/project.git; exit 7;;"))
        XCTAssertThrowsError(try Pullrequest.prepare(repo: "", input: "https://github.com/acme/project/pull/42"),
                             "clone succeeded")
        try put(ghPath, original)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: "", input: "https://github.com/acme/project/pull/42"))
        let calls = try readLog(env)
        XCTAssertEqual(calls.components(separatedBy: "gh repo clone ").count - 1, 1, calls)
    }

    func testCloneOwnershipProtectsDataAndReplacement() {
        for mode in ["data", "replacement", "unowned"] {
            subtest(mode) {
                let env = TestEnv()
                defer { env.restore() }
                _ = try fixture(env)
                let path = (env.get("HOME") ?? "") + "/clone"
                if mode == "unowned" {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                } else {
                    try RaptorPullrequest.claimClone(path)
                }
                if mode == "replacement" {
                    try FileManager.default.moveItem(atPath: path, toPath: path + "-old")
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                }
                if mode == "data" {
                    try put(path + "/keep", "user data")
                }
                XCTAssertThrowsError(try RaptorPullrequest.claimClone(path), "accepted unverified clone destination")
                if mode == "data" {
                    let data = try String(contentsOfFile: path + "/keep", encoding: .utf8)
                    XCTAssertEqual(data, "user data", "data changed")
                }
            }
        }
    }

    func testEffectiveProjectConfig() {
        for mode in ["source drift", "destination drift", "equal"] {
            subtest(mode) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, path) = try fixture(env)
                env.set("WT_PROJECT_CONFIG_PATH", "hooks.toml")
                try put(repo + "/hooks.toml", "# approved config\n")
                XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
                try put(path + "/hooks.toml", "# approved config\n")
                if mode == "source drift" {
                    try put(repo + "/hooks.toml", "# changed source\n")
                }
                if mode == "destination drift" {
                    try put(path + "/hooks.toml", "# changed destination\n")
                }
                let (_, openErr) = openResult(path, "session", Ctx(client: "client"))
                XCTAssertNil(openErr, "\(String(describing: openErr))")
                var setupErr: Error?
                do {
                    try Pullrequest.setup(path: path, retry: false)
                } catch {
                    setupErr = error
                }
                XCTAssertEqual((setupErr == nil), (mode == "equal"), "\(mode): \(String(describing: setupErr))")
            }
        }
    }

    func testConfigStampIncludesUserFileContent() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, _) = try fixture(env)
        let path = (env.get("HOME") ?? "") + "/user.toml"
        try put(path, "# original\n")
        let before = try RaptorPullrequest.configStamp(repo)
        try put(path, "# changed comment\n")
        let after = try RaptorPullrequest.configStamp(repo)
        XCTAssertNotEqual(before, after, "user config content not tracked: \(String(describing: after))")
    }

    func testCommandTimeoutKillsDescendants() throws {
        let env = TestEnv()
        defer { env.restore() }
        _ = try fixture(env)
        let root = dirOf(env.get("PR_LOG") ?? "")
        let marker = root + "/late-mutation"
        let start = Date()
        XCTAssertThrowsError(
            try commandContext(timeout: 0.15, dir: "", name: "/bin/sh",
                               args: ["-c", "(sleep 1; printf bad > " + quote(marker) + ") & wait"]),
            "timeout succeeded")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "unbounded pipe drain")
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "descendant survived cancellation")
    }

    func testCommandBoundsDrainAfterParentExit() throws {
        let env = TestEnv()
        defer { env.restore() }
        _ = try fixture(env)
        let marker = dirOf(env.get("PR_LOG") ?? "") + "/orphan-mutation"
        let start = Date()
        XCTAssertThrowsError(
            try commandContext(timeout: 5, dir: "", name: "/bin/sh",
                               args: ["-c", "(sleep 2; printf bad > " + quote(marker) + ") & exit 0"]),
            "pipe drain succeeded")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "pipe drain")
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "orphan survived bounded drain")
    }

    func testSetupWrapperSurvivesInterrupt() throws {
        let env = TestEnv()
        defer { env.restore() }
        _ = try fixture(env)
        let root = dirOf(env.get("PR_LOG") ?? "")
        let started = root + "/started"
        let runner = root + "/fake-raptor"
        let login = root + "/login-shell"
        try put(runner, "#!/bin/sh\nprintf ready > " + quote(started) + "\nsleep 30\n")
        try put(login, "#!/bin/sh\nprintf 'usable shell'\n")
        env.set("SHELL", login)
        let (pid, readFd) = try Procs.spawnGroupedCapture(argv: ["/bin/sh", "-c", setupWrapper(runner, "path with 'quotes")])
        defer { Procs.killGroup(pid, SIGKILL) }
        let box = LockedBox<Data>(Data())
        let sem = DispatchSemaphore(value: 0)
        Procs.drain(fd: readFd, box: box, sem: sem)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: started) {
            if Date() > deadline {
                XCTFail("runner did not start")
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(kill(-pid, SIGINT), 0)
        let (status, done) = Procs.waitExit(pid, timeout: 5)
        Procs.killGroup(pid, SIGKILL)
        _ = sem.wait(timeout: .now() + 2.0)
        XCTAssertTrue(done, "wrapper did not return to shell")
        if done {
            XCTAssertFalse(wSignaled(status), "wrapper signaled: \(status)")
            XCTAssertEqual(wExitCode(status), 0, "wrapper exit")
        }
        let output = String(data: box.current, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("usable shell"), "wrapper: \(output)")
    }

    func testExplicitGitHubHost() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, _) = try fixture(env)
        env.set("GH_HOST", "example.invalid")
        XCTAssertNotNil(try? Pullrequest.resolve(repo: repo, input: "42"))
        let calls = try readLog(env)
        XCTAssertTrue(calls.contains("gh api --hostname github.com repos/acme/project/pulls/42"), calls)
    }
}
