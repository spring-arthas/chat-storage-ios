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

    func testLoadCachedFriendsPublishesBeforeRemoteRefresh() async {
        let cached = ChatFriend.fixture(friendId: 5, name: "Cached")
        let repository = MessagesFriendRepository(friends: [], cachedFriends: [cached])
        let model = MessagesViewModel(repository: repository)

        await model.loadCached()

        XCTAssertEqual(model.friends, [cached])
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

    func testIncomingMessageIncrementsUnreadAndUpdatesLatestPreview() {
        let model = MessagesViewModel(
            repository: MessagesFriendRepository(friends: []),
            initialFriends: [.fixture(friendId: 9, name: "好友", unread: 2)]
        )

        // [修改] 关闭的会话收到对方消息时，列表直接更新摘要和未读角标。
        model.apply(
            .message(ChatMessage(messageId: 91, senderId: 9, receiverId: 7, content: "push", clientMsgId: "push-91")),
            currentUserId: 7
        )

        XCTAssertEqual(model.friends[0].latestMessage, "push")
        XCTAssertEqual(model.friends[0].unreadCount, 3)
    }

    // [修改] MIXED 消息摘要不能把附件 JSON 原样显示在好友列表。
    func testMixedMessageUsesReadableAttachmentSummary() throws {
        let model = MessagesViewModel(
            repository: MessagesFriendRepository(friends: []),
            initialFriends: [.fixture(friendId: 9, name: "好友")]
        )
        let content = ChatMixedMessageContent(
            text: "旅行资料",
            attachments: [
                ChatAttachment(fileId: 101, fileName: "photo.jpg", fileSize: 10, mimeType: "image/jpeg"),
                ChatAttachment(fileId: 102, fileName: "guide.pdf", fileSize: 20, mimeType: "application/pdf"),
            ]
        )
        let payload = String(decoding: try ProtocolJSON.encoder().encode(content), as: UTF8.self)

        model.apply(
            .message(ChatMessage(messageId: 95, senderId: 9, receiverId: 7, content: payload, msgType: "MIXED")),
            currentUserId: 7
        )

        XCTAssertEqual(model.friends[0].latestMessage, "旅行资料 [图片] [文件]")
    }

    // [修改] 消息 Tab 的角标来自所有好友未读数之和。
    func testTotalUnreadCountSumsEveryConversation() {
        let model = MessagesViewModel(
            repository: MessagesFriendRepository(friends: []),
            initialFriends: [
                .fixture(friendId: 9, name: "A", unread: 2),
                .fixture(friendId: 10, name: "B", unread: 5),
            ]
        )

        XCTAssertEqual(model.totalUnreadCount, 7)
    }

    func testReadEventClearsUnreadCount() {
        let model = MessagesViewModel(
            repository: MessagesFriendRepository(friends: []),
            initialFriends: [.fixture(friendId: 9, name: "好友", unread: 3)]
        )

        model.apply(.read(friendId: 9), currentUserId: 7)

        XCTAssertEqual(model.friends[0].unreadCount, 0)
    }

    // [修改] 好友关系推送不改未读数据，但必须通知页面立即刷新申请红点和好友列表。
    func testFriendRelationshipEventRequestsFriendshipRefresh() {
        let model = MessagesViewModel(
            repository: MessagesFriendRepository(friends: []),
            initialFriends: [.fixture(friendId: 9, name: "好友", unread: 2)]
        )

        let effect = model.apply(
            .friendRelationshipChanged(FriendRelationshipEvent(
                event: "REQUEST_CREATED",
                requestId: 31,
                actorUserId: 9
            )),
            currentUserId: 7
        )

        XCTAssertEqual(effect, .refreshFriendship)
        XCTAssertEqual(model.friends[0].unreadCount, 2)
    }

    func testOutgoingEchoUpdatesPreviewWithoutIncreasingUnread() {
        let model = MessagesViewModel(
            repository: MessagesFriendRepository(friends: []),
            initialFriends: [.fixture(friendId: 9, name: "好友", unread: 2)]
        )

        model.apply(
            .message(ChatMessage(messageId: 92, senderId: 7, receiverId: 9, content: "sent", clientMsgId: "sent-92")),
            currentUserId: 7
        )

        XCTAssertEqual(model.friends[0].latestMessage, "sent")
        XCTAssertEqual(model.friends[0].unreadCount, 2)
    }

    func testDuplicateMessageEventDoesNotIncreaseUnreadTwice() {
        let model = MessagesViewModel(
            repository: MessagesFriendRepository(friends: []),
            initialFriends: [.fixture(friendId: 9, name: "好友", unread: 0)]
        )
        let message = ChatMessage(messageId: 93, senderId: 9, receiverId: 7, content: "once", clientMsgId: "push-93")

        model.apply(.message(message), currentUserId: 7)
        model.apply(.message(message), currentUserId: 7)

        XCTAssertEqual(model.friends[0].unreadCount, 1)
    }

    // [修改] 慢刷新返回旧快照时，不能覆盖刷新期间刚收到的摘要和未读数量。
    func testRefreshPreservesRealtimeMessageReceivedWhileRequestIsInFlight() async {
        let serverFriend = ChatFriend.fixture(friendId: 9, name: "好友", unread: 2)
        let repository = MessagesFriendRepository(friends: [serverFriend], delay: .milliseconds(100))
        let model = MessagesViewModel(repository: repository, initialFriends: [serverFriend])

        let refresh = Task { await model.refresh() }
        try? await Task.sleep(for: .milliseconds(20))
        model.apply(
            .message(ChatMessage(messageId: 94, senderId: 9, receiverId: 7, content: "刷新期间的新消息")),
            currentUserId: 7
        )
        await refresh.value

        XCTAssertEqual(model.friends[0].latestMessage, "刷新期间的新消息")
        XCTAssertEqual(model.friends[0].unreadCount, 3)
    }
}

private actor MessagesFriendRepository: FriendRepository {
    let friends: [ChatFriend]
    let delay: Duration?
    let pinResult: Result<FriendPinState, Error>
    let cachedFriends: [ChatFriend]

    init(
        friends: [ChatFriend],
        delay: Duration? = nil,
        pinResult: Result<FriendPinState, Error> = .success(FriendPinState(relationshipId: 1, isPinned: true, pinnedAt: 1)),
        cachedFriends: [ChatFriend] = []
    ) {
        self.friends = friends
        self.delay = delay
        self.pinResult = pinResult
        self.cachedFriends = cachedFriends
    }

    func refresh() async throws -> [ChatFriend] {
        if let delay { try await Task.sleep(for: delay) }
        return friends
    }

    func updatePin(relationshipId: Int64, pinned: Bool) async throws -> FriendPinState {
        try pinResult.get()
    }

    func cachedFriends() async -> [ChatFriend] { cachedFriends }
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
