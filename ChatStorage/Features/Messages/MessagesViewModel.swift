import Foundation
import Observation

enum MessagesEventEffect: Equatable {
    case none
    case refreshFriendship
}

@MainActor
@Observable
final class MessagesViewModel {
    private(set) var friends: [ChatFriend]
    var searchText = ""
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var pinningRelationshipIDs: Set<Int64> = []

    private let repository: any FriendRepository
    private var appliedMessageIDs: Set<String> = []
    private var conversationVersions: [Int64: Int] = [:]

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

    // [修改] 消息 Tab 角标显示所有会话未读总数。
    var totalUnreadCount: Int {
        friends.reduce(0) { $0 + max($1.unreadCount, 0) }
    }

    func loadCached() async {
        guard friends.isEmpty else { return }
        let cached = await repository.cachedFriends()
        if !cached.isEmpty { friends = cached }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        let versionsAtRefreshStart = conversationVersions
        defer { isRefreshing = false }
        do {
            let refreshedFriends = try await repository.refresh()
            let currentFriends = Dictionary(friends.map { ($0.friendId, $0) }, uniquingKeysWith: { _, latest in latest })
            // [修改] 刷新期间发生过实时事件的会话保留本地摘要和未读数，其余资料采用服务端最新值。
            friends = refreshedFriends.map { refreshed in
                guard conversationVersions[refreshed.friendId, default: 0]
                        != versionsAtRefreshStart[refreshed.friendId, default: 0],
                      let current = currentFriends[refreshed.friendId] else {
                    return refreshed
                }
                return refreshed.applying(
                    latestMessage: current.latestMessage,
                    unreadCount: current.unreadCount
                )
            }
        } catch {
            if friends.isEmpty { errorMessage = Self.message(for: error, fallback: "好友列表刷新失败") }
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

    // [修改] 好友列表直接消费广播事件，实时更新摘要和未读数，不再为每条推送重拉整表。
    @discardableResult
    func apply(_ event: ChatEvent, currentUserId: Int64) -> MessagesEventEffect {
        switch event {
        case .messageAction:
            return .none
        case .read(let friendId):
            guard let index = friends.firstIndex(where: { $0.friendId == friendId }) else { return .none }
            conversationVersions[friendId, default: 0] += 1
            friends[index] = friends[index].applying(
                latestMessage: friends[index].latestMessage,
                unreadCount: 0
            )
            return .none
        case .message(let message):
            guard appliedMessageIDs.insert(message.id).inserted else { return .none }
            let friendId = message.senderId == currentUserId ? message.receiverId : message.senderId
            guard let index = friends.firstIndex(where: { $0.friendId == friendId }) else { return .none }
            let isIncoming = message.senderId != currentUserId
            conversationVersions[friendId, default: 0] += 1
            friends[index] = friends[index].applying(
                latestMessage: message.conversationSummary,
                unreadCount: friends[index].unreadCount + (isIncoming ? 1 : 0)
            )
            return .none
        case .friendRelationshipChanged:
            // [修改] 关系事件本身不猜本地好友状态，通知页面重拉好友与待处理申请。
            return .refreshFriendship
        }
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

    // [修改] ChatFriend 是值类型，通过重建单行保持头像、别名和置顶状态不丢失。
    func applying(latestMessage: String?, unreadCount: Int) -> ChatFriend {
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
            isPinned: isPinned,
            pinnedAt: pinnedAt
        )
    }
}
