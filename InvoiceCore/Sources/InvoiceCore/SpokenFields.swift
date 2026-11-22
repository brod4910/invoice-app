import Foundation

/// Reads fields Dad labels out loud, like "Client Mary Johnson. Address 12 Oak Street."
/// This is plain text matching, not AI, so a labelled field is always picked up exactly as said.
public struct SpokenFields: Equatable, Sendable {
    public var client: String?
    public var address: String?
    public var email: String?
    public var phone: String?

    public init(client: String? = nil, address: String? = nil, email: String? = nil, phone: String? = nil) {
        self.client = client
        self.address = address
        self.email = email
        self.phone = phone
    }

    // Longer labels first so "email address" isn't read as an "address".
    private static let labels = ["email address", "e-mail address", "phone number", "client", "customer", "address", "email", "e-mail", "phone"]

    /// Words that mean "client" was used in a sentence ("the client wanted…") rather than as a label.
    private static let notAName: Set<String> = [
        "wanted", "wants", "said", "says", "asked", "asks", "needs", "needed", "was", "is", "has", "had",
        "will", "would", "told", "paid", "called", "didn't", "doesn't", "liked", "loved",
    ]

    /// Filler that speech often leaves before the next label ("acme plumbing and the address…").
    private static let trailingFiller: Set<String> = ["and", "the", "a", "an", "then", "so", "um", "uh", "her", "his", "their"]

    public static func parse(_ transcript: String) -> SpokenFields {
        var fields = SpokenFields()
        let labelAlternation = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // label, optional "name"/"is"/":" filler, then the value up to a sentence end, a new line,
        // a semicolon or the next label.
        let pattern = "\\b(\(labelAlternation))\\b(?:\\s+name)?(?:\\s+is)?[\\s:,-]*(.+?)(?=\\.(?:\\s|$)|[\\n;]|\\b(?:\(labelAlternation))\\b|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return fields }
        let ns = transcript as NSString
        for match in regex.matches(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: match.range(at: 1)).lowercased()
            let value = dropTrailingFiller(clean(ns.substring(with: match.range(at: 2))))
            guard !value.isEmpty else { continue }
            switch label {
            case "client", "customer":
                let first = value.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if fields.client == nil, !notAName.contains(first) {
                    fields.client = capitalizeWords(limitWords(value, 8))
                }
            case "address":
                if fields.address == nil { fields.address = limitWords(value, 15) }
            case "email", "e-mail", "email address", "e-mail address":
                if fields.email == nil { fields.email = normalizeEmail(value) }
            default:
                if fields.phone == nil { fields.phone = normalizePhone(value) }
            }
        }
        return fields
    }

    /// Fills the result with labelled fields. What was explicitly labelled wins over the AI's guess.
    public func apply(to result: ExtractionResult) -> ExtractionResult {
        var out = result
        if let client { out.clientName = client }
        if let address { out.jobAddress = address }
        if let email { out.clientEmail = email }
        if let phone { out.clientPhone = phone }
        return out
    }

    // MARK: - Helpers

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;-")))
    }

    static func dropTrailingFiller(_ s: String) -> String {
        var words = s.split(separator: " ").map(String.init)
        while let last = words.last, trailingFiller.contains(last.lowercased()) { words.removeLast() }
        return clean(words.joined(separator: " "))
    }

    static func limitWords(_ s: String, _ max: Int) -> String {
        s.split(separator: " ").prefix(max).joined(separator: " ")
    }

    static func capitalizeWords(_ s: String) -> String {
        s.split(separator: " ").map { word in
            // Keep words the speech engine already capitalized ("McDonald", "ABC").
            word.first?.isLowercase == true ? word.prefix(1).uppercased() + word.dropFirst() : String(word)
        }.joined(separator: " ")
    }

    /// "Mary at gmail dot com" -> "mary@gmail.com"
    static func normalizeEmail(_ s: String) -> String? {
        var text = " " + s.lowercased() + " "
        text = text.replacingOccurrences(of: " at ", with: "@")
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " underscore ", with: "_")
            .replacingOccurrences(of: " dash ", with: "-")
        let email = text.filter { !$0.isWhitespace }
        return EmailAddress.isPlausible(email) ? email : nil
    }

    static func normalizePhone(_ s: String) -> String? {
        let digits = s.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        if digits.count == 10 {
            let d = Array(digits)
            return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
        }
        return digits
    }
}
