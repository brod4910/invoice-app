import Foundation

/// Removes anything the AI returned that isn't backed by the transcript.
/// Small on-device models sometimes invent plausible items and prices; this keeps only
/// items whose words were actually said, and only prices whose number was actually said.
public enum ExtractionGrounding {
    public static func ground(_ result: ExtractionResult, transcript: String) -> ExtractionResult {
        let words = Set(tokens(transcript))
        let numbers = spokenNumbers(transcript)
        var out = result

        out.items = result.items.compactMap { item in
            let itemWords = tokens(item.description + " " + (item.details ?? ""))
            guard itemWords.contains(where: { isSaid($0, in: words) }) else { return nil }
            var kept = item
            if let cents = item.unitPriceCents, !numbers.contains(Decimal(cents) / 100) {
                kept.unitPriceCents = nil
            }
            if item.quantity != 1, !numbers.contains(Decimal(item.quantity)) {
                kept.quantity = 1
            }
            return kept
        }

        out.clientName = result.clientName.flatMap { name in
            tokens(name).contains(where: { words.contains($0) }) ? name : nil
        }
        out.clientEmail = result.clientEmail.flatMap { email in
            let local = email.split(separator: "@").first.map(String.init) ?? ""
            return tokens(local).contains(where: { words.contains($0) }) ? email : nil
        }
        out.jobAddress = result.jobAddress.flatMap { address in
            tokens(address).contains(where: { isSaid($0, in: words) }) ? address : nil
        }
        return out
    }

    static let removeCues = [
        "remove", "take off", "take it off", "take that off", "delete", "drop", "scratch",
        "cancel", "didn't do", "did not do", "never did", "forget about", "get rid of",
    ]

    /// Keeps only corrections the transcript backs up: a real item number, a new price that was
    /// said, new wording that brings in at least one word that was said and wasn't there before,
    /// and removal only when removal words were said. Also drops new items that just repeat a
    /// corrected item, so "I meant living room" doesn't add a second line.
    public static func groundChanges(_ result: ExtractionResult, transcript: String, existing: [ExistingItem]) -> ExtractionResult {
        let words = Set(tokens(transcript))
        let numbers = spokenNumbers(transcript)
        let said = " " + tokensAllLengths(transcript).joined(separator: " ") + " "
        let removalSaid = removeCues.contains { said.contains(" " + tokensAllLengths($0).joined(separator: " ") + " ") }

        var seen = Set<Int>()
        var changes: [ItemChange] = []
        for raw in result.changes {
            guard existing.indices.contains(raw.itemNumber - 1), !seen.contains(raw.itemNumber) else { continue }
            let old = existing[raw.itemNumber - 1]
            var change = raw
            if let cents = change.newUnitPriceCents, cents == old.unitPriceCents || !numbers.contains(Decimal(cents) / 100) {
                change.newUnitPriceCents = nil
            }
            if let qty = change.newQuantity, qty == old.quantity || !numbers.contains(Decimal(qty)) {
                change.newQuantity = nil
            }
            if let text = change.newDescription?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let oldWords = Set(tokens(old.description))
                let added = tokens(text).filter { !oldWords.contains($0) }
                change.newDescription = (!text.isEmpty && added.contains { isSaid($0, in: words) }) ? text : nil
            }
            if change.remove && !removalSaid { change.remove = false }
            guard !change.isEmpty else { continue }
            seen.insert(raw.itemNumber)
            changes.append(change)
        }

        var out = result
        out.changes = changes
        let correctedWords = changes.compactMap(\.newDescription).map { Set(tokens($0)) }
        if !correctedWords.isEmpty {
            out.items = result.items.filter { item in
                let itemWords = Set(tokens(item.description))
                return !correctedWords.contains { itemWords.isSubset(of: $0) }
            }
        }
        return out
    }

    /// Words that mean one price covers all the work said, e.g. "$450 for the whole job".
    static let wholeJobCues = [
        "whole job", "whole thing", "for everything", "for all of it", "for all that", "for both",
        "all together", "altogether", "all in", "in total", "total of", "the total", "total is",
        "total was", "total price", "one price", "flat rate", "flat fee", "for the job", "for the lot",
    ]

    /// Safety net for the on-device model splitting "paint kitchen and clean floor, $450 for the
    /// whole job" into two items with the price on only one. When the transcript says the price
    /// covers everything and only one item got a price, fold the work into that single item.
    public static func combineSharedPrice(_ result: ExtractionResult, transcript: String) -> ExtractionResult {
        let priced = result.items.filter { $0.unitPriceCents != nil }
        let unpriced = result.items.filter { $0.unitPriceCents == nil }
        guard priced.count == 1, !unpriced.isEmpty, let only = priced.first, only.quantity == 1 else { return result }
        // Match whole words only, so "install in" doesn't count as "all in".
        let said = " " + tokensAllLengths(transcript).joined(separator: " ") + " "
        guard wholeJobCues.contains(where: { said.contains(" \($0) ") }) else { return result }

        let details = result.items.compactMap(\.details).filter { !$0.isEmpty }
        var out = result
        out.items = [ExtractedItem(
            description: joinWork(result.items.map(\.description)),
            quantity: 1,
            unitPriceCents: only.unitPriceCents,
            details: details.isEmpty ? nil : details.joined(separator: "; ")
        )]
        return out
    }

    /// "paint kitchen", "clean floor" -> "Paint kitchen and clean floor".
    public static func joinWork(_ parts: [String]) -> String {
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = cleaned.first else { return "" }
        var lowered: [String] = cleaned.enumerated().map { index, part -> String in
            index == 0 ? part : part.prefix(1).lowercased() + String(part.dropFirst())
        }
        lowered[0] = first.prefix(1).uppercased() + String(first.dropFirst())
        switch lowered.count {
        case 1: return lowered[0]
        case 2: return lowered[0] + " and " + lowered[1]
        default: return lowered.dropLast().joined(separator: ", ") + " and " + lowered.last!
        }
    }

    static func tokensAllLengths(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Lowercased words of 3+ letters or digits.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }

    /// A word counts as said if it appears, or shares a 5-letter stem with a said word
    /// ("replaced" vs "replace", "boards" vs "board").
    static func isSaid(_ word: String, in words: Set<String>) -> Bool {
        if words.contains(word) { return true }
        guard word.count >= 5 else { return false }
        let stem = word.prefix(5)
        return words.contains { $0.count >= 5 && $0.prefix(5) == stem }
    }

    /// Every number written with digits in the transcript, e.g. "$1,200.50" -> 1200.50.
    static func spokenNumbers(_ text: String) -> Set<Decimal> {
        var result = Set<Decimal>()
        var current = ""
        func flush() {
            let cleaned = current.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US")) {
                result.insert(value)
            }
            current = ""
        }
        for ch in text {
            if ch.isASCII && (ch.isNumber || ((ch == "," || ch == ".") && !current.isEmpty)) {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return result
    }
}
