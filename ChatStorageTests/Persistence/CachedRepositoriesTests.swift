import XCTest
@testable import ChatStorage

final class CachedRepositoriesTests: XCTestCase {
    func testFriendRefreshFallsBackToAccountCache() async throws {
        let cache = ChatCacheStore(fileURL: temporaryCacheURL())
        let friend = ChatFriend(relationshipId: 4, userId: 7, friendId: 9, username: "cached")
        try await cache.saveFriends([friend], userId: 7)
        let repository = CachedFriendRepository(
            remote: OfflineFriendRepository(),
            cache: cache,
            identityProvider: StaticCurrentUserIDProvider(userId: 7)
        )

        let friends = try await repository.refresh()
        // [修改] 先跨 actor 读取缓存结果，避免在 XCTest 自动闭包里直接 await。
        let cachedFriends = await repository.cachedFriends()

        XCTAssertEqual(friends, [friend])
        XCTAssertEqual(cachedFriends, [friend])
    }

    // [修改] 好友刷新在途时写入的实时摘要和未读数，不能被旧服务端快照覆盖到磁盘缓存。
    func testFriendRefreshPreservesRealtimeConversationCacheWrittenInFlight() async throws {
        let cache = ChatCacheStore(fileURL: temporaryCacheURL())
        let serverFriend = ChatFriend(
            relationshipId: 4,
            userId: 7,
            friendId: 9,
            username: "alice",
            unreadCount: 2,
            latestMessage: "旧消息"
        )
        try await cache.saveFriends([serverFriend], userId: 7)
        let repository = CachedFriendRepository(
            remote: DelayedFriendRepository(friends: [serverFriend], delay: .milliseconds(100)),
            cache: cache,
            identityProvider: StaticCurrentUserIDProvider(userId: 7)
        )

        let refreshTask = Task { try await repository.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        try await cache.recordConversationMessage(
            ChatMessage(messageId: 91, senderId: 9, receiverId: 7, content: "刷新期间的新消息"),
            userId: 7,
            friendId: 9,
            incrementsUnread: true
        )

        let refreshed = try await refreshTask.value
        let cached = await repository.cachedFriends()
        XCTAssertEqual(refreshed.first?.latestMessage, "刷新期间的新消息")
        XCTAssertEqual(refreshed.first?.unreadCount, 3)
        XCTAssertEqual(cached.first?.latestMessage, "刷新期间的新消息")
        XCTAssertEqual(cached.first?.unreadCount, 3)
    }

    func testChatHistoryPersistsRemotePageAndFallsBackWhenOffline() async throws {
        let cache = ChatCacheStore(fileURL: temporaryCacheURL())
        let page = ChatHistoryPage(
            messages: [ChatMessage(messageId: 12, senderId: 9, receiverId: 7, content: "remote")],
            hasMore: false,
            nextBeforeMessageId: nil,
            latestMessageId: 12
        )
        let remote = SwitchingChatRepository(results: [.success(page), .failure(RequestResponseError.closed)])
        let repository = CachedChatRepository(
            remote: remote,
            cache: cache,
            identityProvider: StaticCurrentUserIDProvider(userId: 7)
        )

        _ = try await repository.history(friendId: 9, beforeMessageId: nil, limit: 20)
        let offlinePage = try await repository.history(friendId: 9, beforeMessageId: nil, limit: 20)
        // [修改] 先完成异步缓存读取，再比较离线回退结果。
        let cachedPage = await repository.cachedHistory(friendId: 9, beforeMessageId: nil, limit: 20)

        XCTAssertEqual(offlinePage.messages.map(\.content), ["remote"])
        XCTAssertEqual(cachedPage?.messages.map(\.content), ["remote"])
    }

    func testCachedChatRepositoryBroadcastsSameEventToEverySubscriber() async throws {
        let remote = BroadcastRemoteChatRepository()
        let repository = CachedChatRepository(
            remote: remote,
            cache: ChatCacheStore(fileURL: temporaryCacheURL()),
            identityProvider: StaticCurrentUserIDProvider(userId: 7)
        )
        let firstRecorder = CachedMessageRecorder()
        let secondRecorder = CachedMessageRecorder()
        let first = Task { await recordCachedMessageIDs(from: repository.eventStream(), expectedCount: 2, into: firstRecorder) }
        let second = Task { await recordCachedMessageIDs(from: repository.eventStream(), expectedCount: 2, into: secondRecorder) }

        // [修改] 等待真实订阅条件，避免用固定延时猜测 actor 调度速度。
        try await waitForCachedCondition("缓存仓库完成上游订阅") {
            remote.subscriptionCount == 1
        }

        // [修改] 连续两条消息可稳定暴露单 AsyncStream 被两个消费者分流的问题。
        remote.emit(ChatMessage(messageId: 91, senderId: 9, receiverId: 7, content: "first"))
        remote.emit(ChatMessage(messageId: 92, senderId: 9, receiverId: 7, content: "second"))

        try await waitForCachedCondition("两个缓存订阅者收到完整消息") {
            let firstIDs = await firstRecorder.messageIDs
            let secondIDs = await secondRecorder.messageIDs
            return firstIDs == [91, 92] && secondIDs == [91, 92]
        }
        first.cancel()
        second.cancel()
        await first.value
        await second.value
        let firstReceived = await firstRecorder.messageIDs
        let secondReceived = await secondRecorder.messageIDs
        XCTAssertEqual(firstReceived, [91, 92])
        XCTAssertEqual(secondReceived, [91, 92])
    }

    // [修改] 好友关系事件经过缓存仓库后仍要广播，消息页才能实时刷新申请红点。
    func testCachedChatRepositoryRebroadcastsFriendRelationshipEvent() async throws {
        let remote = BroadcastRemoteChatRepository()
        let repository = CachedChatRepository(
            remote: remote,
            cache: ChatCacheStore(fileURL: temporaryCacheURL()),
            identityProvider: StaticCurrentUserIDProvider(userId: 7)
        )
        let eventTask = Task { try await firstCachedFriendRelationshipEvent(from: repository.eventStream()) }

        try await waitForCachedCondition("缓存仓库完成好友事件订阅") {
            remote.subscriptionCount == 1
        }
        remote.emit(.friendRelationshipChanged(FriendRelationshipEvent(
            event: "REQUEST_CREATED",
            requestId: 31,
            actorUserId: 9
        )))

        let relationshipEvent = try await eventTask.value
        XCTAssertEqual(relationshipEvent.requestId, 31)
    }

    // [修改] 服务端只向接收方推送时，发送方仍要靠本地事件即时更新好友摘要。
    func testSuccessfulSendBroadcastsOutgoingMessage() async throws {
        let receipt = try ProtocolJSON.decoder().decode(
            ChatReceipt.self,
            from: Data(#"{"success":true,"data":{"messageId":88,"status":"SUCCESS","clientMsgId":"client-88"}}"#.utf8)
        )
        let repository = CachedChatRepository(
            remote: SuccessfulSendChatRepository(receipt: receipt),
            cache: ChatCacheStore(fileURL: temporaryCacheURL()),
            identityProvider: StaticCurrentUserIDProvider(userId: 7)
        )
        let eventTask = Task { try await firstCachedMessage(from: repository.eventStream()) }
        await Task.yield()

        _ = try await repository.send(friendId: 9, content: "我发出的消息", clientMessageId: "client-88")

        let message = try await eventTask.value
        XCTAssertEqual(message.messageId, 88)
        XCTAssertEqual(message.senderId, 7)
        XCTAssertEqual(message.receiverId, 9)
        XCTAssertEqual(message.content, "我发出的消息")
        XCTAssertTrue(message.isMine)
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("cache.json")
    }
}

private func recordCachedMessageIDs(
    from stream: AsyncStream<ChatEvent>,
    expectedCount: Int,
    into recorder: CachedMessageRecorder
) async {
    for await event in stream {
        if case .message(let message) = event {
            if await recorder.append(message.messageId) == expectedCount { break }
        }
    }
}

private func firstCachedMessage(from stream: AsyncStream<ChatEvent>) async throws -> ChatMessage {
    try await withThrowingTaskGroup(of: ChatMessage.self) { group in
        group.addTask {
            for await event in stream {
                if case .message(let message) = event { return message }
            }
            throw RequestResponseError.closed
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw CachedRepositoryTestTimeout(description: "发送成功后没有广播本地消息")
        }
        guard let message = try await group.next() else { throw RequestResponseError.closed }
        group.cancelAll()
        return message
    }
}

private func firstCachedFriendRelationshipEvent(
    from stream: AsyncStream<ChatEvent>
) async throws -> FriendRelationshipEvent {
    for await event in stream {
        if case .friendRelationshipChanged(let relationshipEvent) = event {
            return relationshipEvent
        }
    }
    throw RequestResponseError.closed
}

// [修改] 测试按事件数量等待，不依赖模拟器当前负载下的固定毫秒数。
private func waitForCachedCondition(
    _ description: String,
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CachedRepositoryTestTimeout(description: description)
}

private actor CachedMessageRecorder {
    private(set) var messageIDs: [Int64] = []

    @discardableResult
    func append(_ messageID: Int64) -> Int {
        messageIDs.append(messageID)
        return messageIDs.count
    }
}

private struct CachedRepositoryTestTimeout: Error, CustomStringConvertible {
    let description: String
}

private struct StaticCurrentUserIDProvider: CurrentUserIDProviding {
    let userId: Int64?
    func currentUserId() -> Int64? { userId }
}

private actor OfflineFriendRepository: FriendRepository {
    func refresh() async throws -> [ChatFriend] { throw RequestResponseError.closed }
    func updatePin(relationshipId: Int64, pinned: Bool) async throws -> FriendPinState { throw RequestResponseError.closed }
}

private actor DelayedFriendRepository: FriendRepository {
    let friends: [ChatFriend]
    let delay: Duration

    init(friends: [ChatFriend], delay: Duration) {
        self.friends = friends
        self.delay = delay
    }

    func refresh() async throws -> [ChatFriend] {
        try await Task.sleep(for: delay)
        return friends
    }

    func updatePin(relationshipId: Int64, pinned: Bool) async throws -> FriendPinState {
        throw RequestResponseError.closed
    }
}

private actor SwitchingChatRepository: ChatRepository {
    nonisolated let messages: AsyncStream<ChatMessage> = AsyncStream { $0.finish() }
    private var results: [Result<ChatHistoryPage, Error>]

    init(results: [Result<ChatHistoryPage, Error>]) { self.results = results }

    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage {
        try results.removeFirst().get()
    }

    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt { throw RequestResponseError.closed }
    func markRead(friendId: Int64) async throws { throw RequestResponseError.closed }
    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] { [] }
    func addFriend(userId: Int64, message: String) async throws {}
    func pendingRequests() async throws -> [FriendRequestItem] { [] }
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws {}
    func updateAlias(relationshipId: Int64, alias: String) async throws {}
}

private actor SuccessfulSendChatRepository: ChatRepository {
    nonisolated let messages: AsyncStream<ChatMessage> = AsyncStream { $0.finish() }
    private let receipt: ChatReceipt

    init(receipt: ChatReceipt) { self.receipt = receipt }

    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage {
        throw RequestResponseError.closed
    }
    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt { receipt }
    func markRead(friendId: Int64) async throws {}
    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] { [] }
    func addFriend(userId: Int64, message: String) async throws {}
    func pendingRequests() async throws -> [FriendRequestItem] { [] }
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws {}
    func updateAlias(relationshipId: Int64, alias: String) async throws {}
}

private actor BroadcastRemoteChatRepository: ChatRepository {
    nonisolated private let broadcaster = ChatEventBroadcaster()
    nonisolated private let subscriptions = CachedSubscriptionCounter()

    nonisolated var subscriptionCount: Int { subscriptions.value }

    nonisolated var messages: AsyncStream<ChatMessage> {
        let events = eventStream()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if case .message(let message) = event { continuation.yield(message) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func eventStream() -> AsyncStream<ChatEvent> {
        subscriptions.increment()
        return broadcaster.stream()
    }

    nonisolated func emit(_ message: ChatMessage) { broadcaster.yield(.message(message)) }
    nonisolated func emit(_ event: ChatEvent) { broadcaster.yield(event) }
    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage { throw RequestResponseError.closed }
    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt { throw RequestResponseError.closed }
    func markRead(friendId: Int64) async throws { broadcaster.yield(.read(friendId: friendId)) }
    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] { [] }
    func addFriend(userId: Int64, message: String) async throws {}
    func pendingRequests() async throws -> [FriendRequestItem] { [] }
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws {}
    func updateAlias(relationshipId: Int64, alias: String) async throws {}
}

private final class CachedSubscriptionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
