import Foundation
import CryptoKit
import RaptorPaths

/// Port of errors.Join: descriptions joined with "\n", nils skipped.
struct JoinedError: Error, CustomStringConvertible {
    let parts: [any Error]
    var description: String { parts.map { String(describing: $0) }.joined(separator: "\n") }
}

/// Returns nil for no errors, the single error unwrapped, otherwise a JoinedError.
func joinErrors(_ errors: (any Error)?...) -> (any Error)? {
    let parts = errors.compactMap { $0 }
    if parts.isEmpty { return nil }
    if parts.count == 1 { return parts[0] }
    return JoinedError(parts: parts)
}

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

/// Port of Go's filepath.Join.
func pathJoin(_ parts: [String]) -> String {
    pathClean(parts.filter { !$0.isEmpty }.joined(separator: "/"))
}

/// Port of Go's filepath.Dir.
func dirOf(_ path: String) -> String {
    guard let idx = path.lastIndex(of: "/") else { return "." }
    if idx == path.startIndex { return "/" }
    return pathClean(String(path[..<idx]))
}

/// Port of Go's filepath.Base.
func baseOf(_ path: String) -> String {
    if path.isEmpty { return "." }
    var p = path
    while p.count > 1, p.hasSuffix("/") { p.removeLast() }
    if p == "/" { return "/" }
    guard let idx = p.lastIndex(of: "/") else { return p }
    return String(p[p.index(after: idx)...])
}

/// Port of Go's filepath.EvalSymlinks: resolves symlinks component-wise and
/// returns nil when any component is missing or the 255-link bound is exceeded.
/// The same symlink may be expanded repeatedly in one walk, like Go.
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
    var expansions = 0
    while let comp = queue.first {
        queue.removeFirst()
        if comp == "." { continue }
        if comp == ".." {
            if !base.isEmpty, base != "/" { base = dirOf(base) }
            else if base == "/" { continue }
            else { base = "" }
            continue
        }
        let next = base.isEmpty || base == "/" ? "/" + comp : base + "/" + comp
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next) {
            expansions += 1
            if expansions > 255 { return nil }
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

/// Go's filepath.Abs: absolute cleaned path; nil only for an empty path.
func absPath(_ path: String) -> String? {
    if path.isEmpty { return nil }
    if path.hasPrefix("/") { return pathClean(path) }
    return pathClean(FileManager.default.currentDirectoryPath + "/" + path)
}

/// True when a filesystem error means the path does not exist (os.IsNotExist).
func isNotExist(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
        return ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError
    }
    if ns.domain == NSPOSIXErrorDomain { return ns.code == ENOENT }
    return false
}

/// Go's os.UserHomeDir equivalent via the HOME environment.
func userHome() -> String {
    RaptorPaths.home()
}

func errnoText(_ errnum: Int32) -> String {
    String(cString: strerror(errnum))
}

/// sha256 hex digest; nil data hashes the empty input, like Go's Sum256(nil).
func sha256Hex(_ data: Data?) -> String {
    SHA256.hash(data: data ?? Data()).map { String(format: "%02x", $0) }.joined()
}

/// Decodes a JSON string into an array, or nil for invalid JSON / non-array
/// values (including null, which Go's []json.RawMessage unmarshal maps to nil).
func jsonArray(_ out: String) -> [Any]? {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) else { return nil }
    return obj as? [Any]
}
