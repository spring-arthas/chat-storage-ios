import Foundation

protocol CurrentUserIDProviding: Sendable {
    func currentUserId() -> Int64?
}

struct SecureCurrentUserIDProvider: CurrentUserIDProviding {
    private let secureStore: any SecureStore

    init(secureStore: any SecureStore) {
        self.secureStore = secureStore
    }

    func currentUserId() -> Int64? {
        guard let data = try? secureStore.data(for: .currentUser) else { return nil }
        return try? ProtocolJSON.decoder().decode(AuthenticatedUser.self, from: data).id
    }
}
