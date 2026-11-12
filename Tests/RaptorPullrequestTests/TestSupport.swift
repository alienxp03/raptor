import XCTest
import RaptorExecx
import RaptorRex
import RaptorWorktree
@testable import RaptorPullrequest

/// setenv/unsetenv with recorded originals; mirrors Go's t.Setenv restore.
final class TestEnv {
    private var saved: [String: String?] = [:]

    private func record(_ name: String) {
        if saved[name] == nil {
            if let value = getenv(name) {
                saved[name] = .some(String(cString: value))
            } else {
                // .some(nil), not .none: assigning .none to a [String: String?]
                // subscript removes the key and the original absence is never restored.
                saved[name] = .some(nil)
            }
        }
    }

    func set(_ name: String, _ value: String) {
        record(name)
        setenv(name, value, 1)
    }

    func unset(_ name: String) {
        record(name)
        unsetenv(name)
    }

    func get(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }

    func restore() {
        for (name, value) in saved {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
        saved = [:]
    }
}

func makeTempDir() throws -> String {
    var base = NSTemporaryDirectory()
    while base.hasSuffix("/") { base.removeLast() }
    let dir = base + "/raptor-pr-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// t.Run-style labeled failure reporting for table-driven cases.
func subtest(_ label: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        XCTFail("\(label): \(error)")
    }
}

func put(_ path: String, _ text: String) throws {
    try FileManager.default.createDirectory(atPath: dirOf(path), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                   attributes: [.posixPermissions: 0o700])
}

func git(_ dir: String, _ args: [String]) throws -> String {
    let r = try Execx.run(dir: dir, timeout: 120, name: "git", args: args)
    if r.code != 0 {
        throw MessageError("git \(args.joined(separator: " ")): \(r.stdout)\(r.stderr)")
    }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - (result, error) helpers mirroring Go's two-value returns

func prepareInfo(_ repo: String, _ input: String) -> (info: Info, error: Error?) {
    do {
        return (try Pullrequest.prepare(repo: repo, input: input), nil)
    } catch let e as PrepareError {
        return (e.info, e)
    } catch {
        return (Info(), error)
    }
}

func prepareInfoWithCommit(_ repo: String, _ input: String, _ checkoutCommit: Bool) -> (info: Info, error: Error?) {
    do {
        return (try Pullrequest.prepareWithOptions(repo: repo, input: input, checkoutCommit: checkoutCommit), nil)
    } catch let e as PrepareError {
        return (e.info, e)
    } catch {
        return (Info(), error)
    }
}

func resolveInfo(_ repo: String, _ input: String) -> (info: Info, error: Error?) {
    do {
        return (try Pullrequest.resolve(repo: repo, input: input), nil)
    } catch let e as ResolveError {
        return (e.info, e)
    } catch {
        return (Info(), error)
    }
}

func openResult(_ path: String, _ target: String, _ ctx: Ctx) -> (result: OpenResult, error: Error?) {
    do {
        return (try Pullrequest.open(path: path, target: target, ctx: ctx), nil)
    } catch let e as OpenError {
        return (e.result, e)
    } catch {
        return (OpenResult(), error)
    }
}

// MARK: - fixtures

let ghFixtureScript = #"""
#!/bin/sh
printf 'gh %s\n' "$*" >> "$PR_LOG"
case "$1 $2" in
 'api --hostname') [ "$3" = github.com ] && [ "$4" = repos/acme/project/pulls/42 ] || exit 8; echo '{"base":{"repo":{"full_name":"acme/project"}}}';;
 'pr view') echo '{"number":42,"title":"Fix it","headRefName":"feat/fix","url":"https://github.com/acme/project/pull/42"}';;
 'repo clone') git clone --quiet "$PR_CLONE_SOURCE" "$4" && git -C "$4" remote set-url origin https://github.com/acme/project.git;;
 *) exit 8;;
