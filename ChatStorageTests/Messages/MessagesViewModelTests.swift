import XCTest
@testable import ChatStorage

@MainActor
final class MessagesViewModelTests: XCTestCase {
    func testConversationsSortPinnedFirstByNewestPinTime() {
        let repository = MessagesFriendRepository(friends: [])
        let model = MessagesViewModel(repository: repository, initialFriends: [
            .fixture(friendId: 1, name: "A", unread: 8),
            .fixture(friendId: 2, name: "B", pinned: true, pinnedAt: 100),
            .fixture(friendId: 3, name: "C", pinned: true, pinnedAt: 200),
        ])

        XCTAssertEqual(model.visibleFriends.map(\.friendId), [3, 2, 1])
    }

    func testSearchMatchesAliasNicknameAndUsername() {
        let model = MessagesViewModel(repository: MessagesFriendRepository(friends: []), initialFriends: [
            ChatFriend(relationshipId: 1, userId: 10, friendId: 2, alias: "设计师", username: "alice", nickname: "Alice"),
            ChatFriend(relationshipId: 2, userId: 10, friendId: 3, username: "bob", nickname: "小博"),
        ])

        model.searchText = "alice"

        XCTAssertEqual(model.visibleFriends.map(\.friendId), [2])
    }

    func testRefreshPublishesLoadingAndReplacesRows() async {
        let repository = MessagesFriendRepository(friends: [.fixture(friendId: 9, name: "New")], delay: .milliseconds(50))
        let model = MessagesViewModel(repository: repository, initialFriends: [.fixture(friendId: 1, name: "Old")])

        let task = Task { await model.refresh() }
        await Task.yield()
        XCTAssertTrue(model.isRefreshing)
        await task.value

        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.friends.map(\.friendId), [9])
    }

    func testPinSuccessAppliesCanonicalStateAndReorders() async {
        let repository = MessagesFriendRepository(
            friends: [],
            pinResult: .success(FriendPinState(relationshipId: 11, isPinned: true, pinnedAt: 500))
        )
        let first = ChatFriend.fixture(relationshipId: 11, friendId: 1, name: "A")
        let second = ChatFriend.fixture(relationshipId: 12, friendId: 2, name: "B")
        let model = MessagesViewModel(repository: repository, initialFriends: [first, second])

        await model.togglePin(first)

        XCTAssertTrue(model.friends.first(where: { $0.friendId == 1 })?.isPinned == true)
        XCTAssertEqual(model.visibleFriends.first?.friendId, 1)
    }

    func testPinFailureKeepsOriginalStateAndShowsError() async {
        let repository = MessagesFriendRepository(
            friends: [],
            pinResult: .failure(FriendRepositoryError.server(message: "置顶失败", code: nil))
        )
        let friend = ChatFriend.fixture(relationshipId: 11, friendId: 1, name: "A")
        let model = MessagesViewModel(repository: repository, initialFriends: [friend])

        await model.togglePin(friend)

        XCTAssertFalse(model.friends[0].isPinned)
        XCTAssertEqual(model.errorMessage, "置顶失败")
    }
}

private actor MessagesFriendRepository: FriendRepository {
    let friends: [ChatFriend]
    let delay: Duration?
    let pinResult: Result<FriendPinState, Error>

    init(
        friends: [ChatFriend],
        delay: Duration? = nil,
        pinResult: Result<FriendPinState, Error> = .success(FriendPinState(relationshipId: 1, isPinned: true, pinnedAt: 1))
    ) {
        self.friends = friends
        self.delay = delay
        self.pinResult = pinResult
    }

    func refresh() async throws -> [ChatFriend] {
        if let delay { try await Task.sleep(for: delay) }
        return friends
    }

    func updatePin(relationshipId: Int64, pinned: Bool) async throws -> FriendPinState {
        try pinResult.get()
    }
}

private extension ChatFriend {
    static func fixture(
        relationshipId: Int64? = nil,
        friendId: Int64,
        name: String,
        unread: Int = 0,
        pinned: Bool = false,
        pinnedAt: Int64? = nil
    ) -> ChatFriend {
        ChatFriend(
            relationshipId: relationshipId ?? friendId + 10,
            userId: 100,
            friendId: friendId,
            username: name,
            unreadCount: unread,
            latestMessage: "最新消息",
            isPinned: pinned,
            pinnedAt: pinnedAt
        )
    }
}
