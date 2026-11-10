import Foundation

/// Port of github.com/sahilm/fuzzy v0.1.1: scoring, byte-indexed match
/// positions, and result ordering must stay identical — catalog ranking is
/// asserted against it and feeds the native app.
public struct FuzzyMatch: Equatable {
    /// The matched string.
    public var str: String
    /// The index of the matched string in the supplied slice.
    public var index: Int
    /// The byte indexes of matched characters. Useful for highlighting matches.
    public var matchedIndexes: [Int]
    /// Score used to rank matches.
    public var score: Int

    public init(str: String = "", index: Int = 0, matchedIndexes: [Int] = [], score: Int = 0) {
        self.str = str
        self.index = index
        self.matchedIndexes = matchedIndexes
        self.score = score
    }
}

/// Abstract source of a list of strings, like Go's fuzzy.Source.
public protocol FuzzySource {
    /// The string to be matched at position i.
    func string(_ i: Int) -> String
    /// The length of the source.
    var count: Int { get }
}

extension Array: FuzzySource where Element == String {
    public func string(_ i: Int) -> String { self[i] }
    public var count: Int { indices.count }
}

public enum Fuzzy {
    static let firstCharMatchBonus = 10
    static let matchFollowingSeparatorBonus = 20
    static let camelCaseMatchBonus = 20
    static let adjacentMatchBonus = 5
    static let unmatchedLeadingCharPenalty = -5
    static let maxUnmatchedLeadingCharPenalty = -15

    static let separators: [Unicode.Scalar] = ["/", "-", "_", " ", ".", "\\"]

    /// Find looks up pattern in data and returns matches in descending order
    /// of match quality. Matches with equal score keep a Go-faithful order:
    /// the sort comparator is `>=`, so equals reverse within a sorted block.
    public static func find(_ pattern: String, _ data: [String]) -> [FuzzyMatch] {
        let matches = findFromNoSort(pattern, data)
        return stableSortGo(matches) { $0.score >= $1.score }
    }

    /// FindNoSort is an alternative Find implementation that does not sort
    /// the results in the end.
    public static func findNoSort(_ pattern: String, _ data: [String]) -> [FuzzyMatch] {
        findFromNoSort(pattern, data)
    }

    /// FindFromNoSort is an alternative FindFrom implementation that does
    /// not sort results in the end.
    public static func findFromNoSort(_ pattern: String, _ data: some FuzzySource) -> [FuzzyMatch] {
        if pattern.isEmpty {
            return []
        }
        let runes = pattern.unicodeScalars.map { $0.value }
        var matches: [FuzzyMatch] = []
        var matchedIndexes: [Int]? = nil
        for i in 0..<data.count {
            let s = data.string(i)
            let bytes = Array(s.utf8)
            var match = FuzzyMatch(str: s, index: i, matchedIndexes: matchedIndexes ?? [])
            var score = 0
            var patternIndex = 0
            var bestScore = -1
            var matchedIndex = -1
            var currAdjacentMatchBonus = 0
            var last: UInt32 = 0
            var lastIndex = 0
            var (nextc, nextSize) = decodeRune(bytes, 0)
            var candidate: UInt32 = 0
            var candidateSize = 0
            var j = 0
            while j < bytes.count {
                candidate = nextc
                candidateSize = nextSize
                if equalFold(candidate, runes[patternIndex]) {
                    score = 0
                    if j == 0 {
                        score += firstCharMatchBonus
                    }
                    if isLower(last) && isUpper(candidate) {
                        score += camelCaseMatchBonus
                    }
                    if j != 0 && isSeparator(last) {
                        score += matchFollowingSeparatorBonus
                    }
                    if !match.matchedIndexes.isEmpty {
                        let lastMatch = match.matchedIndexes[match.matchedIndexes.count - 1]
                        let bonus = adjacentCharBonus(lastIndex, lastMatch, currAdjacentMatchBonus)
                        score += bonus
                        // adjacent matches are incremental and keep increasing based on previous adjacent matches
                        // thus we need to maintain the current match bonus
                        currAdjacentMatchBonus += bonus
                    }
                    if score > bestScore {
                        bestScore = score
                        matchedIndex = j
                    }
                }
                var nextp: UInt32 = 0
                if patternIndex < runes.count - 1 {
                    nextp = runes[patternIndex + 1]
                }
                if j + candidateSize < bytes.count {
                    if bytes[j + candidateSize] < 0x80 { // Fast path for ASCII
                        nextc = UInt32(bytes[j + candidateSize])
                        nextSize = 1
                    } else {
                        (nextc, nextSize) = decodeRune(bytes, j + candidateSize)
                    }
                } else {
                    nextc = 0
                    nextSize = 0
                }
                // We apply the best score when we have the next match coming up or when the search string has ended.
                // Tracking when the next match is coming up allows us to exhaustively find the best match and not necessarily
                // the first match.
                // For example given the pattern "tk" and search string "The Black Knight", exhaustively matching allows us
                // to match the second k thus giving this string a higher score.
                if equalFold(nextp, nextc) || nextc == 0 {
                    if matchedIndex > -1 {
                        if match.matchedIndexes.isEmpty {
                            let penalty = matchedIndex * unmatchedLeadingCharPenalty
                            bestScore += max(penalty, maxUnmatchedLeadingCharPenalty)
                        }
                        match.score += bestScore
                        match.matchedIndexes.append(matchedIndex)
                        score = 0
                        bestScore = -1
                        patternIndex += 1
                    }
                }
                lastIndex = j
                last = candidate
                j += candidateSize
            }
            // apply penalty for each unmatched character
            let penalty = match.matchedIndexes.count - bytes.count
            match.score += penalty
            if match.matchedIndexes.count == runes.count {
                matches.append(match)
                matchedIndexes = nil
            } else {
                matchedIndexes = match.matchedIndexes // Recycle match index slice
                matchedIndexes?.removeAll(keepingCapacity: true)
            }
        }
        return matches
    }

