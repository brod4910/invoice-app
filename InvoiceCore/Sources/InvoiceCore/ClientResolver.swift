import Foundation

/// A past client, with the addresses of jobs done for them.
public struct ClientRecord: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var addresses: [String]

    public init(id: UUID, name: String, addresses: [String]) {
        self.id = id
        self.name = name
        self.addresses = addresses
    }
}

/// Decides which past client a new job belongs to, from the spoken name and address.
/// When the answer isn't clear it says so, and the app leaves the email blank rather than guess.
public enum ClientResolver {
    public enum Resolution: Equatable, Sendable {
        /// A single past client fits.
        case existing(UUID)
        /// A name was said that matches no past client: a new client.
        case new
        /// More than one past client could fit, or the name and address point to different clients.
        case ambiguous([UUID])
        /// Nothing to go on (no name, and no known address).
        case unknown
    }

    public static func resolve(name: String?, address: String?, history: [ClientRecord]) -> Resolution {
        let spokenName = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let spokenAddress = address?.trimmingCharacters(in: .whitespaces) ?? ""

        let atAddress: [ClientRecord] = spokenAddress.isEmpty ? [] : history.filter { record in
            record.addresses.contains { AddressMatching.same($0, spokenAddress) }
        }

        if !spokenName.isEmpty {
            let byName = ClientMatching.candidates(for: spokenName, in: history.map(\.name)).map { history[$0] }
            switch byName.count {
            case 0:
                // A new name. Even at a known address (a new owner or tenant), it's a new client.
                return .new
            case 1:
                let match = byName[0]
                // The full name said matches: that's the client, even at an address someone else
                // used before (a repeat client at a new place, or a new owner).
                if ClientMatching.normalize(match.name) == ClientMatching.normalize(spokenName) {
                    return .existing(match.id)
                }
                // Only part of the name matched, and the address belongs to someone else: unclear.
                if !atAddress.isEmpty, !atAddress.contains(where: { $0.id == match.id }) {
                    return .ambiguous([match.id] + atAddress.map(\.id))
                }
                return .existing(match.id)
            default:
                // Several clients share the name; the address may settle it.
                let both = byName.filter { c in atAddress.contains { $0.id == c.id } }
                if both.count == 1 { return .existing(both[0].id) }
                return .ambiguous(byName.map(\.id))
            }
        }

        switch atAddress.count {
        case 0: return .unknown
        case 1: return .existing(atAddress[0].id)
        default: return .ambiguous(atAddress.map(\.id))
        }
    }

    /// The address to use for a repeat client when none was said: only if all their past jobs
    /// were at one address. Several different addresses means it's unclear, so nil.
    public static func usualAddress(of record: ClientRecord) -> String? {
        var distinct: [String] = []
        for address in record.addresses where !address.trimmingCharacters(in: .whitespaces).isEmpty {
            if !distinct.contains(where: { AddressMatching.same($0, address) }) { distinct.append(address) }
        }
        return distinct.count == 1 ? distinct[0] : nil
    }
}

public enum AddressMatching {
    private static let abbreviations: [String: String] = [
        "street": "st", "avenue": "ave", "av": "ave", "road": "rd", "drive": "dr", "lane": "ln",
        "court": "ct", "boulevard": "blvd", "place": "pl", "circle": "cir", "highway": "hwy",
        "parkway": "pkwy", "terrace": "ter", "trail": "trl", "way": "wy",
        "north": "n", "south": "s", "east": "e", "west": "w",
        "apartment": "unit", "apt": "unit", "suite": "unit", "ste": "unit",
        "first": "1st", "second": "2nd", "third": "3rd", "fourth": "4th", "fifth": "5th",
    ]

    public static func normalize(_ address: String) -> String {
        ClientMatching.normalize(address)
            .split(separator: " ")
            .map { abbreviations[String($0)] ?? String($0) }
            .joined(separator: " ")
    }

    /// Same place if the normalized addresses are equal, or one is the other plus more detail
    /// ("12 Oak St" vs "12 Oak St Springfield"). Requires a house number so "Oak St" alone never matches.
    public static func same(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        guard short.first?.isNumber == true, short.split(separator: " ").count >= 2 else { return false }
        return long.hasPrefix(short + " ")
    }
}
