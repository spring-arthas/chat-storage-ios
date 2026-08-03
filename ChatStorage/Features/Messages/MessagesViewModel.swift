import Foundation
import Observation

@MainActor
@Observable
final class MessagesViewModel {
    private(set) var friends: [ChatFriend]
    var searchText = ""
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var pinningRelationshipIDs: Set<Int64> = []

    private let repository: any FriendRepository

    init(repository: any FriendRepository, initialFriends: [ChatFriend] = []) {
        self.repository = repository
        self.friends = initialFriends
    }

    var visibleFriends: [ChatFriend] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? friends : friends.filter { friend in
            [friend.alias, friend.nickname, friend.username, friend.latestMessage]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return filtered.sorted(by: Self.conversationOrder)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            friends = try await repository.refresh()
        } catch {
            errorMessage = Self.message(for: error, fallback: "好友列表刷新失败")
        }
    }

    func togglePin(_ friend: ChatFriend) async {
        guard !pinningRelationshipIDs.contains(friend.relationshipId) else { return }
        pinningRelationshipIDs.insert(friend.relationshipId)
        errorMessage = nil
        defer { pinningRelationshipIDs.remove(friend.relationshipId) }
        do {
            let state = try await repository.updatePin(
                relationshipId: friend.relationshipId,
                pinned: !friend.isPinned
            )
            guard let index = friends.firstIndex(where: { $0.relationshipId == state.relationshipId }) else { return }
            friends[index] = friends[index].applying(pin: state)
        } catch {
            errorMessage = Self.message(for: error, fallback: "置顶操作失败")
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func isUpdatingPin(for friend: ChatFriend) -> Bool {
        pinningRelationshipIDs.contains(friend.relationshipId)
    }

    private static func conversationOrder(_ left: ChatFriend, _ right: ChatFriend) -> Bool {
        if left.isPinned != right.isPinned { return left.isPinned && !right.isPinned }
        if left.isPinned, left.pinnedAt != right.pinnedAt {
            return (left.pinnedAt ?? .min) > (right.pinnedAt ?? .min)
        }
        if left.unreadCount != right.unreadCount { return left.unreadCount > right.unreadCount }
        return left.friendId < right.friendId
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}

private extension ChatFriend {
    func applying(pin state: FriendPinState) -> ChatFriend {
        ChatFriend(
            relationshipId: relationshipId,
            userId: userId,
            friendId: friendId,
            alias: alias,
            username: username,
            nickname: nickname,
            avatar: avatar,
            unreadCount: unreadCount,
            latestMessage: latestMessage,
            isOnline: isOnline,
            isPinned: state.isPinned,
            pinnedAt: state.pinnedAt
        )
    }
}
