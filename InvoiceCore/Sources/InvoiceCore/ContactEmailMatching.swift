import Foundation

/// A contact found in Google Contacts or on the phone.
public struct ContactCandidate: Equatable, Sendable {
    /// Person name and/or company name.
    public var names: [String]
    public var emails: [String]

    public init(names: [String], emails: [String]) {
        self.names = names
        self.emails = emails
    }
}

/// Picks a client's email from contacts by the name Dad said. Only fills it in when the
/// answer is clear: every match points to the same single address. Otherwise nil, so the
/// email stays blank for review.
public enum ContactEmailMatching {
    public static func pick(name: String, candidates: [ContactCandidate]) -> String? {
        let spoken = words(name)
        guard !spoken.isEmpty else { return nil }
        let matches = candidates.filter { candidate in
            candidate.names.contains { matches(spoken: spoken, contactName: $0) }
        }
        let emails = Set(
            matches.flatMap(\.emails)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { EmailAddress.isPlausible($0) }
        )
        return emails.count == 1 ? emails.first : nil
    }

    /// Same words, or a full name said and contained in the contact ("Mary Johnson" fits
    /// "Mary A. Johnson"). A first name alone must match the whole contact name exactly,
    /// so "Mary" doesn't pick some other Mary.
    static func matches(spoken: [String], contactName: String) -> Bool {
        let contact = words(contactName)
        guard !contact.isEmpty else { return false }
        if contact == spoken { return true }
        return spoken.count >= 2 && Set(spoken).isSubset(of: Set(contact))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
