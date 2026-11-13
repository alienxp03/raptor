import Foundation
import RaptorPaths

/// Ported from internal/execx: process runs with stdout/stderr capture,
/// optional timeout, and Go-style exit-code semantics.
public struct ExecResult {
    public var stdout: String
    public var stderr: String
    public var code: Int

    public init(stdout: String = "", stderr: String = "", code: Int = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.code = code
    }

    /// True when the process ran and exited 0.
    public var ok: Bool { code == 0 }
}

/// Thrown for launch failures and timeouts; carries partial output when a
/// timed-out process already produced some.
public struct ExecxError: Error, CustomStringConvertible {
    public var result: ExecResult
    public var message: String
    public var description: String { message }
}

public enum Execx {
    /// Resolves a bare command name against PATH like Go's exec.Command.
    public static func lookup(name: String) -> String? {
        if name.contains("/") { return FileManager.default.fileExists(atPath: name) ? name : nil }
        let path = RaptorPaths.env("PATH") ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: String(candidate)) {
                return String(candidate)
            }
        }
        return nil
    }

    /// Runs `name` with `args` in `dir`, capturing output. A positive timeout
    /// kills the process: the thrown error's `.result` keeps partial output
    /// and stderr "timed out".
    @discardableResult
    public static func run(dir: String = "", timeout: TimeInterval = 0, name: String, args: [String] = []) throws -> ExecResult {
        guard let executable = lookup(name: name) else {
            throw ExecxError(result: ExecResult(), message: name + ": no such file or directory")
        }
        let process = Process()
        // Captures never accept input. Inherited stdin shares file-status flags
        // with the resident API pipe; a child setting O_NONBLOCK would break it.
        process.standardInput = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if !dir.isEmpty {
            process.currentDirectoryPath = dir
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw ExecxError(result: ExecResult(), message: name + ": " + (error as NSError).localizedDescription)
        }
        // Read concurrently: blocking readDataToEndOfFile deadlocks on large output.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global()
        group.enter()
        queue.async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var timedOut = false
        if timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        group.wait()
        // EOF precedes reaping; isRunning stays true until waitUntilExit runs.
        process.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if timedOut {
            throw ExecxError(result: ExecResult(stdout: stdout, stderr: "timed out", code: Int(process.terminationStatus)), message: name + " timed out")
        }
        return ExecResult(stdout: stdout, stderr: stderr, code: Int(process.terminationStatus))
    }
}
