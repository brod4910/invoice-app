import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Google sign-in using Apple's built-in web sign-in sheet and OAuth with PKCE.
/// No third-party SDK: the refresh token is kept in the Keychain.
@MainActor
final class GoogleAuth: NSObject {
    static let shared = GoogleAuth()

    static let scopes = ["openid", "email", "https://www.googleapis.com/auth/gmail.compose"]

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var session: ASWebAuthenticationSession?

    private var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
    }

    /// e.g. "com.googleusercontent.apps.1234-abc"
    private var redirectScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "GoogleRedirectScheme") as? String ?? ""
    }

    private var redirectURI: String { "\(redirectScheme):/oauthredirect" }

    var hasRefreshToken: Bool { Keychain.read(Keychain.refreshTokenKey) != nil }

    /// Shows Google's sign-in page and returns the signed-in email address.
    func signIn() async throws -> String {
        guard !clientID.isEmpty, !redirectScheme.isEmpty else { throw AuthError.notConfigured }

        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 16)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let callback = try await presentWebSignIn(url: components.url!)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw AuthError.badCallback }
        if items.contains(where: { $0.name == "error" }) { throw AuthError.cancelled }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.badCallback }

        let tokens = try await tokenRequest([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        guard let refresh = tokens.refreshToken else { throw AuthError.noRefreshToken }
        Keychain.write(refresh, for: Keychain.refreshTokenKey)
        store(tokens)
        return try await fetchEmail()
    }

    func signOut() {
        Keychain.delete(Keychain.refreshTokenKey)
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    /// A valid access token, refreshed if it is about to expire.
    func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = Keychain.read(Keychain.refreshTokenKey) else { throw AuthError.notSignedIn }
        do {
            let tokens = try await tokenRequest([
                "client_id": clientID,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            store(tokens)
            return tokens.accessToken
        } catch AuthError.rejected {
            // Google revoked or expired the sign-in (e.g. weekly expiry in testing mode).
            signOut()
            throw AuthError.notSignedIn
        }
    }

    // MARK: - Private

    private func store(_ tokens: TokenResponse) {
        accessToken = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
    }

    private func fetchEmail() async throws -> String {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let info = try JSONDecoder().decode(UserInfo.self, from: data)
        return info.email ?? "Google account"
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { throw AuthError.rejected }
        guard (200..<300).contains(status) else { throw AuthError.server(status) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func presentWebSignIn(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: redirectScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.badCallback)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: AuthError.badCallback) }
        }
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct UserInfo: Decodable {
        let email: String?
    }

    enum AuthError: LocalizedError {
        case notConfigured, cancelled, badCallback, noRefreshToken, notSignedIn, rejected
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Google sign-in isn't set up in this build."
            case .cancelled: "Sign-in was cancelled."
            case .badCallback, .noRefreshToken: "Google sign-in didn't finish. Please try again."
            case .notSignedIn, .rejected: "Please sign in to Gmail again in Settings."
            case .server(let code): "Google had a problem (\(code)). Please try again."
            }
        }
    }
}

extension GoogleAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
                preconditionFailure("Sign-in needs a visible window")
            }
            return scene.keyWindow ?? ASPresentationAnchor(windowScene: scene)
        }
    }
}

/// Minimal Keychain wrapper for one string per key.
enum Keychain {
    static let refreshTokenKey = "google.refreshToken"
    private static let service = "InvoiceApp"

    static func write(_ value: String, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
