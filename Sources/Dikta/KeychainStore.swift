import Foundation
import Security

/// Stores the Anthropic API key in the login keychain as a generic password.
///
/// Deliberately tiny and free of state: the key is read on demand right before
/// a request is built, and never copied into UserDefaults, logs or the menu.
enum KeychainStore {
    private static let service = "com.yahel.dikta"
    private static let account = "anthropic-api-key"

    /// The stored key, or nil when none is set (or the item can't be read).
    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            if status != errSecSuccess && status != errSecItemNotFound {
                NSLog("Dikta: keychain read failed (%d)", Int(status))
            }
            return nil
        }
        return key
    }

    /// Store `key`, or delete the item when it is nil or empty.
    static func setAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            deleteAPIKey()
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let updateStatus = SecItemUpdate(
                query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updateStatus != errSecSuccess {
                NSLog("Dikta: keychain update failed (%d)", Int(updateStatus))
            }
        default:
            NSLog("Dikta: keychain add failed (%d)", Int(status))
        }
    }

    /// True when a key is present — used for menu state without exposing it.
    static var hasAPIKey: Bool { apiKey() != nil }

    private static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("Dikta: keychain delete failed (%d)", Int(status))
        }
    }
}
