import XCTest
import RaptorConfig
import RaptorRex
import RaptorExecx
import RaptorPullrequest
import RaptorWorktree
@testable import RaptorTask

/// setenv/unsetenv with recorded originals; mirrors Go's t.Setenv restore.
final class TestEnv {
    private var saved: [String: String?] = [:]

    private func record(_ name: String) {
        if saved[name] == nil {
            if let value = getenv(name) {
                saved[name] = .some(String(cString: value))
            } else {
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
    let dir = base + "/raptor-task-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func writeExecutable(_ path: String, _ script: String) throws {
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
}

func readText(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

func countOccurrences(_ haystack: String, _ needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var range = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, options: [], range: range) {
        count += 1
        range = found.upperBound..<haystack.endIndex
    }
    return count
}

/// (result, error) shape mirroring Go's two-value Start return.
func startResult(_ ctx: Ctx, _ cfg: RaptorConfig, _ repo: String, _ resumePath: String) -> (result: TaskResult, error: Error?) {
    do {
        return (try RaptorTask.start(ctx: ctx, cfg: cfg, explicitRepo: repo, resumePath: resumePath), nil)
    } catch let e as StartError {
        return (e.result, e)
    } catch {
        return (TaskResult(), error)
    }
}

func fixture(_ env: TestEnv) throws -> (repo: String, cfg: RaptorConfig, ctx: Ctx, log: String) {
    let base = try makeTempDir()
    let repo = base + "/repo with spaces"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o755])
    for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.com"],
                 ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "init"]] {
        _ = try WorktreeKit.gitOut(dir: repo, args: args)
    }
    let bin = try makeTempDir()
    let log = try makeTempDir() + "/calls"
    env.set("TASK_LOG", log)
    env.set("XDG_CACHE_HOME", try makeTempDir())
    let wtRoot = try makeTempDir()
    let empty = wtRoot + "/empty.toml"
    try "".write(toFile: empty, atomically: true, encoding: .utf8)
    env.set("WORKTRUNK_CONFIG_PATH", empty)
    env.set("WORKTRUNK_SYSTEM_CONFIG_PATH", empty)
    env.set("WORKTRUNK_PROJECT_CONFIG_PATH", empty)
    env.set("WORKTRUNK_WORKTREE_PATH", wtRoot + "/trees/{{ repo }}/{{ branch | sanitize }}")
    let script = #"""
    #!/bin/sh
    printf 'CALL\n' >> "$TASK_LOG"
    printf '%s\n' "$@" >> "$TASK_LOG"
    case "$1" in
     window)
      echo '{"window_id":"new-window","block_ids":["new-block"]}' ;;
     new)
      if [ "$TASK_FAIL" = open ]; then echo 'open failed' >&2; exit 1; fi
      echo '{"session_id":"new-session","initial_windows":[{"window_id":"new-window","block_ids":["new-block"]}]}' ;;
     -C)
      if [ "$TASK_FAIL" = focus ]; then echo 'focus failed' >&2; exit 1; fi ;;
    esac
    """#
    try writeExecutable(bin + "/rex", script)
    try writeExecutable(bin + "/pi", "#!/bin/sh\nexit 0\n")
    env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
    return (repo, RaptorConfig(worktreeRoot: try makeTempDir() + "/worktree root"),
            Ctx(session: "origin-session", block: "origin-block", client: "iphone"), log)
}
