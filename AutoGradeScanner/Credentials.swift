import Foundation
import Security

// The device's API credential.
//
// The token goes in the Keychain rather than UserDefaults: UserDefaults is a
// plist inside the app container, readable by anything that can reach the
// filesystem, and it rides along in iCloud backups. A token that grants access
// to every answer key in the school does not belong there.
//
// The teacher's name and id sit in UserDefaults on purpose — they are not
// secret, they are shown in Settings, and keeping them out of the Keychain
// means the common "who am I logged in as" read costs nothing.

/// How this device got its credential.
///
/// Recorded because the two paths are not equally reversible, and the sign-out
/// affordance has to say so. A Microsoft device can sign out and sign straight
/// back in as somebody else — which is the whole point, since signing in as the
/// wrong account is the common mistake. An invite-code device cannot: the code
/// was spent when it was redeemed, so leaving means waiting for an admin to
/// issue another one.
enum EnrolmentMethod: String {
    case microsoft
    case invite
}

enum Credentials {

    private static let account = "api-token"
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.cramschool.autogradescanner"
    }

    private static let teacherNameKey = "auth.teacherName"
    private static let teacherIDKey = "auth.teacherID"
    private static let methodKey = "auth.enrolmentMethod"
    private static let expiresAtKey = "auth.expiresAt"

    /// Posted when enrolment starts or ends, so views showing enrolment state
    /// (and DemoData's default) refresh without polling the Keychain.
    static let didChange = Notification.Name("Credentials.didChange")

    // MARK: - Reading

    static var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static var isEnrolled: Bool { token != nil }

    static var teacherName: String? {
        UserDefaults.standard.string(forKey: teacherNameKey)
    }

    static var teacherID: Int? {
        let stored = UserDefaults.standard.integer(forKey: teacherIDKey)
        return stored > 0 ? stored : nil
    }

    /// Devices enrolled before this was recorded read back as `.invite`, which
    /// is not a guess: the invite code was the only path that ever worked.
    static var enrolmentMethod: EnrolmentMethod {
        UserDefaults.standard.string(forKey: methodKey)
            .flatMap(EnrolmentMethod.init(rawValue:)) ?? .invite
    }

    /// ISO-8601, as the server sent it, or nil for an authorisation that never
    /// expires. Kept as the string because it is only ever displayed — the
    /// server is the one that decides a token is dead, and it says so with a
    /// 401 whatever this thinks.
    static var expiresAt: String? {
        UserDefaults.standard.string(forKey: expiresAtKey)
    }

    // MARK: - Writing

    @discardableResult
    static func store(token: String,
                      teacherID: Int,
                      teacherName: String,
                      method: EnrolmentMethod,
                      expiresAt: String? = nil) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace rather than update: re-enrolling a device is rare, and a
        // delete-then-add cannot leave two entries fighting over one account.
        SecItemDelete(base as CFDictionary)

        var insert = base
        insert[kSecValueData as String] = Data(token.utf8)
        // AfterFirstUnlock, not WhenUnlocked: the upload queue runs while the
        // screen is locked, and a token it cannot read means a teacher's
        // grading sits in the outbox until they next pick the phone up.
        // ThisDeviceOnly so a restored backup cannot resurrect the credential
        // on hardware the school never enrolled — the whole point of a
        // per-device token is that revoking it means something.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { return false }

        UserDefaults.standard.set(teacherName, forKey: teacherNameKey)
        UserDefaults.standard.set(teacherID, forKey: teacherIDKey)
        UserDefaults.standard.set(method.rawValue, forKey: methodKey)
        if let expiresAt {
            UserDefaults.standard.set(expiresAt, forKey: expiresAtKey)
        } else {
            UserDefaults.standard.removeObject(forKey: expiresAtKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    static func clear() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: teacherNameKey)
        UserDefaults.standard.removeObject(forKey: teacherIDKey)
        UserDefaults.standard.removeObject(forKey: methodKey)
        UserDefaults.standard.removeObject(forKey: expiresAtKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
