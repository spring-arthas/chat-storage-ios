import Foundation
import Security

enum KeychainSecureStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case unexpectedData
}

final class KeychainSecureStore: SecureStore, @unchecked Sendable {
    private let service: String

    init(service: String = "com.alibaba.chatstorage.ios") {
        self.service = service
    }

    func data(for key: SecureStoreKey) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainSecureStoreError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainSecureStoreError.unexpectedData }
        return data
    }

    func set(_ data: Data, for key: SecureStoreKey) throws {
        let query = baseQuery(for: key)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainSecureStoreError.unexpectedStatus(updateStatus)
        }
        var addition = query
        addition.merge(update) { _, new in new }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSecureStoreError.unexpectedStatus(addStatus)
        }
    }

    func remove(_ key: SecureStoreKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecureStoreError.unexpectedStatus(status)
        }
    }

    func removeAll() throws {
        for key in SecureStoreKey.allCases {
            try remove(key)
        }
    }

    private func baseQuery(for key: SecureStoreKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
