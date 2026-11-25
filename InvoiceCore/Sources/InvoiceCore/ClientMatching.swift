import Foundation

public enum ClientMatching {
    /// Lowercased, punctuation-free, single-spaced form used for comparisons.
    public static func normalize(_ name: String) -> String {
        let lowered = name.lowercased()
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Indices of every known client whose name matches `spoken`: exact matches if there are any,
    /// otherwise names where one contains the other ("Mrs Johnson" vs "Johnson").
    public static func candidates(for spoken: String, in known: [String]) -> [Int] {
        let target = normalize(spoken)
        guard !target.isEmpty else { return [] }
        let normalized = known.map(normalize)
        let exact = normalized.indices.filter { normalized[$0] == target }
        if !exact.isEmpty { return exact }
        return normalized.indices.filter { i in
            let n = normalized[i]
            guard !n.isEmpty else { return false }
            return wordsContain(n, target) || wordsContain(target, n)
        }
    }

    /// Returns the index of the known client that matches `spoken`, if any.
    /// Matches exact normalized names, then names where one contains the other
    /// ("Mrs Johnson" vs "Johnson"), but only when that is unambiguous.
    public static func bestMatch(for spoken: String, in known: [String]) -> Int? {
        let target = normalize(spoken)
        guard !target.isEmpty else { return nil }
        let normalized = known.map(normalize)
        if let exact = normalized.firstIndex(of: target) { return exact }
        let partial = normalized.indices.filter { i in
            let n = normalized[i]
            guard !n.isEmpty else { return false }
            return wordsContain(n, target) || wordsContain(target, n)
        }
        return partial.count == 1 ? partial[0] : nil
    }

    private static func wordsContain(_ haystack: String, _ needle: String) -> Bool {
        let h = haystack.split(separator: " ")
        let n = needle.split(separator: " ")
        guard n.count <= h.count else { return false }
        for start in 0...(h.count - n.count) where Array(h[start..<(start + n.count)]) == n {
            return true
        }
        return false
    }
}
