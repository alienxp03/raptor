import Foundation
import RaptorPaths

public extension Catalog {
    /// LauncherMatchName uses the final directory component, not its parent path.
    /// Session rows pass an empty directory and use their visible label instead.
    static func launcherMatchName(_ label: String, _ directory: String) -> String {
        if directory.isEmpty {
            return label
        }
        return goPathBase(trimRight(directory, "/"))
    }

    /// RankLauncherMatches ranks exact names first, then fuzzy quality. A leading
    /// dot does not prevent an exact hidden-folder match. Equal scores retain the
    /// input order, including the presentation's fixed session recency order.
    static func rankLauncherMatches(_ query: String, _ texts: [String], _ names: [String]) -> [FuzzyMatch] {
        func exact(_ m: FuzzyMatch) -> Bool {
            let name = names[m.index]
            return name.equalFoldGo(query) || trimPrefix(name, ".").equalFoldGo(query)
        }
        func score(_ m: FuzzyMatch) -> Int {
            // Keep the existing capped length penalty for non-exact matches.
            let penalty = m.matchedIndexes.count - m.str.utf8.count
            return m.score - penalty + max(penalty, -5)
        }
        let matches = Fuzzy.findFromNoSort(query, LauncherTexts(texts: texts))
        return stableSortGo(matches) { a, b in
            let (ea, eb) = (exact(a), exact(b))
            if ea != eb {
                return ea
            }
            return score(a) > score(b)
        }
    }

    static func rankLauncherItems(_ items: [LauncherItem], _ query: String) -> [FuzzyMatch] {
        var texts: [String] = []
        var names: [String] = []
        texts.reserveCapacity(items.count)
        names.reserveCapacity(items.count)
        for item in items {
            let directory = item.kind == "session" ? "" : item.path
            texts.append(item.label + " " + RaptorPaths.homeRelative(directory) + " " + item.host)
            names.append(launcherMatchName(item.label, directory))
        }
        return rankLauncherMatches(query, texts, names)
    }
}

func trimRight(_ s: String, _ cutset: Character) -> String {
    var result = Substring(s)
    while let last = result.last, last == cutset {
        result = result.dropLast()
    }
    return String(result)
}

func trimPrefix(_ s: String, _ prefix: String) -> String {
    s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
}

extension String {
    /// Go's strings.EqualFold: Unicode simple case-fold equality.
    func equalFoldGo(_ other: String) -> Bool {
        if self == other { return true }
        let a = Array(unicodeScalars)
        let b = Array(other.unicodeScalars)
        if a.count != b.count {
            return false
        }
        for (x, y) in zip(a, b) {
            if !Fuzzy.equalFold(x.value, y.value) {
                return false
            }
        }
        return true
    }
}

/// Go's path.Base: the final element after cleaning; "" and "/" yield ".".
func goPathBase(_ path: String) -> String {
    if path.isEmpty {
        return "."
    }
    var trimmed = Substring(path)
    while trimmed.count > 0 && trimmed.hasSuffix("/") {
        trimmed = trimmed.dropLast()
    }
    if trimmed.isEmpty {
        return "."
    }
    if let slash = trimmed.lastIndex(of: "/") {
        trimmed = trimmed[trimmed.index(after: slash)...]
    }
    return trimmed.isEmpty ? "." : String(trimmed)
}
