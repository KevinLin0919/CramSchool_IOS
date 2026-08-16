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
enum Credentials {

    private static let account = "api-token"
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.cramschool.autogradescanner"
    }

    private static let teacherNameKey = "auth.teacherName"
    private static let teacherIDKey = "auth.teacherID"

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

    // MARK: - Writing

    @discardableResult
    static func store(token: String, teacherID: Int, teacherName: String) -> Bool {
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
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
