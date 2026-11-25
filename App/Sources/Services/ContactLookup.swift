import Contacts
import Foundation
import InvoiceCore

/// Finds a client's email: Google Contacts by name (saved contacts and people Dad has emailed),
/// then the iPhone's contacts. If that isn't clear, it searches Dad's Gmail for the client and the
/// job address and asks Claude which of those people, or the people he emails most, are the
/// client. Read-only. Fills in an email only when it's clear; otherwise offers choices.
@MainActor
enum ContactLookup {
    /// Set when the Google sign-in predates the contacts permission; Settings asks to sign in again.
    nonisolated static let needsSignInKey = "contacts.needsGoogleSignIn"

    enum Outcome: Equatable {
        /// One clear email.
        case found(String)
        /// Several people could be the client (a company with a few contacts). Dad picks one.
        case choices([EmailSuggestion])
        case none
    }

    static func lookUp(name: String, address: String, ownEmail: String?) async -> Outcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        // A saved contact with exactly this name settles it without searching mail.
        let contacts = await googleCandidates(trimmed) + phoneCandidates(trimmed)
        let fromContacts = ContactEmailMatching.localSuggestions(name: trimmed, contacts: contacts, mails: [], ownEmail: ownEmail)
        if let clear = ContactEmailMatching.clearChoice(fromContacts) { return .found(clear) }

        // Gmail searches whole messages, so this finds mail where the client is named in a
        // signature or the text, whatever the email address looks like. Words not in quotes,
        // so a slightly different spoken name still finds it.
        var mails = await mailParticipants(query: trimmed)
        if let term = ContactEmailMatching.addressSearchTerm(address) {
            mails += await mailParticipants(query: "\"\(term)\"")
        }

        let book = MailDirectoryStore.shared.directory
        let request = EmailMatchRequest.make(clientName: trimmed, jobAddress: address, contacts: contacts, mails: mails,
                                             frequent: book.mostEmailed(60), sentCounts: book.sentCounts, ownEmail: ownEmail)
        if let answer = await askClaude(request) {
            let picks = answer.suggestions(for: request)
            if let clear = ContactEmailMatching.clearChoice(picks) { return .found(clear) }
            return picks.isEmpty ? .none : .choices(Array(picks.prefix(4)))
        }

        // No connection or no server: fall back to names in contacts and mail.
        let local = ContactEmailMatching.localSuggestions(name: trimmed, contacts: contacts, mails: mails, ownEmail: ownEmail)
        if let clear = ContactEmailMatching.clearChoice(local) { return .found(clear) }
        return local.isEmpty ? .none : .choices(local)
    }

    /// Claude picks who is the client from the people found. Nil if the server can't be reached.
    private static func askClaude(_ request: EmailMatchRequest) async -> EmailMatchResponse? {
        guard !request.people.isEmpty, let url = AppConfig.extractionURL else { return nil }
        var http = URLRequest(url: url.appendingPathComponent("match-email"))
        http.httpMethod = "POST"
        http.timeoutInterval = 60
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Bearer \(AppConfig.appToken)", forHTTPHeaderField: "Authorization")
        http.httpBody = try? JSONEncoder().encode(request)
        guard let (data, response) = try? await URLSession.shared.data(for: http),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return try? JSONDecoder().decode(EmailMatchResponse.self, from: data)
    }

    // MARK: Gmail search

    private static func mailParticipants(query: String) async -> [MailParticipants] {
        // Skip drafts (the app's own invoices) and chats; the newest 20 is plenty.
        await fetchMails(query: "\(query) -in:drafts -in:chats", limit: 20).map(\.mail)
    }

    /// Gmail messages matching a search, newest first, with who they were from and to.
    /// Reads only the From/To/Cc headers, a few at a time.
    static func fetchMails(query: String, limit: Int, headers: [String] = ["From", "To", "Cc", "Subject"]) async -> [(mail: MailParticipants, date: Date)] {
        guard GoogleAuth.shared.hasRefreshToken,
              let token = try? await GoogleAuth.shared.validAccessToken() else { return [] }
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var list = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            list.queryItems = [URLQueryItem(name: "q", value: query),
                               URLQueryItem(name: "maxResults", value: String(min(limit - ids.count, 500)))]
            if let pageToken { list.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            guard let listed: MessageList = await get(list.url!, token: token) else { break }
            ids += (listed.messages ?? []).map(\.id)
            pageToken = listed.nextPageToken
        } while pageToken != nil && ids.count < limit

        var results: [(index: Int, mail: MailParticipants, date: Date)] = []
        for start in stride(from: 0, to: ids.count, by: 8) {
            let chunk = Array(ids[start..<min(start + 8, ids.count)].enumerated())
            await withTaskGroup(of: (Int, MailParticipants, Date)?.self) { group in
                for (offset, id) in chunk {
                    group.addTask {
                        var one = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
                        one.queryItems = [URLQueryItem(name: "format", value: "metadata")]
                            + headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
                        guard let message: Message = await get(one.url!, token: token) else { return nil }
                        let millis = Double(message.internalDate ?? "") ?? 0
                        let all = message.payload?.headers ?? []
                        var mail = MailParticipants.parse(
                            headers: all.filter { ["from", "to", "cc"].contains($0.name.lowercased()) }.map(\.value))
                        let subject = all.first { $0.name.lowercased() == "subject" }?.value ?? ""
                        mail.snippet = [subject, message.snippet ?? ""].filter { !$0.isEmpty }.joined(separator: " - ")
                        return (start + offset, mail, Date(timeIntervalSince1970: millis / 1000))
                    }
                }
                for await item in group { if let item { results.append(item) } }
            }
        }
        return results.sorted { $0.index < $1.index }.map { ($0.mail, $0.date) }
    }

    nonisolated private static func get<T: Decodable>(_ url: URL, token: String) async -> T? {
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
        let nextPageToken: String?
    }

    private struct Message: Decodable {
        struct Payload: Decodable { let headers: [Header]? }
        struct Header: Decodable { let name: String; let value: String }
        let payload: Payload?
        let internalDate: String?
        let snippet: String?
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
