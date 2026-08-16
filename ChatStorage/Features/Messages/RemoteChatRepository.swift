import Foundation

protocol ChatRepository: Sendable {
    var messages: AsyncStream<ChatMessage> { get }
    func eventStream() -> AsyncStream<ChatEvent>
    func cachedHistory(friendId: Int64, beforeMessageId: Int64?, limit: Int) async -> ChatHistoryPage?
    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage
    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt
    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String) async throws -> ChatReceipt
    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String, quote: ChatQuote?) async throws -> ChatReceipt
    func retract(messageId: Int64, friendId: Int64) async throws
    func react(messageId: Int64, friendId: Int64, emoji: String) async throws -> ChatMessageAction
    func setFavorite(message: ChatMessage, isFavorite: Bool, friendId: Int64) async throws
    func favoriteMessages() async -> [ChatMessage]
    func forward(message: ChatMessage, to friendId: Int64, sourceName: String) async throws
    func deleteLocal(message: ChatMessage, friendId: Int64) async throws
    func clearLocalConversation(friendId: Int64) async throws
    func markRead(friendId: Int64) async throws
    func searchMessages(friendId: Int64?, keyword: String, limit: Int) async throws -> [ChatMessage]
    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult]
    func addFriend(userId: Int64, message: String) async throws
    func pendingRequests() async throws -> [FriendRequestItem]
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws
    func updateAlias(relationshipId: Int64, alias: String) async throws
}

extension ChatRepository {
    func eventStream() -> AsyncStream<ChatEvent> {
        let source = messages
        return AsyncStream { continuation in
            let task = Task {
                for await message in source { continuation.yield(.message(message)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cachedHistory(friendId: Int64, beforeMessageId: Int64?, limit: Int) async -> ChatHistoryPage? { nil }

    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String) async throws -> ChatReceipt {
        guard messageType.caseInsensitiveCompare("TEXT") == .orderedSame else {
            throw ChatRepositoryError.server(message: "当前聊天仓库不支持附件消息")
        }
        return try await send(friendId: friendId, content: content, clientMessageId: clientMessageId)
    }

    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String, quote: ChatQuote?) async throws -> ChatReceipt {
        guard quote == nil else {
            throw ChatRepositoryError.server(message: "当前聊天仓库不支持引用消息")
        }
        return try await send(friendId: friendId, content: content, messageType: messageType, clientMessageId: clientMessageId)
    }

    func retract(messageId: Int64, friendId: Int64) async throws {
        throw ChatRepositoryError.server(message: "当前聊天仓库不支持撤回消息")
    }

    func react(messageId: Int64, friendId: Int64, emoji: String) async throws -> ChatMessageAction {
        throw ChatRepositoryError.server(message: "当前聊天仓库不支持表情回应")
    }

    func setFavorite(message: ChatMessage, isFavorite: Bool, friendId: Int64) async throws {}
    func favoriteMessages() async -> [ChatMessage] { [] }

    // [修改] 默认转发生成独立 TEXT 消息；自定义仓库可覆盖以持久化转发来源。
    func forward(message: ChatMessage, to friendId: Int64, sourceName: String) async throws {
        _ = try await send(
            friendId: friendId,
            content: message.conversationSummary,
            messageType: "TEXT",
            clientMessageId: UUID().uuidString,
            quote: nil
        )
    }

    func deleteLocal(message: ChatMessage, friendId: Int64) async throws {}
    func clearLocalConversation(friendId: Int64) async throws {}
    func searchMessages(friendId: Int64? = nil, keyword: String, limit: Int = 50) async throws -> [ChatMessage] { [] }
}

enum ChatRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务器返回了无法识别的聊天数据"
        case .server(let message): message.isEmpty ? "聊天操作失败" : message
        }
    }
}

