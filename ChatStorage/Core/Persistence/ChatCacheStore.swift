import Foundation

actor ChatCacheStore {
    static let shared = ChatCacheStore(fileURL: defaultFileURL)

    // [修改] 正式缓存文件按服务器指纹分目录，旧全局缓存不会在切服后被读取。
    static func serverScoped(configuration: ServerConfiguration, rootURL: URL? = nil) -> ChatCacheStore {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChatStorage", isDirectory: true)
        let fileURL = root
            .appendingPathComponent("Servers", isDirectory: true)
            .appendingPathComponent(configuration.storageScopeID, isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("chat-cache.json")
        return ChatCacheStore(fileURL: fileURL)
    }

    private struct Snapshot: Codable {
        var friendsByUser: [String: [ChatFriend]] = [:]
        var messagesByConversation: [String: [ChatMessage]] = [:]
        var readCursorByConversation: [String: Int64] = [:]
    }

    private let fileURL: URL
    private let dataLoader: @Sendable (URL) -> Data?
    private var snapshot = Snapshot()
    private var didLoadSnapshot = false

    init(
        fileURL: URL,
        dataLoader: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) {
        self.fileURL = fileURL
        self.dataLoader = dataLoader
    }

    func friends(userId: Int64) -> [ChatFriend] {
        loadSnapshotIfNeeded()
        return snapshot.friendsByUser[String(userId)] ?? []
    }

    // [修改] 好友与消息缓存按当前账号分区，避免同一设备多账号串数据。
    func saveFriends(_ friends: [ChatFriend], userId: Int64) throws {
        loadSnapshotIfNeeded()
        snapshot.friendsByUser[String(userId)] = friends
        try persist()
    }

    // [修改] 远端刷新返回旧快照时，原子保留请求期间已经写入缓存的实时摘要和未读数。
    func saveRefreshedFriends(
        _ friends: [ChatFriend],
        userId: Int64,
        baselineFriends: [ChatFriend]
    ) throws -> [ChatFriend] {
        loadSnapshotIfNeeded()
        let key = String(userId)
        let baseline = Dictionary(baselineFriends.map { ($0.friendId, $0) }, uniquingKeysWith: { _, latest in latest })
        let current = Dictionary((snapshot.friendsByUser[key] ?? []).map { ($0.friendId, $0) }, uniquingKeysWith: { _, latest in latest })
        let merged = friends.map { refreshed in
            guard let before = baseline[refreshed.friendId],
                  let now = current[refreshed.friendId],
                  before.latestMessage != now.latestMessage || before.unreadCount != now.unreadCount else {
                return refreshed
            }
            return refreshed.withConversation(
                latestMessage: now.latestMessage,
                unreadCount: now.unreadCount
            )
        }
        snapshot.friendsByUser[key] = merged
        try persist()
        return merged
    }

    func applyPin(_ state: FriendPinState, userId: Int64) throws {
        loadSnapshotIfNeeded()
        let key = String(userId)
        guard let values = snapshot.friendsByUser[key],
              let index = values.firstIndex(where: { $0.relationshipId == state.relationshipId }) else { return }
        var updated = values
        updated[index] = updated[index].withPin(state)
        snapshot.friendsByUser[key] = updated
        try persist()
    }

    func applyAlias(relationshipId: Int64, alias: String, userId: Int64) throws {
        loadSnapshotIfNeeded()
        let key = String(userId)
        guard let values = snapshot.friendsByUser[key],
              let index = values.firstIndex(where: { $0.relationshipId == relationshipId }) else { return }
        var updated = values
        updated[index] = updated[index].withAlias(alias)
        snapshot.friendsByUser[key] = updated
        try persist()
    }

    func mergeMessages(_ messages: [ChatMessage], userId: Int64, friendId: Int64) throws {
        loadSnapshotIfNeeded()
        guard !messages.isEmpty else { return }
        _ = mergeMessagesInMemory(messages, userId: userId, friendId: friendId)
        try persist()
    }

    // [修改] 实时消息落盘、好友摘要和未读数量在同一个 actor 事务内完成，避免重启后列表状态回退。
    func recordConversationMessage(
        _ message: ChatMessage,
        userId: Int64,
        friendId: Int64,
        incrementsUnread: Bool
    ) throws {
        loadSnapshotIfNeeded()
        let inserted = mergeMessagesInMemory([message], userId: userId, friendId: friendId)
        let userKey = String(userId)
        if let values = snapshot.friendsByUser[userKey],
           let index = values.firstIndex(where: { $0.friendId == friendId }) {
            var updated = values
            let unreadCount = updated[index].unreadCount + (incrementsUnread && inserted ? 1 : 0)
            updated[index] = updated[index].withConversation(
                latestMessage: message.conversationSummary,
                unreadCount: unreadCount
            )
            snapshot.friendsByUser[userKey] = updated
        }
        try persist()
    }

    @discardableResult
    private func mergeMessagesInMemory(_ messages: [ChatMessage], userId: Int64, friendId: Int64) -> Bool {
        let key = conversationKey(userId: userId, friendId: friendId)
        var merged: [String: ChatMessage] = [:]
        // [修改] 服务端已经分配 messageId 后，以服务端 ID 为唯一键，避免回执和历史记录重复落盘。
        for message in snapshot.messagesByConversation[key] ?? [] { merged[Self.cacheKey(for: message)] = message }
        var inserted = false
        for message in messages {
            let cacheKey = Self.cacheKey(for: message)
            if let existing = merged[cacheKey] {
                // [修改] 服务端历史不包含本机收藏和转发来源，刷新时不能覆盖这些本地字段。
                merged[cacheKey] = message.mergingLocalState(from: existing)
            } else {
                inserted = true
                merged[cacheKey] = message
            }
        }
        let sorted = merged.values.sorted(by: Self.messageOrder)
        snapshot.messagesByConversation[key] = Array(sorted.suffix(500))
        return inserted
    }

    func history(userId: Int64, friendId: Int64, beforeMessageId: Int64?, limit: Int) -> ChatHistoryPage? {
        loadSnapshotIfNeeded()
        let key = conversationKey(userId: userId, friendId: friendId)
        let sorted = (snapshot.messagesByConversation[key] ?? []).sorted(by: Self.messageOrder)
        let eligible: [ChatMessage]
        if let beforeMessageId {
            eligible = sorted.filter { $0.messageId > 0 && $0.messageId < beforeMessageId }
        } else {
            eligible = sorted
        }
        guard !eligible.isEmpty else { return nil }
        let pageMessages = Array(eligible.suffix(max(limit, 1)))
        return ChatHistoryPage(
            messages: pageMessages,
            hasMore: eligible.count > pageMessages.count,
            nextBeforeMessageId: pageMessages.first?.messageId,
            latestMessageId: sorted.last?.messageId
        )
    }

    func markRead(userId: Int64, friendId: Int64) throws {
        loadSnapshotIfNeeded()
        let conversation = conversationKey(userId: userId, friendId: friendId)
        if let latest = snapshot.messagesByConversation[conversation]?.last?.messageId {
            snapshot.readCursorByConversation[conversation] = latest
        }
        let userKey = String(userId)
        if let values = snapshot.friendsByUser[userKey],
           let index = values.firstIndex(where: { $0.friendId == friendId }) {
            var updated = values
            updated[index] = updated[index].withUnreadCount(0)
            snapshot.friendsByUser[userKey] = updated
        }
        try persist()
    }

    // [修改] 本地删除只作用于当前账号和当前好友的缓存分区，不向服务端发送 delete_local。
    func deleteMessage(messageID: String, userId: Int64, friendId: Int64) throws {
        loadSnapshotIfNeeded()
        let key = conversationKey(userId: userId, friendId: friendId)
        guard let current = snapshot.messagesByConversation[key] else { return }
        let updated = current.filter { $0.id != messageID }
        guard updated.count != current.count else { return }
        if updated.isEmpty {
            snapshot.messagesByConversation.removeValue(forKey: key)
            snapshot.readCursorByConversation.removeValue(forKey: key)
        } else {
            snapshot.messagesByConversation[key] = updated
        }
        updateConversationSummary(userId: userId, friendId: friendId, clearUnread: false)
        try persist()
    }

    // [修改] 清空聊天记录只清除本机缓存；服务端历史仍可在后续刷新时重新同步。
    func clearConversation(userId: Int64, friendId: Int64) throws {
        loadSnapshotIfNeeded()
        let key = conversationKey(userId: userId, friendId: friendId)
        snapshot.messagesByConversation.removeValue(forKey: key)
        snapshot.readCursorByConversation.removeValue(forKey: key)
        updateConversationSummary(userId: userId, friendId: friendId, clearUnread: true)
        try persist()
    }

    // [修改] 收藏只写当前账号和会话分区，服务端历史刷新时通过合并规则继续保留本地收藏状态。
    func setFavorite(
        messageID: String,
        isFavorite: Bool,
        userId: Int64,
        friendId: Int64
    ) throws {
        loadSnapshotIfNeeded()
        let key = conversationKey(userId: userId, friendId: friendId)
        guard var messages = snapshot.messagesByConversation[key],
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index] = messages[index].withFavorite(isFavorite)
        snapshot.messagesByConversation[key] = messages
        try persist()
    }

    func favoriteMessages(userId: Int64) -> [ChatMessage] {
        loadSnapshotIfNeeded()
        let prefix = "\(userId):"
        return snapshot.messagesByConversation
            .filter { $0.key.hasPrefix(prefix) }
            .flatMap(\.value)
            .filter(\.isFavorite)
            .sorted(by: Self.messageOrder)
    }

    // [修改] 表情回应是服务端状态，动作推送只更新命中的原消息，不新增伪消息。
    func applyReaction(_ action: ChatMessageAction, userId: Int64) throws {
        loadSnapshotIfNeeded()
        guard action.isReaction, let reactions = action.reaction else { return }
        let key = conversationKey(userId: userId, friendId: action.friendId)
        guard var messages = snapshot.messagesByConversation[key],
              let index = messages.firstIndex(where: { $0.messageId == action.messageId }) else { return }
        messages[index] = messages[index].withReactions(reactions)
        snapshot.messagesByConversation[key] = messages
        try persist()
    }

    // [修改] 撤回不删除气泡，只持久化撤回态；旧消息撤回不会覆盖当前最新摘要。
    func applyMessageAction(_ action: ChatMessageAction, userId: Int64) throws {
        loadSnapshotIfNeeded()
        if action.isReaction {
            try applyReaction(action, userId: userId)
            return
        }
        guard action.isRetraction else { return }
        let key = conversationKey(userId: userId, friendId: action.friendId)
        guard var messages = snapshot.messagesByConversation[key],
              let index = messages.firstIndex(where: { $0.messageId == action.messageId }) else { return }
        messages[index] = messages[index].withRetraction()
        snapshot.messagesByConversation[key] = messages
        updateConversationSummary(userId: userId, friendId: action.friendId, clearUnread: false)
        try persist()
    }

    private func updateConversationSummary(userId: Int64, friendId: Int64, clearUnread: Bool) {
        let userKey = String(userId)
        guard let values = snapshot.friendsByUser[userKey],
              let index = values.firstIndex(where: { $0.friendId == friendId }) else { return }
        let conversation = conversationKey(userId: userId, friendId: friendId)
        let latest = snapshot.messagesByConversation[conversation]?.sorted(by: Self.messageOrder).last
        var updated = values
        updated[index] = updated[index].withConversation(
            latestMessage: latest?.conversationSummary,
            unreadCount: clearUnread ? 0 : updated[index].unreadCount
        )
        snapshot.friendsByUser[userKey] = updated
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProtocolJSON.encoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    // [修改] AppContainer 构造阶段只记录路径；真实文件读取延迟到缓存第一次被仓库访问。
    private func loadSnapshotIfNeeded() {
        guard !didLoadSnapshot else { return }
        didLoadSnapshot = true
        guard let data = dataLoader(fileURL),
              let decoded = try? ProtocolJSON.decoder().decode(Snapshot.self, from: data) else { return }
        snapshot = decoded
    }

    private func conversationKey(userId: Int64, friendId: Int64) -> String {
        "\(userId):\(friendId)"
    }

    private static func messageOrder(_ left: ChatMessage, _ right: ChatMessage) -> Bool {
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        if left.messageId != right.messageId { return left.messageId < right.messageId }
        return left.id < right.id
    }

    private static func cacheKey(for message: ChatMessage) -> String {
        message.messageId > 0 ? "server-\(message.messageId)" : message.id
    }

    private static var defaultFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("ChatStorage/Cache/chat-cache.json")
    }
}

