import Foundation

// Presentation only. Stable IDs and backend requests always keep absolute paths.
enum PathDisplay {
    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        let root = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !root.isEmpty, root != "/" else { return path }
        if path == root { return "~" }
        guard path.hasPrefix(root + "/") else { return path }
        return "~" + path.dropFirst(root.count)
    }
}
