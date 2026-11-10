import Foundation
import RaptorExecx
import RaptorWorktree

/// Plain process exit failure with Go's ExitError text ("exit status 7").
struct ExitStatusError: Error, CustomStringConvertible {
    let code: Int32
    var description: String { "exit status \(code)" }
}

/// Error for commandContext failures. `stdout` preserves partial output the way
/// Go's cmd.Output returned `string(out)` alongside the error, so Open's create
/// reconciliation can keep every returned ID even when Rex exits nonzero.
struct CmdError: Error, CustomStringConvertible {
    enum Kind {
        case exit(Int32)
        case signal(Int32)
        case timedOut
        case launch
        case waitDelay
    }

    let name: String
    let kind: Kind
    let stderr: String // trimmed
    let stdout: String // raw
    let exitedNormally: Bool

    /// Go's *exec.ExitError classification: exit status or signal death.
    var isExitError: Bool {
        if case .exit = kind { return true }
        if case .signal = kind { return true }
        return false
    }

    /// Go's *exec.Error classification: the executable could not start.
    var isLaunchError: Bool {
        if case .launch = kind { return true }
        return false
    }

    var description: String {
        let tail = ": " + stderr
        switch kind {
        case .exit(let c): return "\(name): exit status \(c)\(tail)"
        case .signal(let s): return "\(name): signal: \(s == SIGKILL ? "killed" : "\(s)")\(tail)"
        case .timedOut: return "\(name): context deadline exceeded\(tail)"
        case .launch: return "\(name): exec: \"\(name)\": executable file not found in $PATH\(tail)"
        case .waitDelay: return "\(name): exec: WaitDelay expired before I/O complete\(tail)"
        }
    }
}

func wExited(_ status: Int32) -> Bool { (status & 0x7f) == 0 }
func wExitCode(_ status: Int32) -> Int32 { (status >> 8) & 0xff }
func wSignaled(_ status: Int32) -> Bool { let t = status & 0x7f; return t != 0 && t != 0x7f }
func wTermSig(_ status: Int32) -> Int32 { status & 0x7f }

final class LockedBox<T> {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var current: T {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

/// Port of process_unix.go + commandContext: child processes run in their own
/// process group (Setpgid); the group is killed on timeout (Cancel) and after
/// Wait returns (finishProcess); pipe drain is bounded after parent exit
/// (WaitDelay of one second).
enum Procs {
    /// posix_spawn into a fresh process group with pipe/inherit std wiring.
    static func spawn(executable: String, argv: [String], dir: String, group: Bool,
                      stdinNull: Bool, outWrite: Int32?, errWrite: Int32?) throws -> pid_t {
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdinNull {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        if let w = outWrite {
            posix_spawn_file_actions_adddup2(&actions, w, 1)
            posix_spawn_file_actions_addclose(&actions, w)
        }
        if let w = errWrite {
            posix_spawn_file_actions_adddup2(&actions, w, 2)
            posix_spawn_file_actions_addclose(&actions, w)
        }
        if !dir.isEmpty {
            let rc = posix_spawn_file_actions_addchdir_np(&actions, dir)
            if rc != 0 {
                throw MessageError("chdir \(dir): \(errnoText(rc))")
            }
        }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if group {
            posix_spawnattr_setpgroup(&attr, 0)
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        }
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, &cargs, environ)
        if rc != 0 {
            throw MessageError("spawn \(executable): \(errnoText(rc))")
        }
        return pid
    }

    /// Go's finishProcess: also remove children left behind after an early
    /// parent exit / WaitDelay. Group leader absence is fine.
    static func killGroup(_ pid: pid_t, _ sig: Int32 = SIGKILL) {
        if pid <= 0 { return }
        _ = kill(-pid, sig)
    }

    static func waitBlocking(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return status
    }

