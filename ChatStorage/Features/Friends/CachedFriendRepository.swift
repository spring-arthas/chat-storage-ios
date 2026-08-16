import Foundation

actor CachedFriendRepository: FriendRepository {
    private let remote: any FriendRepository
    private let cache: ChatCacheStore
    private let identityProvider: any CurrentUserIDProviding

    init(remote: any FriendRepository, cache: ChatCacheStore, identityProvider: any CurrentUserIDProviding) {
        self.remote = remote
        self.cache = cache
        self.identityProvider = identityProvider
    }

    func cachedFriends() async -> [ChatFriend] {
        guard let userId = identityProvider.currentUserId() else { return [] }
        return await cache.friends(userId: userId)
    }

    func refresh() async throws -> [ChatFriend] {
        do {
            let userId = identityProvider.currentUserId()
            let baselineFriends: [ChatFriend]
            if let userId {
                baselineFriends = await cache.friends(userId: userId)
            } else {
                baselineFriends = []
            }
            let friends = try await remote.refresh()
            if let userId,
               let merged = try? await cache.saveRefreshedFriends(
                   friends,
                   userId: userId,
                   baselineFriends: baselineFriends
               ) {
                return merged
            }
            return friends
        } catch {
            let cached = await cachedFriends()
            if !cached.isEmpty { return cached }
            throw error
        }
    }

    func updatePin(relationshipId: Int64, pinned: Bool) async throws -> FriendPinState {
        let state = try await remote.updatePin(relationshipId: relationshipId, pinned: pinned)
        if let userId = identityProvider.currentUserId() { try? await cache.applyPin(state, userId: userId) }
        return state
    }
}
