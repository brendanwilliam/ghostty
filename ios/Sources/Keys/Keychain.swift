import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Items are only readable
/// after the first unlock and never leave this device (no iCloud sync,
/// not included in backups restored to other devices).
enum Keychain {
    enum Error: Swift.Error {
        case unexpectedStatus(OSStatus)
    }

    private static let service = "com.mitchellh.ghostty.ios"

    static func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Error.unexpectedStatus(status)
        }
    }

    static func write(_ data: Data, for account: String) throws {
        let query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Error.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw Error.unexpectedStatus(status)
        }
    }

    static func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unexpectedStatus(status)
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
