import Foundation

/// Plain message error standing in for Go's fmt.Errorf values.
public struct MessageError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Port of errors.Join: descriptions joined with "\n", nils skipped.
public struct JoinedError: Error, CustomStringConvertible {
    public let parts: [any Error]
    public var description: String { parts.map { String(describing: $0) }.joined(separator: "\n") }
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

/// Port of Go's strconv.Quote for the string shapes branch names take
/// (printable text with quotes, backslashes, and control characters escaped).
func goQuote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7f {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

/// Port of Go's regexp.QuoteMeta.
func quoteMeta(_ s: String) -> String {
    let special: Set<Character> = ["\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$"]
    return s.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
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

/// Lstat semantics: true when `path` exists (dangling symlinks count),
/// false when missing, throws for other filesystem errors.
func lstatExists(_ path: String) throws -> Bool {
    do {
        _ = try FileManager.default.attributesOfItem(atPath: path)
        return true
    } catch {
        if isNotExist(error) { return false }
        throw error
    }
}

/// Go's filepath.Dir for already-clean absolute paths.
func dirOf(_ path: String) -> String {
    guard let idx = path.lastIndex(of: "/") else { return "." }
    if idx == path.startIndex { return "/" }
    return pathClean(String(path[..<idx]))
}

/// Port of Go's filepath.EvalSymlinks: resolves symlinks component-wise and
/// returns nil when any component is missing or a symlink loop is hit
/// (URL.resolvingSymlinksInPath leaves intermediate symlinks like /var alone).
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
