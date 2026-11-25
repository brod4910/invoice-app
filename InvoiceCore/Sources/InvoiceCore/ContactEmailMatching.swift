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

/// One email someone exchanged with Dad: who it was from and to, from the message headers.
public struct MailParticipants: Equatable, Sendable {
    public var people: [ContactCandidate]
    public init(people: [ContactCandidate]) { self.people = people }

    /// Parses From/To/Cc header values like `Mary Johnson <mary@x.com>, bob@y.com`.
    public static func parse(headers: [String]) -> MailParticipants {
        var people: [ContactCandidate] = []
        for header in headers {
            for part in splitAddresses(header) {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                    let email = String(trimmed[trimmed.index(after: open)..<close])
                    let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
                    people.append(ContactCandidate(names: name.isEmpty ? [] : [name], emails: [email]))
                } else if EmailAddress.isPlausible(trimmed) {
                    people.append(ContactCandidate(names: [], emails: [trimmed]))
                }
            }
        }
        return MailParticipants(people: people)
    }

    /// Splits on commas that aren't inside quotes ("Johnson, Mary" <m@x.com>).
    static func splitAddresses(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for ch in header {
            if ch == "\"" { quoted.toggle() }
            if ch == "," && !quoted { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        return parts
    }
}

extension ContactEmailMatching {
    /// From emails that mention the job address: the one other person in all of them.
    /// Dad's own address and no-reply senders are ignored. Nil unless exactly one address is left.
    public static func pickByAddress(mails: [MailParticipants], ownEmail: String?) -> String? {
        let own = ownEmail?.lowercased()
        let emails = Set(
            mails.flatMap(\.people).flatMap(\.emails)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { $0 != own && EmailAddress.isPlausible($0) && !isAutomated($0) }
        )
        return emails.count == 1 ? emails.first : nil
    }

    static func isAutomated(_ email: String) -> Bool {
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "mailer-daemon"]
            .contains { local.contains($0) }
    }

    /// The street number and name to search mail for: "123 Oak Street Apt 4" -> "123 Oak".
    /// Short, so "Oak St" and "Oak Street" both match. Nil if it doesn't start with a number.
    public static func addressSearchTerm(_ address: String) -> String? {
        let words = address.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard words.count >= 2, words[0].allSatisfy(\.isNumber) else { return nil }
        return "\(words[0]) \(words[1])"
    }
}

/// Someone who might be the client's email, for Dad to choose from when it isn't clear.
public struct EmailSuggestion: Equatable, Sendable, Identifiable {
    public var email: String
    /// The person's name if known, e.g. "Veronica Smith".
    public var name: String
    /// True when the name, company or email domain matches the client. False when the person
    /// was only in an email that mentions the client.
    public var strong: Bool
    /// How many of the found emails this person was in.
    public var mentions: Int
    public var id: String { email }

    public init(email: String, name: String, strong: Bool, mentions: Int) {
        self.email = email
        self.name = name
        self.strong = strong
        self.mentions = mentions
    }
}

extension ContactEmailMatching {
    /// Everyone who could be the client, best first. A company client like "Crown Management"
    /// often has several people; this finds them by contact name or company, by display name in
    /// mail, or by an email domain like `@crownmgmt.com`. People who were only in an email that
    /// mentions the client come after, and are left out when any strong match exists.
    public static func suggestions(name: String, contacts: [ContactCandidate], mails: [MailParticipants],
                                   ownEmail: String?, limit: Int = 4) -> [EmailSuggestion] {
        let spoken = words(name)
        guard !spoken.isEmpty else { return [] }
        let keys = distinctiveWords(spoken)
        let own = ownEmail?.lowercased()
        var found: [String: EmailSuggestion] = [:]
        var order: [String] = []

        func add(_ rawEmail: String, name: String?, strong: Bool, mention: Bool) {
            let email = rawEmail.trimmingCharacters(in: .whitespaces).lowercased()
            guard email != own, EmailAddress.isPlausible(email), !isAutomated(email) else { return }
            var entry = found[email] ?? EmailSuggestion(email: email, name: "", strong: false, mentions: 0)
            if found[email] == nil { order.append(email) }
            if entry.name.isEmpty, let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                entry.name = name.trimmingCharacters(in: .whitespaces)
            }
            entry.strong = entry.strong || strong
            if mention { entry.mentions += 1 }
            found[email] = entry
        }

        for contact in contacts where contact.names.contains(where: { matches(spoken: spoken, contactName: $0) }) {
            let person = contact.names.first { !words($0).isEmpty && !matches(spoken: spoken, contactName: $0) }
            for email in contact.emails { add(email, name: person ?? contact.names.first, strong: true, mention: false) }
        }
        for mail in mails {
            var seen = Set<String>()
            for person in mail.people {
                for email in person.emails where seen.insert(email.lowercased()).inserted {
                    let byName = person.names.contains { matches(spoken: spoken, contactName: $0) }
                    add(email, name: person.names.first, strong: byName || domainMatches(email, keys: keys), mention: true)
                }
            }
        }

        let all = order.compactMap { found[$0] }
        let strong = all.filter(\.strong)
        let pool = strong.isEmpty ? all : strong
        let ranked = pool.enumerated().sorted { a, b in
            if a.element.mentions != b.element.mentions { return a.element.mentions > b.element.mentions }
            return a.offset < b.offset
        }.map(\.element)
        return Array(ranked.prefix(limit))
    }

    /// The single email to fill in without asking: exactly one strong suggestion.
    public static func clearChoice(_ suggestions: [EmailSuggestion]) -> String? {
        let strong = suggestions.filter(\.strong)
        return strong.count == 1 ? strong[0].email : nil
    }

    /// Words that identify a company: "Crown Management LLC" -> ["crown"].
    static func distinctiveWords(_ spoken: [String]) -> [String] {
        let generic: Set<String> = [
            "the", "and", "management", "mgmt", "property", "properties", "services", "service", "company",
            "co", "inc", "llc", "ltd", "corp", "group", "realty", "real", "estate", "homes", "home",
            "rentals", "rental", "apartments", "partners", "associates", "holdings", "enterprises",
        ]
        return spoken.filter { $0.count >= 4 && !generic.contains($0) }
    }

    /// The company's word in the email's domain (`veronica@crownmgmt.com`) or, for free mail,
    /// in the name before the @ (`crownmanagement@gmail.com`).
    static func domainMatches(_ email: String, keys: [String]) -> Bool {
        guard !keys.isEmpty else { return false }
        let parts = email.lowercased().split(separator: "@")
        guard parts.count == 2 else { return false }
        let domainLabels = parts[1].split(separator: ".").dropLast()
        let freeMail: Set<String> = [
            "gmail", "googlemail", "yahoo", "hotmail", "outlook", "live", "msn", "icloud", "me", "mac",
            "aol", "comcast", "att", "sbcglobal", "verizon", "cox", "charter", "proton", "protonmail",
        ]
        let isFree = domainLabels.contains { freeMail.contains(String($0)) }
        let haystack = isFree ? String(parts[0]) : domainLabels.joined(separator: ".")
        return keys.contains { haystack.contains($0) }
    }
}