esac
"""#

let wtFixtureScript = #"""
#!/bin/sh
printf 'wt %s\n' "$*" >> "$PR_LOG"
case "$1 $2" in
 'config show')
  project="${WT_PROJECT_CONFIG_PATH:-$PWD/.config/wt.toml}"
  case "$project" in /*) :;; *) project="$PWD/$project";; esac
  printf '{"user":{"path":"%s/user.toml","exists":false},"system":{"path":"%s/system.toml","exists":false},"project":{"path":"%s","exists":false}}\n' "$HOME" "$HOME" "$project";;
 'step eval') printf '{"result":"%s"}\n' "$PR_DEST";;
 'hook show')
  if [ "$3" = pre-switch ]; then
   if [ -n "$PR_PRE_SWITCH" ]; then echo '[{"name":"check"}]'; else echo '[]'; fi
  elif [ -n "$PR_HOOK_JSON" ]; then printf '%s\n' "$PR_HOOK_JSON"
  else
   case " $PR_HOOK_PHASES $LOCAL_PHASE " in
    *" $3 "*) echo '[{"name":"check","template":"echo {{ branch }}"}]';;
    *) echo '[]';;
   esac
  fi;;
 'config approvals') if [ -n "$PR_DENY" ]; then echo '{"commands":[{"phase":"pre-start","approved":false}]}'; else echo '{"commands":[]}'; fi;;
 'hook pre-start'|'hook post-start'|'hook post-switch')
  if [ -n "$PR_VISIBLE" ]; then printf '%s stdout\n' "$2"; printf '%s stderr\n' "$2" >&2; fi
  if [ "$2" = pre-start ] && [ -f "$PR_FAIL" ]; then echo 'install failed' >&2; exit 7; fi;;
 'switch --no-hooks')
  if [ ! -d "$PR_DEST" ]; then git worktree add -q -b feat/fix "$PR_DEST" || exit; fi
  printf '{"path":"%s","branch":"feat/fix"}\n' "$PR_DEST"
  if [ -n "$PR_SWITCH_FAIL" ]; then exit 9; fi;;
 *) echo "unexpected wt: $*" >&2; exit 8;;
esac
"""#

let rexFixtureScript = #"""
#!/bin/sh
printf 'rex %s\n' "$*" >> "$PR_LOG"
case "$1" in
 new) echo '{"session_id":"s1","initial_windows":[{"window_id":"w1","block_ids":["b1"]}]}';;
 window) echo '{"session_id":"s1","window_id":"w1","block_ids":["b1"]}';;
 session) echo '{"windows":[{"window_id":"w1","focused_block_id":"b1","blocks":[{"block_id":"b1"}]}]}';;
 ls) echo '{"sessions":[{"session_id":"s1"}]}';;
 do) printf '%s\n' "$PR_DEST";;
 -C) if [ -f "$PR_FAIL" ]; then exit 5; fi;;
 *) exit 8;;
esac
"""#

func fixture(_ env: TestEnv) throws -> (repo: String, path: String) {
    let dir = try makeTempDir()
    let root = evalSymlinks(dir) ?? dir
    let repo = root + "/base"
    let path = root + "/worktree"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    _ = try git(repo, ["init", "-b", "main"])
    _ = try git(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                       "commit", "--allow-empty", "-m", "fixture"])
    _ = try git(repo, ["remote", "add", "origin", "git@github.com:acme/project.git"])
    env.set("HOME", root + "/home")
    env.set("XDG_STATE_HOME", root + "/state")
    env.set("PR_DEST", path)
    env.set("PR_LOG", root + "/calls")
    env.set("PR_FAIL", root + "/fail")
    env.set("PR_HOOK_PHASES", "pre-start post-start post-switch")
    let bin = root + "/bin"
    env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
    try put(bin + "/gh", ghFixtureScript)
    try put(bin + "/zoxide", "#!/bin/sh\nexit 0\n")
    try put(bin + "/wt", wtFixtureScript)
    try put(bin + "/rex", rexFixtureScript)
    return (repo, path)
}

func commitFixture(_ env: TestEnv, state: String, deleted: Bool) throws -> (repo: String, path: String, remote: String, oid: String) {
    let (repo, path) = try fixture(env)
    let oid = try git(repo, ["rev-parse", "HEAD"])
    let remote = dirOf(repo) + "/remote.git"
    _ = try git(repo, ["clone", "--bare", repo, remote])
    _ = try git(remote, ["update-ref", "refs/pull/42/head", oid])
    _ = try git(repo, ["config", "url." + remote + ".insteadOf", "https://github.com/acme/project.git"])
    env.set("GIT_ALLOW_PROTOCOL", "file") // Tests can never fetch over the network.
    let metadata = "{\"number\":42,\"title\":\"Fix\",\"headRefName\":\"feat/fix\",\"state\":\"\(state)\",\"headRefOid\":\"\(oid)\"}"
    let ref = deleted ? "null" : "{\"name\":\"feat/fix\"}"
    let response = "{\"data\":{\"repository\":{\"pullRequest\":{\"state\":\"\(state)\",\"headRefOid\":\"\(oid)\",\"headRef\":\(ref)}}}}"
    env.set("PR_METADATA", metadata)
    env.set("PR_GRAPHQL", response)
    let bin = dirOf(repo) + "/bin"
    try put(bin + "/gh", #"""
#!/bin/sh
printf 'gh %s\n' "$*" >> "$PR_LOG"
case "$1 $2" in
 'api --hostname')
  if [ "$4" = graphql ]; then
   [ -z "$PR_API_FAIL" ] || exit 9
   printf '%s\n' "$PR_GRAPHQL"
  else echo '{"base":{"repo":{"full_name":"acme/project"}}}'; fi;;
 'pr view') printf '%s\n' "$PR_METADATA";;
 *) exit 8;;
esac
"""#)
    let wtPath = bin + "/wt"
    let data = try String(contentsOfFile: wtPath, encoding: .utf8)
    var text = data.replacingOccurrences(of: #"git worktree add -q -b feat/fix "$PR_DEST""#,
                                         with: #"git worktree add -q "$PR_DEST" pr/42"#)
    text = text.replacingOccurrences(of: #""branch":"feat/fix""#, with: #""branch":"pr/42""#)
    try put(wtPath, text)
    return (repo, path, remote, oid)
}

func localFixture(_ env: TestEnv) throws -> (repo: String, path: String) {
    let (repo, path) = try fixture(env)
    env.set("PR_HOOK_PHASES", "")
    return (repo, path)
}

// MARK: - setup capture helpers

/// Files avoid pipe-buffer limits while capturing the same descriptors inherited
/// by interactive hooks. These tests, like the fixture's environment, are serial.
func captureSetup(_ path: String, _ retry: Bool) throws -> (stdout: String, stderr: String, error: Error?) {
    let dir1 = try makeTempDir()
    let dir2 = try makeTempDir()
    let outPath = dir1 + "/stdout"
    let errPath = dir2 + "/stderr"
    FileManager.default.createFile(atPath: outPath, contents: nil)
    FileManager.default.createFile(atPath: errPath, contents: nil)
    guard let out = FileHandle(forWritingAtPath: outPath), let errF = FileHandle(forWritingAtPath: errPath) else {
        throw MessageError("capture temp files unavailable")
    }
    defer { try? out.close(); try? errF.close() }
    let savedOut = dup(1)
    let savedErr = dup(2)
    dup2(out.fileDescriptor, 1)
    dup2(errF.fileDescriptor, 2)
    var caught: Error?
    do {
        try Pullrequest.setup(path: path, retry: retry)
    } catch {
        caught = error
    }
    dup2(savedOut, 1)
    dup2(savedErr, 2)
    close(savedOut)
    close(savedErr)
    let a = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
    let b = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
    return (a, b, caught)
}

func releasedSetupFixture(_ env: TestEnv, existing: Bool) throws -> String {
    let (repo, path) = try fixture(env)
    if existing {
        _ = try git(repo, ["worktree", "add", "-b", "feat/fix", path])
    }
    _ = try Pullrequest.prepare(repo: repo, input: "42")
    var s = try RaptorPullrequest.load(path)
    s.released = true
    try RaptorPullrequest.save(path, s)
    // Only subsequent setup calls matter for execution/inspection assertions.
    try put(env.get("PR_LOG") ?? "", "")
    return path
}

func setupCalls() throws -> String {
    guard let log = ProcessInfo.processInfo.environment["PR_LOG"] else {
        throw MessageError("PR_LOG unset")
    }
    return (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
}

func assertNoHookExecution(_ calls: String) {
    for forbidden in ["wt hook pre-start --", "wt hook post-start --", "wt hook post-switch --", "wt config approvals"] {
        XCTAssertFalse(calls.contains(forbidden), "unexpected \(forbidden): \(calls)")
    }
}

func firstPathDir(_ env: TestEnv) -> String {
    (env.get("PATH") ?? "").components(separatedBy: ":").first ?? ""
}

func readLog(_ env: TestEnv) throws -> String {
    try String(contentsOfFile: env.get("PR_LOG") ?? "", encoding: .utf8)
}
