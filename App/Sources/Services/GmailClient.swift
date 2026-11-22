import Foundation
import GoogleSignIn
import InvoiceCore
import Observation
import UIKit

/// Signs in to Google and creates Gmail drafts. Never sends mail.
@MainActor
@Observable
final class GmailClient {
    static let composeScope = "https://www.googleapis.com/auth/gmail.compose"

    private(set) var signedInEmail: String?

    var isSignedIn: Bool { signedInEmail != nil }

    func restore() async {
        guard let user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn() else { return }
        if user.grantedScopes?.contains(Self.composeScope) == true {
            signedInEmail = user.profile?.email
        }
    }

    func signIn() async throws {
        guard let presenter = UIApplication.shared.topViewController else { throw GmailError.noWindow }
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenter,
            hint: nil,
            additionalScopes: [Self.composeScope]
        )
        signedInEmail = result.user.profile?.email
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        signedInEmail = nil
    }

    /// Creates a draft and returns its Gmail draft id.
    func createDraft(to: String?, subject: String, html: String, text: String) async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw GmailError.notSignedIn }
        let fresh = try await user.refreshTokensIfNeeded()
        let raw = MIMEMessage.base64URL(MIMEMessage.build(to: to, subject: subject, html: html, text: text))

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(fresh.accessToken.tokenString)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": ["raw": raw]])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            signedInEmail = nil
            throw GmailError.needsSignIn
        }
        guard (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else { throw GmailError.failed(status) }
        return id
    }

    enum GmailError: LocalizedError {
        case noWindow, notSignedIn, needsSignIn
        case failed(Int)

        var errorDescription: String? {
            switch self {
            case .noWindow: "Couldn't open the Google sign-in screen."
            case .notSignedIn, .needsSignIn: "Please sign in to Gmail again in Settings."
            case .failed(let code): "Gmail didn't accept the draft (\(code))."
            }
        }
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
