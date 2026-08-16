import Foundation

actor CachedChatRepository: ChatRepository {
    nonisolated private let eventBroadcaster = ChatEventBroadcaster()

    private let remote: any ChatRepository
    private let cache: ChatCacheStore
    private let identityProvider: any CurrentUserIDProviding
    private var listener: Task<Void, Never>?

    nonisolated var messages: AsyncStream<ChatMessage> {
        messageStream(from: eventStream())
    }

    nonisolated func eventStream() -> AsyncStream<ChatEvent> {
        eventBroadcaster.stream()
    }

    init(remote: any ChatRepository, cache: ChatCacheStore, identityProvider: any CurrentUserIDProviding) {
        self.remote = remote
        self.cache = cache
        self.identityProvider = identityProvider
        listener = nil
        Task { [weak self] in await self?.startListening() }
    }

    func cachedHistory(friendId: Int64, beforeMessageId: Int64?, limit: Int) async -> ChatHistoryPage? {
        guard let userId = identityProvider.currentUserId() else { return nil }
        return await cache.history(userId: userId, friendId: friendId, beforeMessageId: beforeMessageId, limit: limit)
    }

    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage {
        do {
            let page = try await remote.history(friendId: friendId, beforeMessageId: beforeMessageId, limit: limit)
            if let userId = identityProvider.currentUserId() {
                try? await cache.mergeMessages(page.messages, userId: userId, friendId: friendId)
            }
            return page
        } catch {
            if let cached = await cachedHistory(friendId: friendId, beforeMessageId: beforeMessageId, limit: limit) {
                return cached
            }
            throw error
        }
    }

    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt {
        try await send(friendId: friendId, content: content, messageType: "TEXT", clientMessageId: clientMessageId)
    }

    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String) async throws -> ChatReceipt {
        try await send(friendId: friendId, content: content, messageType: messageType, clientMessageId: clientMessageId, quote: nil)
    }

    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String, quote: ChatQuote?) async throws -> ChatReceipt {
        let receipt = try await remote.send(
            friendId: friendId,
            content: content,
            messageType: messageType,
            clientMessageId: clientMessageId,
            quote: quote
        )
        if let userId = identityProvider.currentUserId() {
            let message = ChatMessage(
                messageId: receipt.messageId,
                senderId: userId,
                receiverId: friendId,
                content: content,
                msgType: messageType,
                clientMsgId: clientMessageId,
                createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
                isMine: true,
                quote: quote
            )
            try? await cache.recordConversationMessage(
                message,
                userId: userId,
                friendId: friendId,
                incrementsUnread: false
            )
            // [修改] 服务端只推给接收方；发送方用本地广播即时更新好友摘要和其他已打开页面。
            eventBroadcaster.yield(.message(message))
        }
        return receipt
    }

    func retract(messageId: Int64, friendId: Int64) async throws {
        try await remote.retract(messageId: messageId, friendId: friendId)
        if let userId = identityProvider.currentUserId() {
            try await cache.applyMessageAction(
                ChatMessageAction(action: "RETRACT", messageId: messageId, friendId: friendId),
                userId: userId
            )
        }
    }

    func react(messageId: Int64, friendId: Int64, emoji: String) async throws -> ChatMessageAction {
        let action = try await remote.react(messageId: messageId, friendId: friendId, emoji: emoji)
        if let userId = identityProvider.currentUserId() {
            try await cache.applyMessageAction(action, userId: userId)
        }
        return action
    }

    func setFavorite(message: ChatMessage, isFavorite: Bool, friendId: Int64) async throws {
        guard let userId = identityProvider.currentUserId() else { return }
        try await cache.setFavorite(
            messageID: message.id,
            isFavorite: isFavorite,
            userId: userId,
            friendId: friendId
        )
    }

    func favoriteMessages() async -> [ChatMessage] {
        guard let userId = identityProvider.currentUserId() else { return [] }
        return await cache.favoriteMessages(userId: userId)
    }

    // [修改] 转发使用现有聊天发送链路，同时在发送方本地缓存保留“转发自”来源。
    func forward(message: ChatMessage, to friendId: Int64, sourceName: String) async throws {
        let clientMessageId = UUID().uuidString
        let receipt = try await remote.send(
            friendId: friendId,
            content: message.conversationSummary,
            messageType: "TEXT",
            clientMessageId: clientMessageId,
            quote: nil
        )
        guard let userId = identityProvider.currentUserId() else { return }
        let forwarded = ChatMessage(
            messageId: receipt.messageId,
            senderId: userId,
            receiverId: friendId,
            content: message.conversationSummary,
            clientMsgId: clientMessageId,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
            isMine: true,
            forwardFrom: sourceName
        )
        try await cache.recordConversationMessage(
            forwarded,
            userId: userId,
            friendId: friendId,
            incrementsUnread: false
        )
        eventBroadcaster.yield(.message(forwarded))
    }

    func deleteLocal(message: ChatMessage, friendId: Int64) async throws {
        guard let userId = identityProvider.currentUserId() else { return }
        try await cache.deleteMessage(messageID: message.id, userId: userId, friendId: friendId)
    }

    func clearLocalConversation(friendId: Int64) async throws {
        guard let userId = identityProvider.currentUserId() else { return }
        try await cache.clearConversation(userId: userId, friendId: friendId)
    }

    func markRead(friendId: Int64) async throws {
        do {
            try await remote.markRead(friendId: friendId)
        } catch {
            if let userId = identityProvider.currentUserId() { try? await cache.markRead(userId: userId, friendId: friendId) }
            throw error
        }
        if let userId = identityProvider.currentUserId() { try? await cache.markRead(userId: userId, friendId: friendId) }
    }

    func searchMessages(friendId: Int64?, keyword: String, limit: Int) async throws -> [ChatMessage] {
        try await remote.searchMessages(friendId: friendId, keyword: keyword, limit: limit)
    }

    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] { try await remote.searchUsers(keyword: keyword) }
    func addFriend(userId: Int64, message: String) async throws { try await remote.addFriend(userId: userId, message: message) }
    func pendingRequests() async throws -> [FriendRequestItem] { try await remote.pendingRequests() }
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws {
        try await remote.handleFriendRequest(requestId: requestId, accept: accept, alias: alias)
    }

    func updateAlias(relationshipId: Int64, alias: String) async throws {
        try await remote.updateAlias(relationshipId: relationshipId, alias: alias)
        if let userId = identityProvider.currentUserId() {
            try? await cache.applyAlias(relationshipId: relationshipId, alias: alias, userId: userId)
        }
    }

    private func startListening() {
        guard listener == nil else { return }
        listener = Task { [weak self, stream = remote.eventStream()] in
            for await event in stream {
                await self?.receive(event)
            }
        }
    }

    private func receive(_ event: ChatEvent) async {
        if let userId = identityProvider.currentUserId() {
            switch event {
            case .message(let message):
                let friendId = message.senderId == userId ? message.receiverId : message.senderId
                try? await cache.recordConversationMessage(
                    message,
                    userId: userId,
                    friendId: friendId,
                    incrementsUnread: message.senderId != userId
                )
            case .read(let friendId):
                try? await cache.markRead(userId: userId, friendId: friendId)
            case .messageAction(let action):
                try? await cache.applyMessageAction(action, userId: userId)
            case .friendRelationshipChanged:
                // [修改] 好友关系主数据由好友接口刷新，缓存仓库只负责原样转播事件。
                break
            }
        }
        // [修改] 缓存层也必须广播同一事件，不能重新退化为单消费者队列。
        eventBroadcaster.yield(event)
    }
}
