import Foundation
import InvoiceCore
import Observation

/// Creates Gmail drafts for the signed-in Google account. Never sends mail.
@MainActor
@Observable
final class GmailClient {
    private static let emailKey = "gmail.signedInEmail"

    private(set) var signedInEmail: String?

    var isSignedIn: Bool { signedInEmail != nil }

    func restore() async {
        guard GoogleAuth.shared.hasRefreshToken else { signedInEmail = nil; return }
        signedInEmail = UserDefaults.standard.string(forKey: Self.emailKey)
    }

    func signIn() async throws {
        let email = try await GoogleAuth.shared.signIn()
        UserDefaults.standard.set(email, forKey: Self.emailKey)
        signedInEmail = email
    }

    func signOut() {
        GoogleAuth.shared.signOut()
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        signedInEmail = nil
    }

    enum DraftResult {
        /// The existing draft was overwritten.
        case updated(id: String)
        /// A new draft was made (first time, or the old one was already sent or deleted).
        case created(id: String, replacedMissing: Bool)

        var id: String {
            switch self {
            case .updated(let id), .created(let id, _): id
            }
        }
    }

    /// Overwrites the draft `existingID` if it still exists, otherwise creates a new draft.
    func saveDraft(
        replacing existingID: String?,
        to: String?,
        subject: String,
        html: String,
        text: String,
        attachments: [MIMEMessage.Attachment] = []
    ) async throws -> DraftResult {
        let token: String
        do {
            token = try await GoogleAuth.shared.validAccessToken()
        } catch {
            signedInEmail = nil
            throw error
        }
        let raw = MIMEMessage.base64URL(MIMEMessage.build(to: to, subject: subject, html: html, text: text, attachments: attachments))

        if let existingID, !existingID.isEmpty {
            // PUT replaces the whole draft. 404 means it was sent or deleted in Gmail.
            let (status, id) = try await send(
                method: "PUT",
                path: "drafts/\(existingID)",
                body: ["id": existingID, "message": ["raw": raw]],
                token: token
            )
            if (200..<300).contains(status), let id { return .updated(id: id) }
            if status != 404 { throw GmailError.failed(status) }
        }

        let (status, id) = try await send(method: "POST", path: "drafts", body: ["message": ["raw": raw]], token: token)
        guard (200..<300).contains(status), let id else { throw GmailError.failed(status) }
        return .created(id: id, replacedMissing: !(existingID ?? "").isEmpty)
    }

    private func send(method: String, path: String, body: [String: Any], token: String) async throws -> (Int, String?) {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            signOut()
            throw GmailError.needsSignIn
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status, json?["id"] as? String)
    }

    enum GmailError: LocalizedError {
        case needsSignIn
        case failed(Int)

        var errorDescription: String? {
            switch self {
            case .needsSignIn: "Please sign in to Gmail again in Settings."
            case .failed(let code): "Gmail didn't accept the draft (\(code))."
            }
        }
    }
}
