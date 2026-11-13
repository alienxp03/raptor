import Foundation
import RaptorPaths

/// Wires Raptor into a Rex configuration file, resh-style: one managed,
/// idempotent block the user never edits by hand. Ported from internal/rexconfig.

/// Managed block markers. Content between them is replaced on every init.
let beginMarker = "-- >>> raptor >>>"
let endMarker = "-- <<< raptor <<<"

/// Error carrying a Go-style message.
public struct RexconfigError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// Options control where the plugin lives and which bindings init writes.
public struct Options {
    /// Bindings maps Rex key names to action invocations, written in order.
    public var bindings: [[String]]

    public init(bindings: [[String]] = []) {
        self.bindings = bindings
    }
}

public enum Rexconfig {
    public static func defaultOptions() -> Options {
        Options(bindings: [
            ["shift+cmd+o", "raptor"],
            ["shift+cmd+c", "raptor_pr_open"],
            ["shift+cmd+n", "raptor_worktree_new"],
            ["ctrl+shift+n", "raptor_worktree_agent"],
        ] + (1...9).map { ["ctrl+cmd+\($0)", "raptor_pin_\($0)"] })
    }

    /// Locates the packaged init.lua for the running executable: Homebrew opt
    /// layouts, an app bundle's bundled plugin, or an installer-owned copy under
    /// the Rex config directory. Empty means the plugin is not installed.
    /// Rewrites …/Cellar/<name>/<version>/rest to …/opt/<name>/rest so wired
    /// configs track Homebrew upgrades through the stable opt symlink.
    static func stabilizeOpt(_ path: String) -> String {
        guard let cellar = path.range(of: "/Cellar/") else { return path }
        let tail = path[cellar.upperBound...]
        let parts = tail.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, !parts[1].isEmpty else { return path }
        return path[..<cellar.lowerBound] + "/opt/" + parts[0] + "/" + parts[2]
    }

    public static func locatePlugin() -> String {
        if let executable = Bundle.main.executableURL?.path {
            var exe = executable
            let real = URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
            if !real.isEmpty { exe = real }
            let dir = (exe as NSString).deletingLastPathComponent
            // Homebrew: …/opt/raptor/bin/raptor → …/opt/raptor/share/raptor/init.lua
            var candidates = [join(dir, "..", "share", "raptor", "init.lua")]
            // App bundle CLI: …/Raptor.app/Contents/MacOS/raptor-cli
            let bundle = (dir as NSString).deletingLastPathComponent
            candidates.append(join(bundle, "Resources", "rex", "init.lua"))
            // macOS app next to a standalone CLI installation.
            candidates.append(join(bundle, "..", "..", "Resources", "rex", "init.lua"))
            for candidate in candidates where isFile(clean(stabilizeOpt(candidate))) {
                return clean(stabilizeOpt(candidate))
            }
        }
        let home = homeDir()
        let configHome = RaptorPaths.env("XDG_CONFIG_HOME").flatMap { $0.isEmpty ? nil : $0 } ?? join(home, ".config")
        let installedPlugin = join(configHome, "rex", "raptor", "init.lua")
        if isFile(installedPlugin) { return installedPlugin }
        let app = discoverApp(home: home)
        if !app.isEmpty {
            let path = join(app, "Contents", "Resources", "rex", "init.lua")
            if isFile(path) {
                return path
            }
        }
        return ""
    }

    static func discoverApp(home: String) -> String {
        for app in [
            join(home, "Applications", "Raptor.app"),
            "/Applications/Raptor.app",
        ] where isFile(join(app, "Contents", "MacOS", "Raptor")) {
            return app
        }
        for prefix in [RaptorPaths.env("HOMEBREW_PREFIX") ?? "", "/opt/homebrew", "/usr/local"] {
            if prefix.isEmpty { continue }
            let app = join(prefix, "opt", "raptor", "libexec", "Raptor.app")
            if isFile(join(app, "Contents", "MacOS", "Raptor")) {
                return app
            }
        }
        return ""
    }

    static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func homeDir() -> String {
        if let c = getenv("HOME"), !String(cString: c).isEmpty {
            return String(cString: c)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Resolves the Rex configuration file: REX_CONFIG, then the account config
    /// directory. The file itself may not exist yet.
    public static func configPath() -> String {
        if let c = getenv("REX_CONFIG"), String(cString: c) != "" {
            return String(cString: c)
        }
        var base = RaptorPaths.env("XDG_CONFIG_HOME") ?? ""
        if base.isEmpty {
            base = join(homeDir(), ".config")
        }
        return join(base, "rex", "init.lua")
    }

    /// Renders the managed Lua block for the discovered plugin.
    public static func block(plugin: String, options: Options) -> String {
        var b = ""
        b += beginMarker + "\n"
        b += "dofile(\(quote(plugin))).setup{}\n"
        for binding in options.bindings {
            b += "rex.bind(\(quote(binding[0])), \(quote(binding[1])))\n"
        }
        b += endMarker + "\n"
        return b
    }

    /// Writes the managed block into the Rex configuration. It is idempotent:
    /// existing managed content is replaced in place. A config that wires raptor
    /// outside the managed block is refused unless force is set — silent
    /// duplication would leave two setups fighting over one action name.
    /// Returns whether the file was newly created.
    @discardableResult
    public static func apply(configPath: String, plugin: String, options: Options, force: Bool) throws -> Bool {
        guard !plugin.isEmpty else {
            throw RexconfigError(message: "Rex plugin not found; reinstall Raptor before running raptor init")
        }
        var text = ""
        do {
            text = try String(contentsOfFile: configPath, encoding: .utf8)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            text = ""
        } catch {
            throw RexconfigError(message: "open \(configPath): \(error.localizedDescription)")
        }
        let block = block(plugin: plugin, options: options)
        var created = false
        let begin = text.range(of: beginMarker)
        let end = text.range(of: endMarker)
        if let begin, let end, begin.lowerBound < end.lowerBound {
            let rest = String(text[end.upperBound...]).drop(while: { $0 == "\n" })
            text = String(text[..<begin.lowerBound]) + block + rest
        } else if begin != nil || end != nil {
            throw RexconfigError(message: "\(configPath) has a truncated raptor block; fix or remove the markers")
        } else {
            // Outside references predate managed setup; never stack a second one.
            for rawLine in text.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("raptor"), !trimmed.hasPrefix("--"), !force {
                    throw RexconfigError(message: "\(configPath) already configures raptor at \(quote(trimmed)); remove those lines or pass --force")
                }
            }
            if !text.isEmpty, !text.hasSuffix("\n") {
                text += "\n"
            }
            text += "\n" + block
            created = true
        }
        var dir = (configPath as NSString).deletingLastPathComponent
        if dir.isEmpty { dir = "." }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        if !FileManager.default.createFile(atPath: configPath, contents: Data(text.utf8), attributes: [.posixPermissions: 0o644]) {
            throw RexconfigError(message: "open \(configPath): permission denied")
        }
        return created
    }

    // MARK: - Go string helpers

    static func join(_ parts: String...) -> String {
        var result = ""
        for part in parts {
            if part.isEmpty { continue }
            if result.isEmpty {
                result = part
            } else if result.hasSuffix("/") || part.hasPrefix("/") {
                result = result.hasSuffix("/") && part.hasPrefix("/") ? result + String(part.dropFirst()) : result + part
            } else {
                result += "/" + part
            }
        }
        return result
    }

    static func clean(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// Go %q-style quoting for the string shapes this package writes.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
