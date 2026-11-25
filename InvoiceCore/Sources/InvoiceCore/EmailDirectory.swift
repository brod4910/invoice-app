import Foundation

/// Everyone Dad has sent mail to, built ahead of time from his Sent folder, so a client's
/// email can be found instantly and by company ("Crown Management" -> @crownmgmt.com).
public struct EmailDirectory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var email: String
        public var name: String
        /// How many sent emails included this person.
        public var count: Int
        public var lastSeen: Date
    }

    public var entries: [String: Entry] = [:]
    /// Newest mail already counted; the next refresh only reads mail after this.
    public var syncedThrough: Date?

    public init() {}

    /// Counts one sent email: everyone on To/Cc except Dad and automated addresses.
    public mutating func record(_ mail: MailParticipants, sentAt: Date, ownEmail: String?) {
        let own = ownEmail?.lowercased()
        var seen = Set<String>()
        for person in mail.people {
            for raw in person.emails {
                let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
                guard email != own, EmailAddress.isPlausible(email), !ContactEmailMatching.isAutomated(email),
                      seen.insert(email).inserted else { continue }
                var entry = entries[email] ?? Entry(email: email, name: "", count: 0, lastSeen: sentAt)
                if let name = person.names.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                   entry.name.isEmpty || sentAt >= entry.lastSeen {
                    entry.name = name
                }
                entry.count += 1
                entry.lastSeen = max(entry.lastSeen, sentAt)
                entries[email] = entry
            }
        }
        syncedThrough = max(syncedThrough ?? sentAt, sentAt)
    }

    /// The people Dad emails most, for Claude to consider alongside the mail search.
    public func mostEmailed(_ count: Int) -> [Entry] {
        Array(entries.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastSeen > $1.lastSeen }
            .prefix(count))
    }

    public var sentCounts: [String: Int] { entries.mapValues(\.count) }
}
