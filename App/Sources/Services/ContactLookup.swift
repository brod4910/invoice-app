import Contacts
import Foundation
import InvoiceCore

/// Finds a client's email: Google Contacts by name (saved contacts and people Dad has emailed),
/// then the iPhone's contacts, then Dad's Gmail (by name, then by the job address).
/// Read-only; fills in an email only when it's clear.
@MainActor
enum ContactLookup {
    /// Set when the Google sign-in predates the contacts permission; Settings asks to sign in again.
    static let needsSignInKey = "contacts.needsGoogleSignIn"

    static func email(forName name: String, address: String, ownEmail: String?) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let google = await googleCandidates(trimmed)
        if let found = ContactEmailMatching.pick(name: trimmed, candidates: google) { return found }
        let phone = await phoneCandidates(trimmed)
        if let found = ContactEmailMatching.pick(name: trimmed, candidates: google + phone) { return found }

        // Mail by name: people in From/To/Cc whose display name matches.
        let byName = await mailParticipants(query: "\"\(trimmed)\"", ownEmail: ownEmail)
        if let found = ContactEmailMatching.pick(name: trimmed, candidates: byName.flatMap(\.people)) { return found }

        // Mail mentioning the job address, e.g. a client asking for a quote at "123 Oak".
        if let term = ContactEmailMatching.addressSearchTerm(address) {
            let byAddress = await mailParticipants(query: "\"\(term)\"", ownEmail: ownEmail)
            return ContactEmailMatching.pickByAddress(mails: byAddress, ownEmail: ownEmail)
        }
        return nil
    }

    // MARK: Gmail search

    private static func mailParticipants(query: String, ownEmail: String?) async -> [MailParticipants] {
        guard GoogleAuth.shared.hasRefreshToken,
              let token = try? await GoogleAuth.shared.validAccessToken() else { return [] }
        var list = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        // Skip drafts (the app's own invoices) and chats; newest 10 is plenty.
        list.queryItems = [URLQueryItem(name: "q", value: "\(query) -in:drafts -in:chats"),
                           URLQueryItem(name: "maxResults", value: "10")]
        guard let listed: MessageList = await get(list.url!, token: token) else { return [] }
        var mails: [MailParticipants] = []
        for ref in listed.messages ?? [] {
            var one = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(ref.id)")!
            one.queryItems = [URLQueryItem(name: "format", value: "metadata")]
                + ["From", "To", "Cc"].map { URLQueryItem(name: "metadataHeaders", value: $0) }
            guard let message: Message = await get(one.url!, token: token) else { continue }
            mails.append(MailParticipants.parse(headers: (message.payload?.headers ?? []).map(\.value)))
        }
        return mails
    }

    private static func get<T: Decodable>(_ url: URL, token: String) async -> T? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 403 { UserDefaults.standard.set(true, forKey: needsSignInKey); return nil }
        guard (200..<300).contains(status) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private struct MessageList: Decodable {
        struct Ref: Decodable { let id: String }
        let messages: [Ref]?
    }

    private struct Message: Decodable {
        struct Payload: Decodable { let headers: [Header]? }
        struct Header: Decodable { let name: String; let value: String }
        let payload: Payload?
    }

    // MARK: Google

    private static func googleCandidates(_ name: String) async -> [ContactCandidate] {
        guard GoogleAuth.shared.hasRefreshToken,
              let token = try? await GoogleAuth.shared.validAccessToken() else { return [] }
        var found: [ContactCandidate] = []
        // Saved contacts, then "other contacts" (everyone Dad has emailed).
        for (path, mask) in [("people:searchContacts", "names,emailAddresses,organizations"),
                             ("otherContacts:search", "names,emailAddresses")] {
            // Google asks for an empty warm-up search first so its search cache is current.
            _ = await search(path: path, mask: mask, query: "", token: token)
            found += await search(path: path, mask: mask, query: name, token: token)
        }
        return found
    }

    private static func search(path: String, mask: String, query: String, token: String) async -> [ContactCandidate] {
        var components = URLComponents(string: "https://people.googleapis.com/v1/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "readMask", value: mask),
            URLQueryItem(name: "pageSize", value: "10"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return [] }
        if status == 403 {
            // Signed in before the app asked for contacts.
            UserDefaults.standard.set(true, forKey: needsSignInKey)
            return []
        }
        guard (200..<300).contains(status),
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        UserDefaults.standard.set(false, forKey: needsSignInKey)
        return (decoded.results ?? []).map { result in
            let person = result.person
            return ContactCandidate(
                names: (person.names ?? []).compactMap(\.displayName) + (person.organizations ?? []).compactMap(\.name),
                emails: (person.emailAddresses ?? []).compactMap(\.value)
            )
        }
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable { let person: Person }
        struct Person: Decodable {
            struct Name: Decodable { let displayName: String? }
            struct Email: Decodable { let value: String? }
            struct Organization: Decodable { let name: String? }
            let names: [Name]?
            let emailAddresses: [Email]?
            let organizations: [Organization]?
        }
        let results: [Result]?
    }

    // MARK: iPhone contacts

    private static func phoneCandidates(_ name: String) async -> [ContactCandidate] {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            guard (try? await CNContactStore().requestAccess(for: .contacts)) == true else { return [] }
        case .authorized, .limited:
            break
        default:
            return []
        }
        return await Task.detached(priority: .userInitiated) {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let contacts = (try? CNContactStore().unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
            return contacts.map { contact in
                ContactCandidate(
                    names: ["\(contact.givenName) \(contact.familyName)", contact.organizationName],
                    emails: contact.emailAddresses.map { $0.value as String }
                )
            }
        }.value
    }
}
