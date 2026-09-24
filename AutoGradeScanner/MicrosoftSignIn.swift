import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

// Signing in with the school's Microsoft account.
//
// Microsoft replaces exactly one step — proving who you are — and nothing
// else. What comes back is the same device token the invite-code path issues,
// so the Keychain, the bearer header and per-device revocation are untouched
// by which door someone came through.
//
// Authorization code with PKCE, which is the flow for a public client: there
// is no client secret here and there must not be one, because a secret shipped
// inside an app is not a secret. The code challenge is what stops an
// intercepted redirect being redeemed by anyone but this process.
//
// The app never asks for an access token and never keeps one. All it needs is
// the `id_token` — a signed assertion of who signed in — which it hands
// straight to our own server to verify and exchange. Asking for anything that
// could act on the teacher's behalf would be collecting a capability with no
// use for it.

enum MicrosoftSignInError: LocalizedError {
    case notConfigured
    case cancelled
    case wrongTenant
    /// Microsoft answered, but not with something this flow can continue from.
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未設定學校帳號登入"
        case .cancelled: return "已取消登入"
        case .wrongTenant: return "這個帳號不屬於浮島，請再試一次"
        case .badResponse: return "Microsoft 回應無法解讀，請再試一次"
        }
    }
}

enum MicrosoftSignIn {

    struct Result {
        let token: String
        let teacherID: Int
        let teacherName: String
        let role: String
        /// ISO-8601. The backend expires Microsoft-issued device tokens on
        /// purpose — an iPad that outlives the directory account it was issued
        /// against would make central offboarding a fiction.
        let expiresAt: String?
    }

    /// Identifiers from the tenant's app registration.
    ///
    /// Neither is a secret — they are the public identifiers of an application
    /// and of a directory, and the flow is a public client with no client
    /// secret by design, so there is nothing here that shipping in the binary
    /// could leak. They carry defaults so the button works on a fresh install
    /// with nothing typed in, and a UserDefaults value still overrides, which
    /// is what lets one build be pointed at a test tenant.
    enum Config {
        static let clientIDKey = "auth.microsoft.clientID"
        static let tenantIDKey = "auth.microsoft.tenantID"

        /// 浮島's registration in the cram school's directory, 2026-09-12.
        static let defaultClientID = "f3eaa930-3ab3-4c6b-8f7c-5adaaa92f745"
        static let defaultTenantID = "b0418364-9041-438d-9062-0a5b28396b37"

        private static func value(_ key: String, _ fallback: String) -> String {
            let stored = UserDefaults.standard.string(forKey: key)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? fallback : stored
        }

        static var clientID: String { value(clientIDKey, defaultClientID) }
        static var tenantID: String { value(tenantIDKey, defaultTenantID) }
    }

    static var isConfigured: Bool {
        !Config.clientID.isEmpty && !Config.tenantID.isEmpty
    }

    /// Fixed, and deliberately NOT derived from the bundle identifier.
    ///
    /// Deriving it was the first thing tried, on the reasoning that the bundle
    /// id is not settled and a constant would quietly go stale. That reasoning
    /// ignored how this app is actually installed: sideloading rewrites the
    /// bundle id on every install, appending the signing team — the build in
    /// hand identifies itself as `com.cramschool.autogradescanner.8NV6MG8FR6`
    /// — so a derived URI matched nothing and Microsoft answered AADSTS50011
    /// on the first real attempt.
    ///
    /// A fixed scheme is safe because `ASWebAuthenticationSession` intercepts
    /// the redirect itself. The scheme is a rendezvous between this process and
    /// the browser sheet it opened; it is never resolved by the system, never
    /// routed to a bundle id, and so has no need to resemble one. The only
    /// thing it must match is the string in the tenant's app registration.
    static let callbackScheme = "msauth.com.cramschool.autogradescanner"

    static var redirectURI: String { callbackScheme + "://auth" }

    @MainActor
    static func run() async throws -> Result {
        guard isConfigured else { throw MicrosoftSignInError.notConfigured }

        let verifier = randomURLSafeString(length: 64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafeString(length: 32)
        let nonce = randomURLSafeString(length: 32)

        let code = try await authorize(challenge: challenge, state: state, nonce: nonce)
        let idToken = try await exchange(code: code, verifier: verifier)

        let response = try await APIClient.shared.signInWithMicrosoft(
            idToken: idToken, deviceName: UIDevice.current.name)
        return Result(token: response.token,
                      teacherID: response.teacherID,
                      teacherName: response.teacherName,
                      role: response.role,
                      expiresAt: response.expiresAt)
    }

    // MARK: - Authorization

    @MainActor
    private static func authorize(challenge: String, state: String,
                                  nonce: String) async throws -> String {
        var components = URLComponents(
            string: "https://login.microsoftonline.com/\(Config.tenantID)/oauth2/v2.0/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            // Not optional. The whole purpose of 登出 is recovering from having
            // signed in as the wrong account, and ASWebAuthenticationSession
            // shares Safari's cookies — without this, signing out and back in
            // silently returns the same wrong account and the button looks
            // broken.
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let url = components?.url else { throw MicrosoftSignInError.badResponse }

        let anchor = PresentationAnchor()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme) { callback, error in
                    // Held until here so ARC cannot collect the session or its
                    // context provider while the sheet is still up.
                    withExtendedLifetime(anchor) {}
                    if let error {
                        let code = (error as? ASWebAuthenticationSessionError)?.code
                        continuation.resume(throwing: code == .canceledLogin
                                            ? MicrosoftSignInError.cancelled : error)
                        return
                    }
                    guard let callback,
                          let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                              .queryItems else {
                        continuation.resume(throwing: MicrosoftSignInError.badResponse)
                        return
                    }
                    // Checked before the code is read, not after: a redirect
                    // whose state does not match is not this sign-in, and
                    // redeeming its code would be redeeming someone else's.
                    guard items.first(where: { $0.name == "state" })?.value == state else {
                        continuation.resume(throwing: MicrosoftSignInError.wrongTenant)
                        return
                    }
                    guard let code = items.first(where: { $0.name == "code" })?.value else {
                        continuation.resume(throwing: MicrosoftSignInError.badResponse)
                        return
                    }
                    continuation.resume(returning: code)
                }
            session.presentationContextProvider = anchor
            // The teacher may well have signed in on this device before; the
            // shared session is what makes `prompt=select_account` able to
            // offer the accounts they already have.
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: MicrosoftSignInError.badResponse)
            }
        }
    }

    // MARK: - Token exchange

    private static func exchange(code: String, verifier: String) async throws -> String {
        guard let url = URL(string:
            "https://login.microsoftonline.com/\(Config.tenantID)/oauth2/v2.0/token") else {
            throw MicrosoftSignInError.badResponse
        }
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.percentEncodedQuery.map { Data($0.utf8) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = payload["id_token"] as? String else {
            throw MicrosoftSignInError.badResponse
        }
        return idToken
    }

    // MARK: - PKCE helpers

    /// RFC 7636 unreserved characters, so the verifier needs no escaping on the
    /// way out and no unescaping on the way back.
    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func base64URL(_ digest: SHA256.Digest) -> String {
        base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The sheet needs a window to present from, and the window is whichever
    /// one is on screen — this app has no scene it can name in advance.
    private final class PresentationAnchor: NSObject,
                                            ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