    /// Polls for exit with a deadline; done=false on timeout.
    static func waitExit(_ pid: pid_t, timeout: TimeInterval) -> (status: Int32, done: Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return (status, true) }
            if r < 0, errno == EINTR { continue }
            if Date() >= deadline { return (0, false) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    static func drain(fd: Int32, box: LockedBox<Data>, sem: DispatchSemaphore) {
        DispatchQueue.global().async {
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            close(fd)
            box.current = data
            sem.signal()
        }
    }

    /// Port of Go's commandContext/cmd.Output: capture stdout/stderr with the
    /// 2-minute budget handled by the caller's timeout argument.
    static func capture(dir: String, timeout: TimeInterval, name: String, args: [String]) throws -> (stdout: String, stderr: String) {
        guard let executable = Execx.lookup(name: name) else {
            throw CmdError(name: name, kind: .launch, stderr: "", stdout: "", exitedNormally: false)
        }
        var outFds = [Int32](repeating: -1, count: 2)
        var errFds = [Int32](repeating: -1, count: 2)
        guard pipe(&outFds) == 0, pipe(&errFds) == 0 else {
            throw CmdError(name: name, kind: .launch, stderr: "", stdout: "", exitedNormally: false)
        }
        let pid: pid_t
        do {
            pid = try spawn(executable: executable, argv: [name] + args, dir: dir, group: true,
                            stdinNull: true, outWrite: outFds[1], errWrite: errFds[1])
        } catch {
            close(outFds[0]); close(outFds[1]); close(errFds[0]); close(errFds[1])
            throw error
        }
        close(outFds[1])
        close(errFds[1])
        let outBox = LockedBox<Data>(Data())
        let errBox = LockedBox<Data>(Data())
        let outSem = DispatchSemaphore(value: 0)
        let errSem = DispatchSemaphore(value: 0)
        drain(fd: outFds[0], box: outBox, sem: outSem)
        drain(fd: errFds[0], box: errBox, sem: errSem)
        var status: Int32 = 0
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0, errno == EINTR { continue }
            if Date() >= deadline {
                timedOut = true
                killGroup(pid, SIGKILL)
                status = waitBlocking(pid)
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // WaitDelay-bounded drain after the parent exited. The group kill
        // (Go's deferred finishProcess) happens only after this wait.
        let drainDeadline = Date().addingTimeInterval(1.0)
        var outDrained = outSem.wait(timeout: .now() + max(0, drainDeadline.timeIntervalSinceNow)) != .timedOut
        var errDrained = errSem.wait(timeout: .now() + max(0, drainDeadline.timeIntervalSinceNow)) != .timedOut
        let drained = outDrained && errDrained
        killGroup(pid, SIGKILL)
        if !outDrained { outDrained = outSem.wait(timeout: .now() + 2.0) != .timedOut }
        if !errDrained { errDrained = errSem.wait(timeout: .now() + 2.0) != .timedOut }
        let out = String(data: outBox.current, encoding: .utf8) ?? ""
        let err = String(data: errBox.current, encoding: .utf8) ?? ""
        let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut {
            throw CmdError(name: name, kind: .timedOut, stderr: trimmedErr, stdout: out, exitedNormally: false)
        }
        if wSignaled(status) {
            throw CmdError(name: name, kind: .signal(wTermSig(status)), stderr: trimmedErr, stdout: out, exitedNormally: false)
        }
        let code = wExitCode(status)
        if code != 0 {
            throw CmdError(name: name, kind: .exit(code), stderr: trimmedErr, stdout: out, exitedNormally: true)
        }
        if !drained {
            throw CmdError(name: name, kind: .waitDelay, stderr: trimmedErr, stdout: out, exitedNormally: true)
        }
        return (out, err)
    }

    /// Port of setup.go's interactive(): wt runs with inherited std descriptors
    /// (post-dup2 under test capture) and no timeout. Nonzero exit maps to
    /// Go's ExitError text.
    static func runInherit(dir: String, name: String, args: [String]) throws -> (code: Int32, exitedNormally: Bool) {
        guard let executable = Execx.lookup(name: name) else {
            throw CmdError(name: name, kind: .launch, stderr: "", stdout: "", exitedNormally: false)
        }
        let pid = try spawn(executable: executable, argv: [name] + args, dir: dir, group: false,
                            stdinNull: false, outWrite: nil, errWrite: nil)
        let status = waitBlocking(pid)
        if wSignaled(status) {
            throw CmdError(name: name, kind: .signal(wTermSig(status)), stderr: "", stdout: "", exitedNormally: false)
        }
        return (wExitCode(status), true)
    }

    /// Spawn in a fresh process group with merged stdout/stderr capture; used by
    /// the setup-wrapper test to interrupt the group like a terminal would.
    static func spawnGroupedCapture(argv: [String]) throws -> (pid: pid_t, readFd: Int32) {
        guard let executable = Execx.lookup(name: argv[0]) else {
            throw CmdError(name: argv[0], kind: .launch, stderr: "", stdout: "", exitedNormally: false)
        }
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else {
            throw CmdError(name: argv[0], kind: .launch, stderr: "", stdout: "", exitedNormally: false)
        }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addclose(&actions, fds[0])
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, &cargs, environ)
        if rc != 0 {
            close(fds[0]); close(fds[1])
            throw CmdError(name: argv[0], kind: .launch, stderr: "", stdout: "", exitedNormally: false)
        }
        close(fds[1])
        return (pid, fds[0])
    }
}