    /// utf8.DecodeRuneInString on a byte array: invalid UTF-8 yields U+FFFD size 1;
    /// an empty string yields U+FFFD size 0.
    static func decodeRune(_ bytes: [UInt8], _ i: Int) -> (UInt32, Int) {
        if i >= bytes.count {
            return (0xFFFD, 0)
        }
        let b = bytes[i]
        if b < 0x80 {
            return (UInt32(b), 1)
        }
        let size: Int
        var r: UInt32
        switch b {
        case 0xC0...0xDF:
            size = 2
            r = UInt32(b & 0x1F)
        case 0xE0...0xEF:
            size = 3
            r = UInt32(b & 0x0F)
        case 0xF0...0xF7:
            size = 4
            r = UInt32(b & 0x07)
        default:
            return (0xFFFD, 1)
        }
        if i + size > bytes.count {
            return (0xFFFD, 1)
        }
        for k in 1..<size {
            let cb = bytes[i + k]
            if cb < 0x80 || cb > 0xBF {
                return (0xFFFD, 1)
            }
            r = r << 6 | UInt32(cb & 0x3F)
        }
        if (0xD800...0xDFFF).contains(r) || r > 0x10FFFF {
            return (0xFFFD, 1)
        }
        return (r, size)
    }

    /// Case-insensitive rune comparison under simple case folding, like Go's
    /// strings/unicode equalFold.
    static func equalFold(_ a: UInt32, _ b: UInt32) -> Bool {
        if a == b {
            return true
        }
        if a < 0x80 && b < 0x80 {
            // Go: tr < utf8.RuneSelf after swapping so tr > sr; sr must be upper case.
            let upperRune = max(a, b)
            let lowerRune = min(a, b)
            return (0x41...0x5A).contains(lowerRune) && upperRune == lowerRune + 32
        }
        return simpleFoldValue(a) == simpleFoldValue(b)
    }

    static func simpleFoldValue(_ value: UInt32) -> UInt32 {
        guard let scalar = Unicode.Scalar(value) else { return value }
        let mapping = scalar.properties.lowercaseMapping
        var scalars = mapping.unicodeScalars.makeIterator()
        guard let first = scalars.next(), scalars.next() == nil else {
            // Multi-scalar lowercase mapping (e.g. İ) has no simple fold orbit:
            // Go's SimpleFold leaves such runes in an orbit of their own.
            return value
        }
        return first.value
    }

    /// Go's unicode.IsLower: general category Ll.
    static func isLower(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.generalCategory == .lowercaseLetter
    }

    /// Go's unicode.IsUpper: general category Lu.
    static func isUpper(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.generalCategory == .uppercaseLetter
    }

    static func adjacentCharBonus(_ i: Int, _ lastMatch: Int, _ currentBonus: Int) -> Int {
        if lastMatch == i {
            return currentBonus * 2 + adjacentMatchBonus
        }
        return 0
    }

    static func isSeparator(_ s: UInt32) -> Bool {
        separators.contains { $0.value == s }
    }
}
