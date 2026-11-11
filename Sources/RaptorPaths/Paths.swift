import Foundation

/// Filesystem locations the backend shares. Ported from internal/paths.
public enum RaptorPaths {
    /// Live environment read (Go's os.Getenv). ProcessInfo.environment is a
    /// process-start snapshot and misses setenv from tests and callers.
    public static func env(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    /// $HOME like Go's os.UserHomeDir.
    public static func home() -> String {
        if let c = getenv("HOME"), !String(cString: c).isEmpty {
            return String(cString: c)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Cache directory, creating it when missing.
    public static func cacheDir() -> String {
        var base = env("XDG_CACHE_HOME") ?? ""
        if base.isEmpty {
            base = home() + "/Library/Caches"
        }
        let dir = base + "/raptor"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Unix socket the resident panel host listens on.
    public static func panelSocket() -> String {
        cacheDir() + "/panel.sock"
    }

    /// Resolves symlinks and makes a path absolute for stable comparison.
    /// A missing path keeps its form, like Go's EvalSymlinks failure case.
    public static func canonical(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var working = path
        var seen = Set<String>()
        while seen.count < 16 {
            let next = (try? FileManager.default.destinationOfSymbolicLink(atPath: working)) ?? ""
            if next.isEmpty || !next.hasPrefix("/") || seen.contains(next) { break }
            seen.insert(next)
            working = next
        }
        return absolute(working)
    }

    /// Makes a path absolute without resolving symlinks.
    public static func absolute(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    public static func expandHome(_ path: String) -> String {
        if path == "~" { return home() }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return home() + "/" + rest
        }
        return path
    }

    public static func homeRelative(_ path: String) -> String {
        let home = home()
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return (trimmed as NSString).lastPathComponent
    }
}
