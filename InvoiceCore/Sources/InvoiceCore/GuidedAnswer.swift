import Foundation

/// Answers to the recorder's spoken questions ("Who is the client?", "What's the address?").
/// Because the app asked, it already knows what the answer is, so Dad doesn't have to say
/// "client" or "address" first. If he does anyway, the lead-in is dropped.
public enum GuidedAnswer {
    public enum Kind: String, Sendable {
        case client, address

        /// How the answer is written into the transcript, e.g. "Client: Mary Johnson".
        public var label: String { self == .client ? "Client" : "Address" }

        var leadIns: [String] {
            switch self {
            case .client:
                return ["the client's name is", "the client name is", "the client is", "client's name is",
                        "client name is", "client name", "client is", "client", "customer name is",
                        "customer name", "customer is", "customer", "the name is", "name is", "name",
                        "it's for", "it is for", "this is for", "for"]
            case .address:
                return ["the address is", "address is", "the address", "address", "it's at", "it is at",
                        "the job is at", "job is at", "located at", "at"]
            }
        }
    }

    /// The cleaned answer, or nil if nothing is left.
    public static func value(_ kind: Kind, from transcript: String) -> String? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a lead-in once ("Client name is Mary Johnson" -> "Mary Johnson").
        let lower = text.lowercased()
        if let lead = kind.leadIns.first(where: { lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ",") || lower.hasPrefix($0 + ":") }) {
            text = String(text.dropFirst(lead.count))
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;-.!?")))
        guard !text.isEmpty else { return nil }
        switch kind {
        case .client: return SpokenFields.capitalizeWords(SpokenFields.limitWords(text, 8))
        case .address: return SpokenFields.limitWords(text, 15)
        }
    }
}
