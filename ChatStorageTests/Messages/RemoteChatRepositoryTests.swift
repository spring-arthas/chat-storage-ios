import XCTest
@testable import ChatStorage

final class RemoteChatRepositoryTests: XCTestCase {
    // [修改] 单个订阅者暂时处理变慢时，超过 200 条推送也不能静默丢失。
    func testEventBroadcasterRetainsBurstLargerThanPreviousBufferLimit() async {
        let broadcaster = ChatEventBroadcaster()
        let stream = broadcaster.stream()
        for id in 1...250 {
            broadcaster.yield(.message(ChatMessage(
                messageId: Int64(id),
                senderId: 9,
                receiverId: 7,
                content: "message-\(id)"
            )))
        }

        let receivedCount = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                var count = 0
                while count < 250, await iterator.next() != nil { count += 1 }
                return count
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(300))
                return -1
            }
            let first = await group.next() ?? -1
            group.cancelAll()
            return first
        }

        XCTAssertEqual(receivedCount, 250)
    }

    func testHistoryUsesAndroidWireKeysAndDecodesPage() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"list":[{"id":42,"senderId":7,"receiverId":9,"content":"hello","msgType":"TEXT","status":1,"gmtCreated":1785360000123}],"hasMore":true,"nextBeforeMessageId":42}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatHistoryResponse, payload: payload)])
        let repository = RemoteChatRepository(client: client)

        let page = try await repository.history(friendId: 9, limit: 20)

        XCTAssertEqual(page.messages.first?.messageId, 42)
        XCTAssertTrue(page.hasMore)
        let frames = await client.sentFrames
        let sent = try XCTUnwrap(frames.first)
        XCTAssertEqual(sent.type, .chatHistoryRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["friendId"] as? Int, 9)
        XCTAssertEqual(object["limit"] as? Int, 20)
        XCTAssertNil(object["beforeMessageId"])
    }

    // [修改] 历史接口会把 reaction 作为 JSON 字符串返回，不能只兼容实时动作推送。
    func testHistoryDecodesReactionJSONString() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"list":[{"id":42,"senderId":7,"receiverId":9,"content":"hello","msgType":"TEXT","reaction":"{\"👍\":[7,9],\"❤️\":[9]}"}],"hasMore":false}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatHistoryResponse, payload: payload)])
        let repository = RemoteChatRepository(client: client)

        let page = try await repository.history(friendId: 9, limit: 20)

        XCTAssertEqual(page.messages.first?.reactions, ["👍": [7, 9], "❤️": [9]])
    }

    // [修改] 会话内搜索必须把当前好友 ID 发给服务端，避免命中其他会话的同名内容。
    func testSearchMessagesUsesCurrentFriendScopeAndClampsLimit() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"list":[{"id":42,"senderId":9,"receiverId":7,"content":"项目文件","msgType":"TEXT","gmtCreated":1785360000123}]}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatMessageSearchResponse, payload: payload)])
        let repository = RemoteChatRepository(client: client)

        let messages = try await repository.searchMessages(friendId: 9, keyword: "  项目  ", limit: 500)

        XCTAssertEqual(messages.map(\.messageId), [42])
        let frames = await client.sentFrames
        let sent = try XCTUnwrap(frames.first)
        XCTAssertEqual(sent.type, .chatMessageSearchRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["friendId"] as? Int, 9)
        XCTAssertEqual(object["keyword"] as? String, "项目")
        XCTAssertEqual(object["limit"] as? Int, 100)
    }

    // [修改] 空关键词不发 Socket 请求，直接返回空结果。
    func testSearchMessagesSkipsRequestForBlankKeyword() async throws {
        let client = ChatFrameClient(responses: [])
        let repository = RemoteChatRepository(client: client)

        let messages = try await repository.searchMessages(friendId: 9, keyword: " \n ", limit: 50)

        XCTAssertTrue(messages.isEmpty)
        let frames = await client.sentFrames
        XCTAssertTrue(frames.isEmpty)
    }

    func testSendMessageReturnsReceiptAndUsesClientMessageId() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"messageId":88,"status":"SUCCESS","clientMsgId":"client-1"}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatReceipt, payload: payload)])
        let repository = RemoteChatRepository(client: client)

        let receipt = try await repository.send(friendId: 9, content: "hello", clientMessageId: "client-1")

        XCTAssertEqual(receipt.messageId, 88)
        XCTAssertTrue(receipt.isSuccess)
        let frames = await client.sentFrames
        let sent = try XCTUnwrap(frames.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["receiverId"] as? Int, 9)
        XCTAssertEqual(object["clientMsgId"] as? String, "client-1")
        XCTAssertEqual(object["msgType"] as? String, "TEXT")
    }

    // [修改] 引用消息继续复用 0x50，只增加 macOS 已使用的三个可选 JSON 字段。
    func testSendMessageWithQuoteEncodesCompatibleWireFields() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"messageId":89,"status":"SUCCESS","clientMsgId":"client-quote"}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatReceipt, payload: payload)])
        let repository = RemoteChatRepository(client: client)
        let quote = ChatQuote(messageId: 42, content: "上一条消息", senderName: "张三")

        _ = try await repository.send(
            friendId: 9,
            content: "回复内容",
            messageType: "TEXT",
            clientMessageId: "client-quote",
            quote: quote
        )

        let frames = await client.sentFrames
        let sent = try XCTUnwrap(frames.first)
        XCTAssertEqual(sent.type, .chatSendRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["quoteMsgId"] as? Int, 42)
        XCTAssertEqual(object["quoteMsgContent"] as? String, "上一条消息")
        XCTAssertEqual(object["quoteMsgSenderName"] as? String, "张三")
    }

    // [修改] 撤回复用服务端现有 0x59/0x5A，并将成功结果广播给缓存和其他页面。
    func testRetractMessageUsesActionFramesAndPublishesAction() async throws {
        let payload = Data(#"{"success":true,"message":"消息已撤回","data":{"action":"RETRACT","messageId":88,"friendId":9,"notifyText":"消息已撤回","retracted":1}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatMessageActionResponse, payload: payload)])
        let repository = RemoteChatRepository(client: client)
        let eventTask = Task { try await firstMessageAction(from: repository.eventStream()) }
        await Task.yield()

        try await repository.retract(messageId: 88, friendId: 9)

        let action = try await eventTask.value
        XCTAssertEqual(action.messageId, 88)
        XCTAssertEqual(action.friendId, 9)
        XCTAssertTrue(action.isRetraction)
        let frames = await client.sentFrames
        let sent = try XCTUnwrap(frames.first)
        XCTAssertEqual(sent.type, .chatMessageActionRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "retract")
        XCTAssertEqual(object["messageId"] as? Int, 88)
        XCTAssertEqual(object["friendId"] as? Int, 9)
    }

    // [修改] 对方撤回通过 0x5B 直推，不能被当作未知帧丢掉。
    func testMessageActionPushPublishesRetraction() async throws {
        let client = ChatFrameClient(responses: [])
        let repository = RemoteChatRepository(client: client)
        let eventTask = Task { try await firstMessageAction(from: repository.eventStream()) }
        await Task.yield()

        await client.emit(Frame(
            type: .chatMessageActionPush,
            payload: Data(#"{"action":"RECALL","messageId":91,"friendId":9,"notifyText":"消息已撤回","retracted":true}"#.utf8)
        ))

        let action = try await eventTask.value
        XCTAssertEqual(action.messageId, 91)
        XCTAssertEqual(action.friendId, 9)
        XCTAssertTrue(action.isRetraction)
    }

    // [修改] 表情回应必须把单个 emoji 作为字符串发给服务端，并解码服务端合并后的用户列表。
    func testReactionUsesActionFramesAndDecodesMergedUsers() async throws {
        let payload = Data(#"{"success":true,"data":{"action":"REACTION","messageId":88,"friendId":9,"reaction":"{\"👍\":[7,9]}"}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatMessageActionResponse, payload: payload)])
        let repository = RemoteChatRepository(client: client)

        let action = try await repository.react(messageId: 88, friendId: 9, emoji: "👍")

        XCTAssertEqual(action.reaction, ["👍": [7, 9]])
        let frames = await client.sentFrames
        let sent = try XCTUnwrap(frames.first)
        XCTAssertEqual(sent.type, .chatMessageActionRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "REACTION")
        XCTAssertEqual(object["reaction"] as? String, "👍")
    }

    func testPushStreamPublishesIncomingMessage() async throws {
        let client = ChatFrameClient(responses: [])
        let repository = RemoteChatRepository(client: client)
        let task = Task { () -> ChatMessage in
            for await message in repository.messages {
                return message
            }
            throw RequestResponseError.closed
        }

        await client.emit(Frame(type: .chatPush, payload: Data(#"{"messageId":91,"senderId":9,"content":"push","msgType":"TEXT","gmtCreated":1785360000123}"#.utf8)))

        let message = try await task.value
        XCTAssertEqual(message.messageId, 91)
        XCTAssertEqual(message.senderId, 9)
        XCTAssertEqual(message.content, "push")
    }

    func testPushStreamBroadcastsIncomingMessageToEverySubscriber() async throws {
        let client = ChatFrameClient(responses: [])
        let repository = RemoteChatRepository(client: client)
        let first = Task { try await firstMessage(from: repository.eventStream()) }
        let second = Task { try await firstMessage(from: repository.eventStream()) }
        await Task.yield()

        // [修改] 一条推送必须广播给所有页面，不能在好友列表和聊天页之间分流。
        await client.emit(Frame(type: .chatPush, payload: Data(#"{"messageId":91,"senderId":9,"receiverId":7,"content":"push","msgType":"TEXT","gmtCreated":1785360000123}"#.utf8)))

        let firstReceived = try await first.value
        let secondReceived = try await second.value
        XCTAssertEqual(firstReceived.messageId, 91)
        XCTAssertEqual(secondReceived.messageId, 91)
    }

    // [修改] 好友申请推送必须进入统一事件流，消息页才能实时刷新右上角红点和好友列表。
    func testFriendEventPushPublishesRelationshipChange() async throws {
        let client = ChatFrameClient(responses: [])
        let repository = RemoteChatRepository(client: client)
        let task = Task { try await firstFriendRelationshipEvent(from: repository.eventStream()) }
        await Task.yield()

        await client.emit(Frame(
            type: .friendEventPush,
            payload: Data(#"{"event":"REQUEST_CREATED","requestId":31,"actorUserId":9}"#.utf8)
        ))

        let event = try await task.value
        XCTAssertEqual(event, FriendRelationshipEvent(
            event: "REQUEST_CREATED",
            requestId: 31,
            actorUserId: 9
        ))
    }

    func testMarkReadSendsFriendIdAndBroadcastsReadEvent() async throws {
        let response = Data(#"{"success":true,"code":200,"data":null}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatReadResponse, payload: response)])
        let repository = RemoteChatRepository(client: client)
        let eventTask = Task { try await firstReadFriendID(from: repository.eventStream()) }
        await Task.yield()

        try await repository.markRead(friendId: 9)

        let readFriendId = try await eventTask.value
        XCTAssertEqual(readFriendId, 9)
        let frames = await client.sentFrames
        let sent = try XCTUnwrap(frames.first)
        XCTAssertEqual(sent.type, .chatReadRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["friendId"] as? Int, 9)
    }

    func testChatMessageDecodesOptionalFoundationFields() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"list":[{"id":42,"senderId":7,"receiverId":9,"content":"hello","msgType":"TEXT","status":1,"gmtCreated":1785360000123,"conversationSeq":7,"senderDeviceId":"device-a","encryptionMode":"SERVER_MANAGED","keyId":"k1"}],"hasMore":false}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatHistoryResponse, payload: payload)])
        let repository = RemoteChatRepository(client: client)

        let page = try await repository.history(friendId: 9, limit: 20)
        let message = try XCTUnwrap(page.messages.first)

        XCTAssertEqual(message.conversationSeq, 7)
        XCTAssertEqual(message.senderDeviceId, "device-a")
        XCTAssertEqual(message.encryptionMode, "SERVER_MANAGED")
        XCTAssertEqual(message.keyId, "k1")
    }

    func testChatMessageOmitsFoundationFieldsForLegacyResponses() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"list":[{"id":42,"senderId":7,"receiverId":9,"content":"hello","msgType":"TEXT","status":1,"gmtCreated":1785360000123}],"hasMore":false}}"#.utf8)
        let client = ChatFrameClient(responses: [Frame(type: .chatHistoryResponse, payload: payload)])
        let repository = RemoteChatRepository(client: client)

        let page = try await repository.history(friendId: 9, limit: 20)
        let message = try XCTUnwrap(page.messages.first)

        XCTAssertNil(message.conversationSeq)
        XCTAssertNil(message.senderDeviceId)
        XCTAssertNil(message.encryptionMode)
        XCTAssertNil(message.keyId)
    }
}

private func firstMessage(from stream: AsyncStream<ChatEvent>) async throws -> ChatMessage {
    for await event in stream {
        if case .message(let message) = event { return message }
    }
    throw RequestResponseError.closed
}

private func firstReadFriendID(from stream: AsyncStream<ChatEvent>) async throws -> Int64 {
    for await event in stream {
        if case .read(let friendId) = event { return friendId }
    }
    throw RequestResponseError.closed
}

private func firstFriendRelationshipEvent(
    from stream: AsyncStream<ChatEvent>
) async throws -> FriendRelationshipEvent {
    for await event in stream {
        if case .friendRelationshipChanged(let relationshipEvent) = event {
            return relationshipEvent
        }
    }
    throw RequestResponseError.closed
}

private func firstMessageAction(from stream: AsyncStream<ChatEvent>) async throws -> ChatMessageAction {
    for await event in stream {
        if case .messageAction(let action) = event { return action }
    }
    throw RequestResponseError.closed
}

private actor ChatFrameClient: FrameRequesting {
    private var responses: [Frame]
    private(set) var sentFrames: [Frame] = []
    private var continuation: AsyncStream<Frame>.Continuation?
    nonisolated let pushes: AsyncStream<Frame>

    init(responses: [Frame]) {
        self.responses = responses
        var captured: AsyncStream<Frame>.Continuation!
        pushes = AsyncStream { captured = $0 }
        continuation = captured
    }

    func connect() async throws {}

    func request(_ frame: Frame, expecting: Set<FrameType>, timeout: Duration) async throws -> Frame {
        sentFrames.append(frame)
        guard !responses.isEmpty else { throw RequestResponseError.closed }
        return responses.removeFirst()
    }

    func emit(_ frame: Frame) { continuation?.yield(frame) }
}
