import Foundation

// The seam for signing in with the school's Microsoft account.
//
// Deliberately not implemented yet. The OAuth flow needs an app registration
// in 浮島's Entra tenant — a client id, a redirect URI, and a tenant id that
// only their tenant admin can create — and the backend needs an endpoint that
// verifies the resulting ID token's signature and `tid` claim. Neither exists,
// and neither can be tested from here.
//
// Writing the flow anyway would produce a screen that looks finished and fails
// in the field, which is worse than a button that says what is missing. What
// this file does provide is the shape the rest of the app codes against, so
// filling it in later touches nothing outside these lines:
//
//   * `isConfigured` gates the button
//   * `run()` returns the same thing enrolment by invite code returns —
//     a device token — because Microsoft replaces only the step that proves
//     who you are. The token layer, the Keychain, and everything downstream
//     are unchanged either way.
//
// The remaining work, once the registration exists:
//   iOS      ASWebAuthenticationSession + PKCE against
//            login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize
//
//            The authorize URL MUST carry `prompt=select_account`. Settings
//            now offers a 登出 whose whole purpose is recovering from signing
//            in as the wrong account, and ASWebAuthenticationSession shares
//            Safari's cookies by default — so without it, 登出 followed by 登入
//            silently returns the same wrong account and the button looks
//            broken. (`prefersEphemeralWebBrowserSession = true` also works,
//            at the cost of re-typing the password every time.)
//   backend  POST /api/v1/auth/microsoft — verify the ID token against the
//            tenant's JWKS, check `aud` and `tid`, find or create the teacher,
//            issue a device token exactly as the invite-code path does.

enum MicrosoftSignInError: LocalizedError {
    case notConfigured
    case cancelled
    case wrongTenant

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未設定學校帳號登入"
        case .cancelled: return "已取消登入"
        case .wrongTenant: return "這個帳號不屬於浮島，請再試一次"
        }
    }
}

enum MicrosoftSignIn {

    struct Result {
        let token: String
        let teacherID: Int
        let teacherName: String
    }

    /// Identifiers from the tenant's app registration. Stored in UserDefaults
    /// rather than compiled in so the same build works against a test tenant
    /// and the school's, and so nothing has to be rebuilt when they arrive.
    enum Config {
        static let clientIDKey = "auth.microsoft.clientID"
        static let tenantIDKey = "auth.microsoft.tenantID"

        static var clientID: String {
            UserDefaults.standard.string(forKey: clientIDKey)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }

        static var tenantID: String {
            UserDefaults.standard.string(forKey: tenantIDKey)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
    }

    static var isConfigured: Bool {
        !Config.clientID.isEmpty && !Config.tenantID.isEmpty
    }

    static func run() async throws -> Result {
        throw MicrosoftSignInError.notConfigured
    }
}
