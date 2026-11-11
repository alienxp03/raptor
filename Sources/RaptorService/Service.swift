import Foundation
import RaptorPaths

/// Manages the resident panel host: a launchd gui-domain job that keeps the
/// Raptor app running with a pre-created panel. Open requests travel over a
/// unix socket (package panel), so opening never spawns a process. Ported
/// from internal/service.

public struct ServiceError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// The small value set the job definition uses: maps, string slices,
/// strings, bools, and integers.
public enum PlistValue: Equatable {
    case string(String)
    case stringArray([String])
    case bool(Bool)
    case int(Int)
    case dict([String: PlistValue])
}

public enum Service {
    /// The launchd job label for the resident panel host.
    public static let label = "com.alienxp03.raptor.panel"

    /// Keeps the job definition in the cache directory, mirroring the app's
    /// transient, per-user nature. Nothing is installed system-wide.
    public static func plistPath() -> String {
        RaptorPaths.cacheDir() + "/launcher.plist"
    }

    /// Builds the launchd job. KeepAlive restarts the host if it exits;
    /// ThrottleInterval prevents crash loops from spinning.
    public static func definition(appExecutable: String) -> [String: PlistValue] {
        [
            "Label": .string(label),
            "ProgramArguments": .stringArray([appExecutable, "serve"]),
            "EnvironmentVariables": .dict(["PATH": .string(servicePath())]),
            "KeepAlive": .bool(true), // Always keep the panel host up; stop = bootout.
            "ThrottleInterval": .int(2),
            "ExitTimeOut": .int(1),
            "ProcessType": .string("Interactive"),
            "StandardOutPath": .string("/dev/null"),
            "StandardErrorPath": .string(RaptorPaths.cacheDir() + "/service.log"),
        ]
    }

    /// Finds an installed Raptor.app, preferring the same discovery order
    /// init.lua uses.
    public static func discoverApp() throws -> String {
        let home = RaptorPaths.home()
        var candidates = [
            home + "/Applications/Raptor.app",
            "/Applications/Raptor.app",
        ]
        for prefix in [RaptorPaths.env("HOMEBREW_PREFIX") ?? "", "/opt/homebrew", "/usr/local"] {
            if prefix.isEmpty { continue }
            candidates.append(prefix + "/opt/raptor/libexec/Raptor.app")
        }
        for app in candidates {
            let executable = app + "/Contents/MacOS/Raptor"
            if isFile(executable) {
                return app // The .app path; install joins the executable itself.
            }
        }
        throw ServiceError(message: "Raptor.app not found; pass --app /path/to/Raptor.app")
    }

    /// Writes the job definition and loads it, replacing any previous job.
    public static func install(appPath: String) throws {
        var appPath = appPath
        if appPath.isEmpty {
            appPath = try discoverApp()
        }
        let executable = RaptorPaths.absolute(appPath + "/Contents/MacOS/Raptor")
        guard isFile(executable) else {
            throw ServiceError(message: "not a Raptor app executable: \(executable)")
        }
        let data = try marshalPlist(definition(appExecutable: executable))
        guard FileManager.default.createFile(atPath: plistPath(), contents: data, attributes: [.posixPermissions: 0o644]) else {
            throw ServiceError(message: "write \(plistPath()): permission denied")
        }
        _ = try? launchctl("bootout", domain() + "/" + label) // Ignore: may not be loaded.
        try launchctl("bootstrap", domain(), plistPath())
    }

    /// Stops the host and removes the job definition and socket.
    public static func uninstall() throws {
        var stopError: Error?
        do {
            try launchctl("bootout", domain() + "/" + label)
        } catch {
            stopError = error
        }
        try? FileManager.default.removeItem(atPath: plistPath())
        try? FileManager.default.removeItem(atPath: RaptorPaths.panelSocket())
        if let stopError {
            throw ServiceError(message: "service stop: \(stopError)")
        }
    }

    /// Loads (if needed) and starts the job without restarting a running one.
    public static func start() throws {
        if !loaded() {
            guard FileManager.default.fileExists(atPath: plistPath()) else {
                throw ServiceError(message: "service is not installed; run raptor service install first")
            }
            try launchctl("bootstrap", domain(), plistPath())
        }
        try launchctl("kickstart", domain() + "/" + label)
    }

    /// (Re)starts the job regardless of state; used by panel open when the
    /// host socket is missing.
    public static func kickstart() throws {
        guard FileManager.default.fileExists(atPath: plistPath()) else {
            throw ServiceError(message: "service is not installed")
        }
        _ = try? launchctl("bootout", domain() + "/" + label)
        try launchctl("bootstrap", domain(), plistPath())
        try launchctl("kickstart", domain() + "/" + label)
    }

    /// Unloads the job. The socket file disappears with the host.
    public static func stop() throws {
        try launchctl("bootout", domain() + "/" + label)
    }

    /// Reports whether launchd currently has the job loaded.
    public static func status() -> Bool {
        loaded()
    }

    static func loaded() -> Bool {
        do {
            try launchctl("print", domain() + "/" + label)
            return true
        } catch {
            return false
        }
    }

    static func domain() -> String {
        "gui/\(getuid())"
    }

    @discardableResult
    static func launchctl(_ args: String...) throws -> String {
        guard let executable = lookup(name: "launchctl") else {
            throw ServiceError(message: "launchctl \(args.joined(separator: " ")): exec: \"launchctl\": executable file not found in $PATH")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw ServiceError(message: "launchctl \(args.joined(separator: " ")): \(error.localizedDescription)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let combined = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        if process.terminationStatus != 0 {
            throw ServiceError(message: "launchctl \(args.joined(separator: " ")): \(combined.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return combined
    }

    /// Resolves a bare command name against PATH like Go's exec.Command.
    static func lookup(name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.fileExists(atPath: name) ? name : nil
        }
        let path = RaptorPaths.env("PATH") ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: String(candidate)) {
                return String(candidate)
            }
        }
        return nil
    }

    static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func servicePath() -> String {
        let home = RaptorPaths.home()
        return [
            home + "/.local/share/mise/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")
    }

    static func marshalPlist(_ value: [String: PlistValue]) throws -> Data {
        var b = ""
        b += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n"
        try writePlistValue(&b, .dict(value))
        b += "</plist>\n"
        return Data(b.utf8)
    }

    static func writePlistValue(_ b: inout String, _ value: PlistValue) throws {
        switch value {
        case .string(let s):
            b += "<string>\(xmlEscape(s))</string>\n"
        case .bool(let v):
            b += "<\(v ? "true" : "false")/>\n"
        case .int(let v):
            b += "<integer>\(v)</integer>\n"
        case .stringArray(let items):
            b += "<array>\n"
            for item in items {
                b += "<string>\(xmlEscape(item))</string>\n"
            }
            b += "</array>\n"
        case .dict(let dict):
            b += "<dict>\n"
            for key in dict.keys.sorted() {
                b += "<key>\(xmlEscape(key))</key>\n"
                try writePlistValue(&b, dict[key]!)
            }
            b += "</dict>\n"
        }
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
