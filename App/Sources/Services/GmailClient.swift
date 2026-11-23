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

    /// Creates a draft and returns its Gmail draft id.
    func createDraft(
        to: String?,
        subject: String,
        html: String,
        text: String,
        attachments: [MIMEMessage.Attachment] = []
    ) async throws -> String {
        let token: String
        do {
            token = try await GoogleAuth.shared.validAccessToken()
        } catch {
            signedInEmail = nil
            throw error
        }
        let raw = MIMEMessage.base64URL(MIMEMessage.build(to: to, subject: subject, html: html, text: text, attachments: attachments))

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": ["raw": raw]])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            signOut()
            throw GmailError.needsSignIn
        }
        guard (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else { throw GmailError.failed(status) }
        return id
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
