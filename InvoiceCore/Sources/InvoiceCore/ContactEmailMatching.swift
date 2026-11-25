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
    /// Subject and Gmail's short preview of the text, used as a clue for who the client is.
    public var snippet: String
    public init(people: [ContactCandidate], snippet: String = "") {
        self.people = people
        self.snippet = snippet
    }

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
    /// True when the person is clearly the client (Claude was sure, or the contact's name matches).
    /// False when it's only likely, so Dad confirms.
    public var strong: Bool
    public var id: String { email }

    public init(email: String, name: String, strong: Bool) {
        self.email = email
        self.name = name
        self.strong = strong
    }
}

/// Asks Claude (through the proxy) which people in Dad's mail are the client. No rules about
/// domains or initials: Claude reads names, signatures in the snippets and domains itself, so a
/// rebrand like Crown Management at cmc.rent works the same as anything else.
public struct EmailMatchRequest: Encodable, Equatable, Sendable {
    public struct Person: Encodable, Equatable, Sendable {
        public var email: String
        public var name: String
        public var sentCount: Int
        public var snippets: [String]

        enum CodingKeys: String, CodingKey {
            case email, name, snippets
            case sentCount = "sent_count"
        }
    }

    public var clientName: String
    public var jobAddress: String
    public var people: [Person]

    enum CodingKeys: String, CodingKey {
        case people
        case clientName = "client_name"
        case jobAddress = "job_address"
    }

    /// Everyone worth asking about: people from contacts that matched the name, people in mail
    /// that mentions the client or the address (with what the mail said), then the people Dad
    /// emails most. Dad himself and automated senders are left out.
    public static func make(clientName: String, jobAddress: String, contacts: [ContactCandidate],
                            mails: [MailParticipants], frequent: [EmailDirectory.Entry],
                            sentCounts: [String: Int], ownEmail: String?, limit: Int = 120) -> EmailMatchRequest {
        let own = ownEmail?.lowercased()
        var people: [Person] = []
        var index: [String: Int] = [:]

        func add(_ raw: String, name: String?, snippet: String?) {
            let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard email != own, EmailAddress.isPlausible(email), !ContactEmailMatching.isAutomated(email) else { return }
            let cleanName = name?.trimmingCharacters(in: .whitespaces) ?? ""
            let cleanSnippet = String((snippet ?? "").prefix(300))
            if let i = index[email] {
                if people[i].name.isEmpty { people[i].name = cleanName }
                if !cleanSnippet.isEmpty, people[i].snippets.count < 3, !people[i].snippets.contains(cleanSnippet) {
                    people[i].snippets.append(cleanSnippet)
                }
                return
            }
            guard people.count < limit else { return }
            index[email] = people.count
            people.append(Person(email: email, name: cleanName, sentCount: sentCounts[email] ?? 0,
                                 snippets: cleanSnippet.isEmpty ? [] : [cleanSnippet]))
        }

        for contact in contacts {
            let label = contact.names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
            for email in contact.emails { add(email, name: label, snippet: nil) }
        }
        for mail in mails {
            for person in mail.people {
                for email in person.emails { add(email, name: person.names.first, snippet: mail.snippet) }
            }
        }
        for entry in frequent { add(entry.email, name: entry.name, snippet: nil) }
        return EmailMatchRequest(clientName: clientName, jobAddress: jobAddress, people: people)
    }
}

public struct EmailMatchResponse: Decodable, Equatable, Sendable {
    public struct Match: Decodable, Equatable, Sendable {
        public var email: String
        public var confidence: String
    }
    public var matches: [Match]

    /// Claude's answer as choices, keeping only addresses that were asked about.
    public func suggestions(for request: EmailMatchRequest) -> [EmailSuggestion] {
        let byEmail = Dictionary(request.people.map { ($0.email, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let found = matches.compactMap { match -> EmailSuggestion? in
            let email = match.email.lowercased()
            guard let person = byEmail[email], seen.insert(email).inserted else { return nil }
            return EmailSuggestion(email: email, name: person.name, strong: match.confidence == "sure")
        }
        // Sure first, then the ones he emails most.
        return found.enumerated().sorted { a, b in
            if a.element.strong != b.element.strong { return a.element.strong }
            let ca = byEmail[a.element.email]?.sentCount ?? 0, cb = byEmail[b.element.email]?.sentCount ?? 0
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
    }
}

extension ContactEmailMatching {
    /// The single email to fill in without asking: exactly one strong suggestion.
    public static func clearChoice(_ suggestions: [EmailSuggestion]) -> String? {
        let strong = suggestions.filter(\.strong)
        return strong.count == 1 ? strong[0].email : nil
    }

    /// Without Claude (no connection or no server): people from contacts whose name matches,
    /// then people in mail that mentions the client, most often first. Only a name match is strong.
    public static func localSuggestions(name: String, contacts: [ContactCandidate], mails: [MailParticipants],
                                        ownEmail: String?, limit: Int = 4) -> [EmailSuggestion] {
        let spoken = words(name)
        guard !spoken.isEmpty else { return [] }
        let own = ownEmail?.lowercased()
        var found: [String: (suggestion: EmailSuggestion, count: Int, order: Int)] = [:]

        func add(_ raw: String, name: String?, strong: Bool) {
            let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard email != own, EmailAddress.isPlausible(email), !isAutomated(email) else { return }
            var entry = found[email] ?? (EmailSuggestion(email: email, name: "", strong: false), 0, found.count)
            if entry.suggestion.name.isEmpty { entry.suggestion.name = name?.trimmingCharacters(in: .whitespaces) ?? "" }
            entry.suggestion.strong = entry.suggestion.strong || strong
            entry.count += 1
            found[email] = entry
        }

        for contact in contacts where contact.names.contains(where: { matches(spoken: spoken, contactName: $0) }) {
            let person = contact.names.first { !words($0).isEmpty && !matches(spoken: spoken, contactName: $0) }
            for email in contact.emails { add(email, name: person ?? contact.names.first, strong: true) }
        }
        for mail in mails {
            for person in mail.people {
                let byName = person.names.contains { matches(spoken: spoken, contactName: $0) }
                for email in person.emails { add(email, name: person.names.first, strong: byName) }
            }
        }
        let all = found.values
        let pool = all.contains(where: \.suggestion.strong) ? all.filter(\.suggestion.strong) : Array(all)
        return pool.sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }
            .prefix(limit).map(\.suggestion)
    }
}
