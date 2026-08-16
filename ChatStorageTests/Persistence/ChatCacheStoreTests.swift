import XCTest
@testable import ChatStorage

final class ChatCacheStoreTests: XCTestCase {
    // [修改] 构造应用容器时不能同步读取大缓存；第一次真正访问缓存时才加载一次。
    func testCacheFileLoadsLazilyOnFirstAccess() async {
        let loader = ChatCacheDataLoaderSpy()
        let store = ChatCacheStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            dataLoader: loader.load
        )

        XCTAssertEqual(loader.loadCount, 0)

        _ = await store.friends(userId: 7)
        XCTAssertEqual(loader.loadCount, 1)

        _ = await store.friends(userId: 8)
        XCTAssertEqual(loader.loadCount, 1)
    }

    func testFriendsAndMessagesPersistWithAccountIsolation() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        // [修改] 覆盖本地 Codable 字段名，防止在线和置顶状态重启后丢失。
        let firstFriend = ChatFriend(
            relationshipId: 1,
            userId: 7,
            friendId: 9,
            username: "alice",
            isOnline: true,
            isPinned: true,
            pinnedAt: 99
        )
        let secondFriend = ChatFriend(relationshipId: 2, userId: 8, friendId: 10, username: "bob")

        try await store.saveFriends([firstFriend], userId: 7)
        try await store.saveFriends([secondFriend], userId: 8)
        try await store.mergeMessages([ChatMessage(messageId: 11, senderId: 9, receiverId: 7, content: "hello")], userId: 7, friendId: 9)

        let restored = ChatCacheStore(fileURL: fileURL)
        // [修改] XCTest 断言使用同步自动闭包，异步读取必须先完成再断言。
        let firstFriends = await restored.friends(userId: 7)
        let secondFriends = await restored.friends(userId: 8)
        let firstHistory = await restored.history(userId: 7, friendId: 9, beforeMessageId: nil, limit: 20)
        let isolatedHistory = await restored.history(userId: 8, friendId: 9, beforeMessageId: nil, limit: 20)

        XCTAssertEqual(firstFriends, [firstFriend])
        XCTAssertEqual(secondFriends, [secondFriend])
        XCTAssertEqual(firstHistory?.messages.map(\.content), ["hello"])
        XCTAssertNil(isolatedHistory)
    }

    func testMessageFoundationFieldsPersistAcrossRestart() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        let message = ChatMessage(
            messageId: 12,
            senderId: 9,
            receiverId: 7,
            content: "hello",
            conversationSeq: 34,
            senderDeviceId: "device-a",
            encryptionMode: "SERVER_MANAGED",
            keyId: "k1"
        )
        try await store.mergeMessages([message], userId: 7, friendId: 9)

        let restored = ChatCacheStore(fileURL: fileURL)
        let history = await restored.history(userId: 7, friendId: 9, beforeMessageId: nil, limit: 20)

        let persisted = try XCTUnwrap(history?.messages.first)
        XCTAssertEqual(persisted.conversationSeq, 34)
        XCTAssertEqual(persisted.senderDeviceId, "device-a")
        XCTAssertEqual(persisted.encryptionMode, "SERVER_MANAGED")
        XCTAssertEqual(persisted.keyId, "k1")
    }

    // [修改] 两台服务器即使返回相同 userId，也不能读取彼此的好友和消息缓存。
    func testServerScopedStoresDoNotShareCachedFriends() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstConfiguration = try ServerConfiguration(host: "server-a.example")
        let secondConfiguration = try ServerConfiguration(host: "server-b.example")
        let firstStore = ChatCacheStore.serverScoped(configuration: firstConfiguration, rootURL: root)
        let secondStore = ChatCacheStore.serverScoped(configuration: secondConfiguration, rootURL: root)
        let friend = ChatFriend(relationshipId: 1, userId: 7, friendId: 9, username: "alice")

        try await firstStore.saveFriends([friend], userId: 7)

        let firstFriends = await firstStore.friends(userId: 7)
        let secondFriends = await secondStore.friends(userId: 7)
        XCTAssertEqual(firstFriends, [friend])
        XCTAssertTrue(secondFriends.isEmpty)
    }

    // [修改] 发送回执和后续服务端历史即使 clientMsgId 字段不同，也只能缓存一条消息。
    func testMergeMessagesDeduplicatesByServerMessageID() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        let sent = ChatMessage(
            messageId: 42,
            senderId: 7,
            receiverId: 9,
            content: "hello",
            clientMsgId: "client-42",
            createdAt: 100,
            isMine: true
        )
        let history = ChatMessage(
            messageId: 42,
            senderId: 7,
            receiverId: 9,
            content: "hello",
            clientMsgId: nil,
            createdAt: 100,
            isMine: true
        )

        try await store.mergeMessages([sent], userId: 7, friendId: 9)
        try await store.mergeMessages([history], userId: 7, friendId: 9)

        let page = await store.history(userId: 7, friendId: 9, beforeMessageId: nil, limit: 20)
        XCTAssertEqual(page?.messages.count, 1)
        XCTAssertEqual(page?.messages.first?.messageId, 42)
    }

    // [修改] 推送消息必须在一次持久化中同步更新摘要和未读数，重复推送不能重复计数。
    func testRecordIncomingMessageUpdatesFriendSummaryAndUnreadExactlyOnce() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        let friend = ChatFriend(
            relationshipId: 1,
            userId: 7,
            friendId: 9,
            username: "alice",
            unreadCount: 2,
            latestMessage: "旧消息"
        )
        let message = ChatMessage(
            messageId: 88,
            senderId: 9,
            receiverId: 7,
            content: "新消息"
        )
        try await store.saveFriends([friend], userId: 7)

        try await store.recordConversationMessage(message, userId: 7, friendId: 9, incrementsUnread: true)
        try await store.recordConversationMessage(message, userId: 7, friendId: 9, incrementsUnread: true)

        let restored = ChatCacheStore(fileURL: fileURL)
        let cachedFriend = await restored.friends(userId: 7).first
        let history = await restored.history(userId: 7, friendId: 9, beforeMessageId: nil, limit: 20)
        XCTAssertEqual(cachedFriend?.latestMessage, "新消息")
        XCTAssertEqual(cachedFriend?.unreadCount, 3)
        XCTAssertEqual(history?.messages.count, 1)
    }

    // [修改] 自己发送的附件消息只更新摘要，不增加未读数。
    func testRecordOutgoingMixedMessageUpdatesSummaryWithoutUnreadIncrement() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        let friend = ChatFriend(relationshipId: 1, userId: 7, friendId: 9, username: "alice", unreadCount: 4)
        let mixed = ChatMixedMessageContent(
            attachments: [
                ChatAttachment(fileId: 101, fileName: "a.jpg", fileSize: 10, mimeType: "image/jpeg"),
                ChatAttachment(fileId: 102, fileName: "b.jpg", fileSize: 10, mimeType: "image/jpeg"),
            ]
        )
        let payload = String(decoding: try ProtocolJSON.encoder().encode(mixed), as: UTF8.self)
        let message = ChatMessage(messageId: 89, senderId: 7, receiverId: 9, content: payload, msgType: "MIXED")
        try await store.saveFriends([friend], userId: 7)

        try await store.recordConversationMessage(message, userId: 7, friendId: 9, incrementsUnread: false)

        let cachedFriend = await store.friends(userId: 7).first
        XCTAssertEqual(cachedFriend?.latestMessage, "[图片]×2")
        XCTAssertEqual(cachedFriend?.unreadCount, 4)
    }

    // [修改] 本地删除必须同时按当前账号和好友隔离，相同 messageId 不能误删其他分区。
    func testDeleteMessageOnlyAffectsSelectedAccountConversation() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        let target = ChatMessage(messageId: 88, senderId: 9, receiverId: 7, content: "target")
        let otherAccount = ChatMessage(messageId: 88, senderId: 9, receiverId: 8, content: "other-account")
        let otherFriend = ChatMessage(messageId: 88, senderId: 10, receiverId: 7, content: "other-friend")
        try await store.mergeMessages([target], userId: 7, friendId: 9)
        try await store.mergeMessages([otherAccount], userId: 8, friendId: 9)
        try await store.mergeMessages([otherFriend], userId: 7, friendId: 10)

        try await store.deleteMessage(messageID: target.id, userId: 7, friendId: 9)

        let deletedHistory = await store.history(userId: 7, friendId: 9, beforeMessageId: nil, limit: 20)
        let otherAccountHistory = await store.history(userId: 8, friendId: 9, beforeMessageId: nil, limit: 20)
        let otherFriendHistory = await store.history(userId: 7, friendId: 10, beforeMessageId: nil, limit: 20)
        XCTAssertNil(deletedHistory)
        XCTAssertEqual(otherAccountHistory?.messages.map(\.content), ["other-account"])
        XCTAssertEqual(otherFriendHistory?.messages.map(\.content), ["other-friend"])
    }

    // [修改] 清空只删除当前会话，本地其他好友和其他账号的历史必须保留。
    func testClearConversationOnlyRemovesSelectedPartition() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        try await store.mergeMessages([ChatMessage(messageId: 1, senderId: 9, receiverId: 7, content: "target")], userId: 7, friendId: 9)
        try await store.mergeMessages([ChatMessage(messageId: 2, senderId: 10, receiverId: 7, content: "keep")], userId: 7, friendId: 10)
        try await store.mergeMessages([ChatMessage(messageId: 3, senderId: 9, receiverId: 8, content: "keep-account")], userId: 8, friendId: 9)

        try await store.clearConversation(userId: 7, friendId: 9)

        let clearedHistory = await store.history(userId: 7, friendId: 9, beforeMessageId: nil, limit: 20)
        let otherFriendHistory = await store.history(userId: 7, friendId: 10, beforeMessageId: nil, limit: 20)
        let otherAccountHistory = await store.history(userId: 8, friendId: 9, beforeMessageId: nil, limit: 20)
        XCTAssertNil(clearedHistory)
        XCTAssertEqual(otherFriendHistory?.messages.map(\.content), ["keep"])
        XCTAssertEqual(otherAccountHistory?.messages.map(\.content), ["keep-account"])
    }

    // [修改] 撤回动作保留原消息位置，只把内容状态改成撤回并持久化到磁盘。
    func testApplyRetractionPersistsMessageStateAndLatestSummary() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        let friend = ChatFriend(relationshipId: 1, userId: 7, friendId: 9, username: "alice", latestMessage: "原消息")
        let message = ChatMessage(messageId: 88, senderId: 7, receiverId: 9, content: "原消息", createdAt: 100)
        try await store.saveFriends([friend], userId: 7)
        try await store.mergeMessages([message], userId: 7, friendId: 9)

        try await store.applyMessageAction(
            ChatMessageAction(action: "RETRACT", messageId: 88, friendId: 9),
            userId: 7
        )

        let restored = ChatCacheStore(fileURL: fileURL)
        let retracted = await restored.history(userId: 7, friendId: 9, beforeMessageId: nil, limit: 20)?.messages.first
        let cachedFriend = await restored.friends(userId: 7).first
        XCTAssertTrue(retracted?.retracted == true)
        XCTAssertEqual(cachedFriend?.latestMessage, "[消息已撤回]")
    }

    // [修改] 收藏状态必须按账号持久化，并在服务端历史刷新后继续保留。
    func testFavoritePersistsAndSurvivesRemoteHistoryMerge() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        let original = ChatMessage(messageId: 88, senderId: 9, receiverId: 7, content: "收藏消息")
        try await store.mergeMessages([original], userId: 7, friendId: 9)

        try await store.setFavorite(messageID: original.id, isFavorite: true, userId: 7, friendId: 9)
        try await store.mergeMessages([original], userId: 7, friendId: 9)

        let restored = ChatCacheStore(fileURL: fileURL)
        let favorites = await restored.favoriteMessages(userId: 7)
        XCTAssertEqual(favorites.map(\.messageId), [88])
        XCTAssertTrue(favorites[0].isFavorite)
    }

    // [修改] 表情回应动作需要落盘，重新进入会话后仍显示每个表情的数量。
    func testReactionActionPersistsMergedUsers() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat-cache.json")
        let store = ChatCacheStore(fileURL: fileURL)
        try await store.mergeMessages(
            [ChatMessage(messageId: 88, senderId: 9, receiverId: 7, content: "回应消息")],
            userId: 7,
            friendId: 9
        )

        try await store.applyMessageAction(
            ChatMessageAction(action: "REACTION", messageId: 88, friendId: 9, reaction: ["❤️": [7, 9]]),
            userId: 7
        )

        let restored = ChatCacheStore(fileURL: fileURL)
        let message = await restored.history(userId: 7, friendId: 9, beforeMessageId: nil, limit: 20)?.messages.first
        XCTAssertEqual(message?.reactions, ["❤️": [7, 9]])
    }
}

private final class ChatCacheDataLoaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var loadCount: Int {
        lock.withLock { count }
    }

    func load(_ url: URL) -> Data? {
        lock.withLock { count += 1 }
        return nil
    }
}