private extension ChatFriend {
    func withPin(_ state: FriendPinState) -> ChatFriend {
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

    func withAlias(_ alias: String) -> ChatFriend {
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

    func withUnreadCount(_ unreadCount: Int) -> ChatFriend {
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

    func withConversation(latestMessage: String?, unreadCount: Int) -> ChatFriend {
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

private extension ChatMessage {
    func withRetraction() -> ChatMessage {
        ChatMessage(
            messageId: messageId,
            senderId: senderId,
            receiverId: receiverId,
            content: content,
            msgType: msgType,
            status: status,
            avatar: avatar,
            groupTime: groupTime,
            messageTime: messageTime,
            clientMsgId: clientMsgId,
            createdAt: createdAt,
            isMine: isMine,
            conversationSeq: conversationSeq,
            senderDeviceId: senderDeviceId,
            encryptionMode: encryptionMode,
            keyId: keyId,
            sendStatus: sendStatus,
            quote: quote,
            retracted: true,
            isFavorite: isFavorite,
            reactions: reactions,
            forwardFrom: forwardFrom
        )
    }

    func withFavorite(_ value: Bool) -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: isMine, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: sendStatus, quote: quote, retracted: retracted, isFavorite: value, reactions: reactions, forwardFrom: forwardFrom)
    }

    func withReactions(_ value: [String: [Int64]]) -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: isMine, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: sendStatus, quote: quote, retracted: retracted, isFavorite: isFavorite, reactions: value, forwardFrom: forwardFrom)
    }

    func mergingLocalState(from existing: ChatMessage) -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: isMine, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: sendStatus, quote: quote, retracted: retracted, isFavorite: existing.isFavorite, reactions: reactions.isEmpty ? existing.reactions : reactions, forwardFrom: forwardFrom ?? existing.forwardFrom)
    }
}
