import Foundation
import Security

/// Persists the shared symmetric key for a paired peer in the iOS Keychain.
///
/// Phase 1 is one-peer-at-a-time, so we store at most one key under a single
/// account identifier. M4+ can extend this to multiple paired devices by
/// keying on a per-peer identifier.
final class KeyStore: Sendable {
    enum KeyStoreError: Error, Sendable {
        case osStatus(OSStatus)
        case invalidItem
    }

    private let service: String
    private let account: String

    init(service: String = "world.madhans.klick.sharedkey", account: String = "default") {
        self.service = service
        self.account = account
    }

    convenience init(forChannel channelId: String) {
        self.init(account: "channel:\(channelId)")
    }

    func save(_ key: Data) throws {
        // Delete any existing entry first; SecItemAdd fails with duplicate if present.
        let delQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(delQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.osStatus(status) }
    }

    func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError.osStatus(status) }
        guard let data = item as? Data else { throw KeyStoreError.invalidItem }
        return data
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.osStatus(status)
        }
    }
}
