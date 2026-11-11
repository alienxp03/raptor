import Foundation
import RaptorPaths

/// Port of Go's filepath.Clean: lexical slash-path normalization.
func pathClean(_ path: String) -> String {
    if path.isEmpty { return "." }
    let rooted = path.hasPrefix("/")
    var parts: [String] = []
    for comp in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
        if comp == "." { continue }
        if comp == ".." {
            if let last = parts.last, last != ".." {
                parts.removeLast()
            } else if !rooted {
                parts.append("..")
            }
            continue
        }
        parts.append(comp)
    }
    var result = parts.joined(separator: "/")
    if rooted { result = "/" + result }
    if result.isEmpty { return "." }
    return result
}

/// Go's filepath.Abs: absolute cleaned path; nil only for an empty path.
func absPath(_ path: String) -> String? {
    if path.isEmpty { return nil }
    if path.hasPrefix("/") { return pathClean(path) }
    return pathClean(FileManager.default.currentDirectoryPath + "/" + path)
}

/// Go's filepath.Dir for already-clean absolute paths.
func dirOf(_ path: String) -> String {
    guard let idx = path.lastIndex(of: "/") else { return "." }
    if idx == path.startIndex { return "/" }
    return pathClean(String(path[..<idx]))
}

/// Port of Go's filepath.EvalSymlinks: resolves symlinks component-wise and
/// returns nil when any component is missing or a symlink loop is hit.
func evalSymlinks(_ path: String) -> String? {
    let cleaned = pathClean(path)
    var queue: [String]
    var base = ""
    if cleaned.hasPrefix("/") {
        queue = cleaned.dropFirst().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    } else {
        base = FileManager.default.currentDirectoryPath
        queue = cleaned.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
    var seen = Set<String>()
    while let comp = queue.first {
        queue.removeFirst()
        if comp == "." { continue }
        if comp == ".." {
            if !base.isEmpty, base != "/" { base = dirOf(base) }
            else if !base.isEmpty && base == "/" { continue }
            else { base = "" }
            continue
        }
        let next = base.isEmpty || base == "/" ? "/" + comp : base + "/" + comp
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next) {
            if seen.contains(next) { return nil }
            seen.insert(next)
            let expanded = target.hasPrefix("/") ? target : (base.isEmpty || base == "/" ? "/" + target : base + "/" + target)
            let resolved = pathClean(expanded)
            var replacement: [String]
            if resolved.hasPrefix("/") {
                base = ""
                replacement = resolved.dropFirst().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            } else {
                replacement = resolved.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            }
            queue = replacement + queue
            continue
        }
        if !FileManager.default.fileExists(atPath: next) { return nil }
        base = next
    }
    if base.isEmpty { return "/" }
    return base
}

/// Go's exec.LookPath: resolves a bare command name against PATH.
func lookPath(_ name: String) -> String? {
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
