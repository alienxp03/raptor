import Foundation

/// Go path/filepath semantics needed by the catalog (internal helpers).

/// filepath.Clean for unix paths.
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

/// filepath.Join.
func pathJoin(_ parts: [String]) -> String {
    let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
    return pathClean(joined)
}

/// filepath.Dir: strips the last element and cleans the rest.
func pathDir(_ path: String) -> String {
    let bytes = Array(path.utf8)
    var i = bytes.count - 1
    while i >= 0 && bytes[i] != UInt8(ascii: "/") {
        i -= 1
    }
    return pathClean(String(decoding: bytes[0..<(i + 1)], as: UTF8.self))
}
