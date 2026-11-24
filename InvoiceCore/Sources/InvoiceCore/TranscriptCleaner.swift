import Foundation

/// Tidies speech-to-text before it is saved and written up: drops filler sounds
/// ("um", "uhh", "erm", "hmm") and stuttered repeats ("I I painted", "the the floor").
/// Numbers are never removed, even when repeated, so no price can go missing.
public enum TranscriptCleaner {
    public static func clean(_ text: String) -> String {
        var kept: [String] = []
        for raw in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let bare = raw.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if isFiller(bare) {
                // Keep sentence-ending punctuation that was stuck to the filler ("um.").
                if let last = raw.last, ".?!".contains(last), let previous = kept.last,
                   let end = previous.last, !".?!,".contains(end) {
                    kept[kept.count - 1] = previous + String(last)
                }
                continue
            }
            if let previous = kept.last,
               previous.lowercased().trimmingCharacters(in: .punctuationCharacters) == bare,
               !bare.isEmpty, !bare.contains(where: \.isNumber) {
                kept[kept.count - 1] = raw  // stutter: keep one copy, with this one's punctuation
                continue
            }
            kept.append(raw)
        }
        var out = kept.joined(separator: " ")
        // A filler at the very start can leave a dangling comma.
        while let first = out.first, ",;".contains(first) { out = String(out.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let first = out.first, first.isLowercase, text.first?.isUppercase == true {
            out = first.uppercased() + out.dropFirst()
        }
        return out
    }

    static func isFiller(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let patterns = ["^u+[hm]+$", "^e+r+m*$", "^a+h+$", "^h+m+$", "^m+h*m+$", "^e+h+$"]
        return patterns.contains { word.range(of: $0, options: .regularExpression) != nil }
    }
}