actor RemoteChatRepository: ChatRepository {
    nonisolated private let eventBroadcaster = ChatEventBroadcaster()
    private let client: any FrameRequesting
    private let timeout: Duration
    private var listener: Task<Void, Never>?

    nonisolated var messages: AsyncStream<ChatMessage> {
        messageStream(from: eventStream())
    }

    nonisolated func eventStream() -> AsyncStream<ChatEvent> {
        eventBroadcaster.stream()
    }

    init(client: any FrameRequesting, timeout: Duration = .seconds(15)) {
        self.client = client
        self.timeout = timeout
        listener = nil
        Task { [weak self] in await self?.startListening() }
    }

    func history(friendId: Int64, beforeMessageId: Int64? = nil, limit: Int = 20) async throws -> ChatHistoryPage {
        let request = ChatHistoryRequest(friendId: friendId, beforeMessageId: beforeMessageId, limit: limit)
        let frame = try await client.request(
            Frame(type: .chatHistoryRequest, payload: try ProtocolJSON.encoder().encode(request)),
            expecting: [.chatHistoryResponse, .chatReceipt], timeout: timeout
        )
        if frame.type == .chatReceipt { throw try decodeReceiptError(frame.payload) }
        return try decodeEnvelope(frame.payload, as: ChatHistoryPage.self)
    }

    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt {
        try await send(friendId: friendId, content: content, messageType: "TEXT", clientMessageId: clientMessageId, quote: nil)
    }

    // [修改] 复用 0x50/0x52，只扩展 Android 已支持的 msgType 字段。
    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String) async throws -> ChatReceipt {
        try await send(friendId: friendId, content: content, messageType: messageType, clientMessageId: clientMessageId, quote: nil)
    }

    // [修改] 引用字段只扩展 0x50 JSON，不改变帧号和旧客户端必填字段。
    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String, quote: ChatQuote?) async throws -> ChatReceipt {
        let request = SendChatMessageRequest(
            receiverId: friendId,
            content: content,
            msgType: messageType,
            clientMsgId: clientMessageId,
            quote: quote
        )
        let frame = try await client.request(
            Frame(type: .chatSendRequest, payload: try ProtocolJSON.encoder().encode(request)),
            expecting: [.chatReceipt], timeout: timeout
        )
        let receipt = try decode(ChatReceipt.self, from: frame.payload)
        guard receipt.isSuccess else { throw ChatRepositoryError.server(message: receipt.message ?? "发送失败") }
        return receipt
    }

    func retract(messageId: Int64, friendId: Int64) async throws {
        let requestedAction = ChatMessageAction(action: "retract", messageId: messageId, friendId: friendId)
        _ = try await performMessageAction(requestedAction)
    }

    // [修改] 表情回应继续复用服务端现有 0x59/0x5A，不增加端口或新帧类型。
    func react(messageId: Int64, friendId: Int64, emoji: String) async throws -> ChatMessageAction {
        try await performMessageAction(ChatMessageAction(
            action: "REACTION",
            messageId: messageId,
            friendId: friendId,
            reaction: [emoji: []]
        ), wireReaction: emoji)
    }

    func setFavorite(message: ChatMessage, isFavorite: Bool, friendId: Int64) async throws {}
    func favoriteMessages() async -> [ChatMessage] { [] }

    func forward(message: ChatMessage, to friendId: Int64, sourceName: String) async throws {
        _ = try await send(
            friendId: friendId,
            content: message.conversationSummary,
            messageType: "TEXT",
            clientMessageId: UUID().uuidString,
            quote: nil
        )
    }

    private func performMessageAction(
        _ requestedAction: ChatMessageAction,
        wireReaction: String? = nil
    ) async throws -> ChatMessageAction {
        struct Request: Encodable {
            let action: String
            let messageId: Int64
            let friendId: Int64
            let reaction: String?
        }
        let frame = try await client.request(
            Frame(type: .chatMessageActionRequest, payload: try ProtocolJSON.encoder().encode(Request(
                action: requestedAction.action,
                messageId: requestedAction.messageId,
                friendId: requestedAction.friendId,
                reaction: wireReaction
            ))),
            expecting: [.chatMessageActionResponse],
            timeout: timeout
        )
        let envelope = try decode(WireEnvelope<ChatMessageAction>.self, from: frame.payload)
        guard envelope.isSuccess else {
            throw ChatRepositoryError.server(message: envelope.message)
        }
        let confirmed = envelope.data ?? requestedAction
        eventBroadcaster.yield(.messageAction(confirmed))
        return confirmed
    }

    func markRead(friendId: Int64) async throws {
        try await operation(
            Frame(type: .chatReadRequest, payload: try ProtocolJSON.encoder().encode(ClearUnreadRequest(friendId: friendId))),
            expecting: [.chatReadResponse]
        )
        eventBroadcaster.yield(.read(friendId: friendId))
    }

    // [修改] 0x5E 增加可选 friendId；传值时只查当前会话，缺省仍兼容旧全局搜索。
    func searchMessages(friendId: Int64? = nil, keyword: String, limit: Int = 50) async throws -> [ChatMessage] {
        struct Request: Encodable {
            let friendId: Int64?
            let keyword: String
            let limit: Int
        }
        struct SearchPage: Decodable {
            let list: [ChatMessage]
        }
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let frame = try await client.request(
            Frame(
                type: .chatMessageSearchRequest,
                payload: try ProtocolJSON.encoder().encode(Request(
                    friendId: friendId,
                    keyword: normalized,
                    limit: max(1, min(limit, 100))
                ))
            ),
            expecting: [.chatMessageSearchResponse],
            timeout: timeout
        )
        return try decodeEnvelope(frame.payload, as: SearchPage.self).list
    }

    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] {
        let frame = try await client.request(
            Frame(type: .friendSearchRequest, payload: try ProtocolJSON.encoder().encode(UserSearchRequest(userName: keyword))),
            expecting: [.friendSearchResponse], timeout: timeout
        )
        return try decodeListEnvelope(frame.payload, as: ChatUserSearchResult.self)
    }

    func addFriend(userId: Int64, message: String) async throws {
        try await operation(
            Frame(type: .friendAddRequest, payload: try ProtocolJSON.encoder().encode(AddFriendRequest(userId: userId, requestMsg: message))),
            expecting: [.friendAddResponse]
        )
    }

    func pendingRequests() async throws -> [FriendRequestItem] {
        let frame = try await client.request(Frame(type: .friendRequestsRequest), expecting: [.friendRequestsResponse], timeout: timeout)
        return try decodeListEnvelope(frame.payload, as: FriendRequestItem.self)
    }

    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws {
        try await operation(
            Frame(type: .friendHandleRequest, payload: try ProtocolJSON.encoder().encode(HandleFriendRequest(requestId: requestId, action: accept ? 1 : 2, alias: alias))),
            expecting: [.friendHandleResponse]
        )
    }

    func updateAlias(relationshipId: Int64, alias: String) async throws {
        try await operation(
            Frame(type: .friendAliasUpdateRequest, payload: try ProtocolJSON.encoder().encode(UpdateFriendAliasRequest(id: relationshipId, alias: alias))),
            expecting: [.friendAliasUpdateResponse]
        )
    }

    private func operation(_ frame: Frame, expecting types: Set<FrameType>) async throws {
        let response = try await client.request(frame, expecting: types, timeout: timeout)
        let envelope = try decode(FriendOperationEnvelope.self, from: response.payload)
        guard envelope.isSuccess else { throw ChatRepositoryError.server(message: envelope.message) }
    }

    private func startListening() {
        guard listener == nil else { return }
        listener = Task { [weak self, pushes = client.pushes] in
            for await frame in pushes {
                await self?.receive(frame)
            }
        }
    }

    private func receive(_ frame: Frame) {
        switch frame.type {
        case .chatPush:
            guard let message = try? decode(ChatMessage.self, from: frame.payload), message.messageId > 0 else { return }
            eventBroadcaster.yield(.message(message))
        case .chatMessageActionPush:
            guard let action = try? decode(ChatMessageAction.self, from: frame.payload),
                  action.messageId > 0,
                  action.friendId > 0 else { return }
            eventBroadcaster.yield(.messageAction(action))
        case .friendEventPush:
            guard let relationshipEvent = try? decode(FriendRelationshipEvent.self, from: frame.payload),
                  !relationshipEvent.event.isEmpty,
                  relationshipEvent.requestId > 0 else { return }
            // [修改] 好友申请创建、同意和拒绝都广播给消息页，避免只能手动刷新红点。
            eventBroadcaster.yield(.friendRelationshipChanged(relationshipEvent))
        default:
            return
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        do { return try ProtocolJSON.decoder().decode(type, from: payload) }
        catch { throw ChatRepositoryError.invalidResponse }
    }

    private func decodeEnvelope<T: Decodable>(_ payload: Data, as type: T.Type) throws -> T {
        let envelope = try decode(WireEnvelope<T>.self, from: payload)
        guard envelope.isSuccess else { throw ChatRepositoryError.server(message: envelope.message) }
        guard let data = envelope.data else { throw ChatRepositoryError.invalidResponse }
        return data
    }

    private func decodeListEnvelope<T: Decodable>(_ payload: Data, as type: T.Type) throws -> [T] {
        if let envelope = try? decode(WireEnvelope<[T]>.self, from: payload) {
            guard envelope.isSuccess else { throw ChatRepositoryError.server(message: envelope.message) }
            guard let data = envelope.data else { throw ChatRepositoryError.invalidResponse }
            return data
        }
        let envelope = try decode(WireEnvelope<T>.self, from: payload)
        guard envelope.isSuccess else { throw ChatRepositoryError.server(message: envelope.message) }
        guard let data = envelope.data else { throw ChatRepositoryError.invalidResponse }
        return [data]
    }

    private func decodeReceiptError(_ payload: Data) throws -> Error {
        let receipt = try decode(ChatReceipt.self, from: payload)
        return ChatRepositoryError.server(message: receipt.message ?? "聊天记录加载失败")
    }
}

// [修改] AsyncStream 默认是单队列消费；这里为每个订阅者保存独立 continuation 并逐一广播。
final class ChatEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ChatEvent>.Continuation] = [:]

    func stream() -> AsyncStream<ChatEvent> {
        let id = UUID()
        // [修改] 聊天推送不能因订阅者短暂变慢而丢失，消费完成前保留全部待处理事件。
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
        }
    }

    func yield(_ event: ChatEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(event) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

func messageStream(from events: AsyncStream<ChatEvent>) -> AsyncStream<ChatMessage> {
    AsyncStream { continuation in
        let task = Task {
            for await event in events {
                if case .message(let message) = event { continuation.yield(message) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private struct WireEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let code: Int
    let message: String
    let data: T?
    var isSuccess: Bool { success ?? (code == 200) }

    private enum CodingKeys: String, CodingKey { case success, code, message, msg, data }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        code = try values.decodeIfPresent(Int.self, forKey: .code) ?? (success == true ? 200 : 400)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? values.decodeIfPresent(String.self, forKey: .msg) ?? ""
        data = try values.decodeIfPresent(T.self, forKey: .data)
    }
}
