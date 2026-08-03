import Foundation

protocol SecureStore: Sendable {
    func data(for key: SecureStoreKey) throws -> Data?
    func set(_ data: Data, for key: SecureStoreKey) throws
    func remove(_ key: SecureStoreKey) throws
}

enum SecureStoreKey: String, CaseIterable, Sendable {
    case sessionToken
    case transferToken
    case currentUser
}
