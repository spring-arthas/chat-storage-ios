import XCTest
@testable import ChatStorage

@MainActor
final class ChatConversationViewModelTests: XCTestCase {
    func testLoadFetchesHistoryAndMarksConversationRead() async {
        let repository = ConversationRepository(pages: [
            ChatHistoryPage(messages: [.fixture(id: 2, content: "server")], hasMore: true, nextBeforeMessageId: 2, latestMessageId: 2)
        ])
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)

        await model.load()

        XCTAssertEqual(model.messages.map(\.content), ["server"])
        XCTAssertTrue(model.hasOlderMessages)
        let readIDs = await repository.readFriendIds
        XCTAssertEqual(readIDs, [9])
    }

    func testLoadUsesCachedHistoryWhenRemoteIsUnavailable() async {
        let cachedPage = ChatHistoryPage(messages: [.fixture(id: 3, content: "cached")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 3)
        let repository = ConversationRepository(pages: [], cachedPage: cachedPage, historyError: RequestResponseError.closed)
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)

        await model.load()

        XCTAssertEqual(model.messages.map(\.content), ["cached"])
        XCTAssertNil(model.errorMessage)
    }

    // [修改] 历史请求在途时收到的新推送不能被旧历史快照覆盖。
    func testLoadPreservesIncomingMessageReceivedWhileHistoryIsInFlight() async throws {
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [.fixture(id: 2, content: "server")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 2)],
            historyDelay: .milliseconds(100)
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        let observation = Task { await model.observeIncoming() }
        await Task.yield()

        let loading = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(20))
        await repository.emit(.fixture(id: 91, senderId: 9, receiverId: 7, content: "push"))
        try await waitForConversationCondition("历史刷新期间先收到实时消息") {
            model.messages.contains(where: { $0.messageId == 91 })
        }
        await loading.value

        XCTAssertEqual(model.messages.map(\.content), ["server", "push"])
        observation.cancel()
    }

    // [修改] 下拉刷新只能补服务端历史，不能删除本地仍可重试的失败消息。
    func testLoadPreservesFailedLocalMessage() async {
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [.fixture(id: 2, content: "server")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 2)],
            sendFailuresRemaining: 1
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        model.draft = "retry me"
        await model.send()

        await model.load()

        XCTAssertEqual(model.messages.map(\.content), ["server", "retry me"])
        XCTAssertEqual(model.messages.last?.sendStatus, .failed)
    }

    // [修改] 下拉刷新最新页后，继续上拉必须从刷新前的旧游标接着取，不能重复加载第二页。
    func testRefreshPreservesOlderHistoryCursor() async {
        let repository = ConversationRepository(pages: [
            ChatHistoryPage(messages: [.fixture(id: 21, content: "latest")], hasMore: true, nextBeforeMessageId: 21, latestMessageId: 21),
            ChatHistoryPage(messages: [.fixture(id: 11, content: "older")], hasMore: true, nextBeforeMessageId: 11, latestMessageId: 21),
            ChatHistoryPage(messages: [.fixture(id: 22, content: "refreshed")], hasMore: true, nextBeforeMessageId: 22, latestMessageId: 22),
            ChatHistoryPage(messages: [.fixture(id: 1, content: "oldest")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 22),
        ])
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)

        await model.load()
        await model.loadOlder()
        await model.load()
        await model.loadOlder()

        let requestedCursors = await repository.historyBeforeMessageIds
        XCTAssertEqual(requestedCursors, [nil, 21, nil, 11])
        XCTAssertEqual(model.messages.map(\.content), ["oldest", "older", "latest", "refreshed"])
    }

    func testSendAddsConfirmedMessageAndClearsDraft() async {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 88))
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        model.draft = " hello "

        await model.send()

        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.messages.last?.messageId, 88)
        XCTAssertTrue(model.messages.last?.isMine == true)
        let sent = await repository.sentContents
        XCTAssertEqual(sent, ["hello"])
    }

    func testIncomingPushForFriendIsAppendedAndMarkedRead() async throws {
        let repository = ConversationRepository(pages: [])
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        let observation = Task { await model.observeIncoming() }
        await Task.yield()

        await repository.emit(.fixture(id: 91, senderId: 9, receiverId: 7, content: "push"))
        // [修改] 当前会话收到对方消息后，界面追加和已读上报必须一起完成。
        try await waitForConversationCondition("当前会话追加消息并上报已读") {
            let readFriendIDs = await repository.readFriendIds
            return model.messages.last?.messageId == 91 && readFriendIDs == [9]
        }

        XCTAssertEqual(model.messages.last?.content, "push")
        let readFriendIDs = await repository.readFriendIds
        XCTAssertEqual(readFriendIDs, [9])
        observation.cancel()
    }

    func testInsertEmojiAppendsToExistingDraft() {
        let repository = ConversationRepository(pages: [])
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        model.draft = "晚上见"

        model.insertEmoji("👍")

        XCTAssertEqual(model.draft, "晚上见👍")
    }

    // [修改] 表情面板按 macOS 分类对齐，并把最近使用限制为 24 个且去重置顶。
    func testEmojiCatalogProvidesCategoriesAndRecentStoreMovesSelectionToFront() throws {
        let suiteName = "ChatEmojiStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ChatEmojiStore(defaults: defaults)

        XCTAssertEqual(ChatEmojiCatalog.categories.map(\.title), ["笑脸", "手势", "人物", "动物", "食物", "活动", "旅行", "符号", "物品"])
        XCTAssertTrue(ChatEmojiCatalog.categories.allSatisfy { !$0.emojis.isEmpty })

        for emoji in ChatEmojiCatalog.categories.flatMap(\.emojis).prefix(25) {
            store.storeRecent(emoji)
        }
        store.storeRecent("😀")

        XCTAssertEqual(store.recent.first, "😀")
        XCTAssertEqual(store.recent.count, 24)
        XCTAssertEqual(store.recent.filter { $0 == "😀" }.count, 1)
    }

    // [修改] 引用文本消息时，本地气泡和 0x50 请求都必须带同一份引用信息。
    func testSendTextIncludesSelectedQuoteAndClearsComposerQuote() async {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 88))
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        let source = ChatMessage.fixture(id: 42, senderId: 9, receiverId: 7, content: "上一条消息")
        model.selectQuote(source, senderName: "好友")
        model.draft = "回复内容"

        await model.send()

        XCTAssertNil(model.quotedMessage)
        XCTAssertEqual(model.messages.last?.quote, ChatQuote(messageId: 42, content: "上一条消息", senderName: "好友"))
        let sentQuotes = await repository.sentQuotes
        XCTAssertEqual(sentQuotes, [ChatQuote(messageId: 42, content: "上一条消息", senderName: "好友")])
    }

    // [修改] 多附件仍是每个资源一条消息，引用只跟随第一条，避免同一引用重复九次。
    func testAttachmentBatchAppliesQuoteOnlyToFirstIndependentMessage() async throws {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 99))
        let uploader = ConversationAttachmentUploader()
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository, attachmentUploader: uploader)
        model.selectQuote(ChatMessage.fixture(id: 42, content: "上一条"), senderName: "好友")
        let first = try temporaryFile(name: "one.pdf", contents: "one")
        let second = try temporaryFile(name: "two.pdf", contents: "two")

        await model.sendAttachments([first, second])

        XCTAssertNil(model.quotedMessage)
        XCTAssertEqual(model.messages.map(\.quote), [
            ChatQuote(messageId: 42, content: "上一条", senderName: "好友"),
            nil,
        ])
        let sentQuotes = await repository.sentQuotes
        XCTAssertEqual(sentQuotes, [
            ChatQuote(messageId: 42, content: "上一条", senderName: "好友"),
            nil,
        ])
    }

    // [修改] 本地删除不发消息动作帧；仓库失败时恢复原位置，避免气泡静默丢失。
    func testDeleteLocalRemovesMessageAndRestoresItWhenCacheWriteFails() async {
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [.fixture(id: 42, content: "保留我")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 42)],
            localDeleteError: ChatRepositoryError.server(message: "本地删除失败")
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        await model.load()

        await model.deleteLocal(messageID: model.messages[0].id)

        XCTAssertEqual(model.messages.map(\.content), ["保留我"])
        XCTAssertEqual(model.errorMessage, "本地删除失败")
        let deletedMessageIDs = await repository.locallyDeletedMessageIDs
        XCTAssertEqual(deletedMessageIDs, [model.messages[0].id])
    }

    // [修改] 撤回先更新界面，服务端拒绝时必须恢复原消息状态并显示错误。
    func testRetractFailureRestoresOriginalMessage() async {
        let message = ChatMessage.fixture(id: 42, senderId: 7, receiverId: 9, content: "撤回我")
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [message], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 42)],
            retractError: ChatRepositoryError.server(message: "超过撤回时间")
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        await model.load()

        await model.retract(messageID: model.messages[0].id)

        XCTAssertFalse(model.messages[0].retracted)
        XCTAssertEqual(model.errorMessage, "超过撤回时间")
        let retractedMessageIDs = await repository.retractedMessageIDs
        XCTAssertEqual(retractedMessageIDs, [42])
    }

    // [修改] 对方的 0x5B 撤回推送要原地更新气泡，不新增一条伪消息。
    func testIncomingRetractionUpdatesExistingMessageInPlace() async throws {
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [.fixture(id: 42, senderId: 9, receiverId: 7, content: "原消息")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 42)]
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        await model.load()
        let observation = Task { await model.observeIncoming() }
        await Task.yield()

        await repository.emitAction(ChatMessageAction(action: "RECALL", messageId: 42, friendId: 9))
        try await waitForConversationCondition("撤回推送更新原气泡") { model.messages.first?.retracted == true }

        XCTAssertEqual(model.messages.count, 1)
        observation.cancel()
    }

    // [修改] 收藏只写当前账号的本地缓存，并立即更新当前气泡和收藏列表。
    func testToggleFavoriteUpdatesMessageAndFavoriteCollection() async {
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [.fixture(id: 42, content: "收藏我")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 42)]
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        await model.load()

        await model.toggleFavorite(messageID: model.messages[0].id)

        XCTAssertTrue(model.messages[0].isFavorite)
        XCTAssertEqual(model.favoriteMessages.map(\.messageId), [42])
        let favorites = await repository.favoriteUpdates
        XCTAssertEqual(favorites, [FavoriteUpdate(messageID: "server-42", isFavorite: true)])
    }

    // [修改] 转发沿用 Android 语义：生成一条新文本消息，并保留原消息来源提示。
    func testForwardMessageSendsIndependentMessageToSelectedFriend() async {
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [.fixture(id: 42, content: "需要转发")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 42)],
            receipt: .fixture(messageId: 99)
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        await model.load()

        await model.forward(messageID: model.messages[0].id, to: 10, sourceName: "好友")

        let forwarded = await repository.forwardedMessages
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded.first?.friendId, 10)
        XCTAssertEqual(forwarded.first?.content, "需要转发")
        XCTAssertEqual(forwarded.first?.forwardFrom, "好友")
    }

    // [修改] 表情回应走 0x59/0x5A，服务端合并后的用户列表必须原地更新气泡。
    func testReactionActionUpdatesMessageAndIncomingReactionPush() async throws {
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [.fixture(id: 42, content: "回应我")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 42)],
            reactionResult: ["👍": [7]]
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        await model.load()

        await model.sendReaction(messageID: model.messages[0].id, emoji: "👍")

        XCTAssertEqual(model.messages[0].reactions, ["👍": [7]])
        let actions = await repository.reactionRequests
        XCTAssertEqual(actions, [ReactionRequest(messageId: 42, friendId: 9, emoji: "👍")])

        let observation = Task { await model.observeIncoming() }
        await Task.yield()
        await repository.emitAction(ChatMessageAction(
            action: "REACTION",
            messageId: 42,
            friendId: 9,
            reaction: ["❤️": [7, 9]]
        ))
        try await waitForConversationCondition("表情回应推送更新原气泡") {
            model.messages[0].reactions == ["❤️": [7, 9]]
        }
        observation.cancel()
    }

    // [修改] 清空聊天只清本地视图和缓存；写盘失败时恢复原会话。
    func testClearLocalConversationRestoresMessagesWhenCacheWriteFails() async {
        let repository = ConversationRepository(
            pages: [ChatHistoryPage(messages: [.fixture(id: 42, content: "保留我")], hasMore: false, nextBeforeMessageId: nil, latestMessageId: 42)],
            clearLocalError: ChatRepositoryError.server(message: "清空失败")
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        await model.load()

        await model.clearLocalConversation()

        XCTAssertEqual(model.messages.map(\.content), ["保留我"])
        XCTAssertEqual(model.errorMessage, "清空失败")
        let clearedFriendIDs = await repository.clearedFriendIDs
        XCTAssertEqual(clearedFriendIDs, [9])
    }

    // [修改] 用户确认每个附件必须独立生成一条消息，不能把整个批次合并成一个 MIXED 消息。
    func testSendAttachmentsCreatesOneIndependentMessagePerResource() async throws {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 99))
        let uploader = ConversationAttachmentUploader()
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        model.draft = "请查收"
        let first = try temporaryFile(name: "one.pdf", contents: "one")
        let second = try temporaryFile(name: "two.jpg", contents: "two")

        await model.sendAttachments([first, second])

        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages.map(\.msgType), ["MIXED", "MIXED"])
        XCTAssertEqual(model.messages.map(\.sendStatus), [.sent, .sent])
        let sentMessages = await repository.sentMessages
        XCTAssertEqual(sentMessages.count, 2)
        let payloads = try sentMessages.map {
            try ProtocolJSON.decoder().decode(ChatMixedMessageContent.self, from: Data($0.content.utf8))
        }
        XCTAssertEqual(payloads.map(\.attachments.count), [1, 1])
        XCTAssertEqual(Set(payloads.flatMap(\.attachments).map(\.fileName)), ["one.pdf", "two.jpg"])
        XCTAssertEqual(payloads.filter { !$0.text.isEmpty }.map(\.text), ["请查收"])
        let uploadedNames = await uploader.uploadedNames
        XCTAssertEqual(Set(uploadedNames), ["one.pdf", "two.jpg"])
        let clientMessageIds = await repository.sentClientMessageIds
        XCTAssertEqual(Set(clientMessageIds).count, 2)
    }

    // [修改] 缺少上传凭据时也要释放应用已创建的暂存副本，不能留下孤儿文件。
    func testSendAttachmentsWithoutUploaderRemovesManagedSources() async throws {
        let repository = ConversationRepository(pages: [])
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        let source = try temporaryOutgoingAttachment(name: "orphan.pdf", contents: "orphan")

        await model.sendAttachments([source])

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(model.errorMessage, "当前账号没有可用的附件传输凭据")
        XCTAssertTrue(model.messages.isEmpty)
    }

    // [修改] 文件仍在上传时，所有资源都要先各自出现在会话中并显示“发送中”。
    func testSendAttachmentsShowsIndependentSendingMessagesBeforeUploadsFinish() async throws {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 99))
        let uploader = SlowConversationAttachmentUploader(delay: .milliseconds(150))
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        let first = try temporaryFile(name: "one.pdf", contents: "one")
        let second = try temporaryFile(name: "two.jpg", contents: "two")

        let sending = Task { await model.sendAttachments([first, second]) }
        try await waitForConversationCondition("附件本地发送中消息") {
            model.messages.count == 2
        }

        XCTAssertEqual(model.messages.map(\.sendStatus), [.sending, .sending])
        XCTAssertEqual(model.messages.compactMap(\.mixedContent).map(\.attachments.count), [1, 1])

        await sending.value
        XCTAssertEqual(model.messages.map(\.sendStatus), [.sent, .sent])
    }

    // [修改] 第一批仍在上传时，第二批选择必须排队，不能被 isSending 静默丢弃。
    func testSendAttachmentsQueuesSecondBatchWhileFirstBatchIsUploading() async throws {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 99))
        let uploader = SlowConversationAttachmentUploader(delay: .milliseconds(150))
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        let first = try temporaryFile(name: "first.pdf", contents: "first")
        let second = try temporaryFile(name: "second.pdf", contents: "second")

        let firstBatch = Task { await model.sendAttachments([first]) }
        try await waitForConversationCondition("第一批进入上传") {
            model.messages.count == 1 && model.messages.first?.sendStatus == .sending
        }
        let secondBatch = Task { await model.sendAttachments([second]) }

        await firstBatch.value
        await secondBatch.value
        try await waitForConversationCondition("第二批排队发送完成") {
            model.messages.count == 2 && model.messages.allSatisfy { $0.sendStatus == .sent }
        }

        let uploadedNames = await uploader.uploadedNames
        XCTAssertEqual(uploadedNames, ["first.pdf", "second.pdf"])
    }

    // [修改] 文本消息请求在途时选择的附件也必须排队，并在文本发送结束后自动继续。
    func testSendAttachmentsQueuedDuringTextSendStartsAutomaticallyAfterTextCompletes() async throws {
        let repository = ConversationRepository(
            pages: [],
            receipt: ChatReceipt.fixture(messageId: 99),
            textSendDelay: .milliseconds(150)
        )
        let uploader = ConversationAttachmentUploader()
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        model.draft = "先发文本"
        let source = try temporaryFile(name: "queued.pdf", contents: "queued")

        let textSend = Task { await model.send() }
        try await waitForConversationCondition("文本消息进入发送中") {
            model.isSending && model.messages.first?.content == "先发文本"
        }
        await model.sendAttachments([source])
        await textSend.value

        try await waitForConversationCondition("文本结束后自动发送附件") {
            model.messages.count == 2 && model.messages.allSatisfy { $0.sendStatus == .sent }
        }
        let uploadedNames = await uploader.uploadedNames
        XCTAssertEqual(uploadedNames, ["queued.pdf"])
    }

    // [修改] 文本进入本地发送队列后立即清空旧草稿；发送期间新输入的文字不能被迟到回执清掉。
    func testTextSendClearsOriginalDraftImmediatelyAndPreservesNewInput() async throws {
        let repository = ConversationRepository(
            pages: [],
            receipt: ChatReceipt.fixture(messageId: 99),
            textSendDelay: .milliseconds(150)
        )
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        model.draft = "正在发送的文字"

        let sending = Task { await model.send() }
        try await waitForConversationCondition("文本消息进入发送中") {
            model.isSending && model.messages.first?.content == "正在发送的文字"
        }

        XCTAssertEqual(model.draft, "")
        model.draft = "发送期间新输入"
        await sending.value

        XCTAssertEqual(model.draft, "发送期间新输入")
    }

    // [修改] 文本发送期间选择附件时，附件不能重复带上已经发送的旧草稿。
    func testAttachmentQueuedDuringTextSendDoesNotRepeatSentTextAsCaption() async throws {
        let repository = ConversationRepository(
            pages: [],
            receipt: ChatReceipt.fixture(messageId: 99),
            textSendDelay: .milliseconds(150)
        )
        let uploader = ConversationAttachmentUploader()
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        model.draft = "只发送一次"
        let source = try temporaryFile(name: "queued-caption.pdf", contents: "queued")

        let textSend = Task { await model.send() }
        try await waitForConversationCondition("文本消息进入发送中") {
            model.isSending && model.messages.first?.content == "只发送一次"
        }
        await model.sendAttachments([source])
        await textSend.value

        let sentMessages = await repository.sentMessages
        let mixedPayload = try XCTUnwrap(sentMessages.first).content
        let payload = try ProtocolJSON.decoder().decode(
            ChatMixedMessageContent.self,
            from: Data(mixedPayload.utf8)
        )
        XCTAssertEqual(payload.text, "")
    }

    // [修改] 单个附件失败不能拖垮同批其他资源，失败项必须单独保留并可重试。
    func testSendAttachmentsKeepsPerResourceSuccessAndFailureStates() async throws {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 99))
        let uploader = SelectiveConversationAttachmentUploader(failingNames: ["two.jpg"])
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        let first = try temporaryFile(name: "one.pdf", contents: "one")
        let second = try temporaryFile(name: "two.jpg", contents: "two")
        let third = try temporaryFile(name: "three.mov", contents: "three")

        await model.sendAttachments([first, second, third])

        XCTAssertEqual(model.messages.count, 3)
        let statesByName = Dictionary(uniqueKeysWithValues: model.messages.compactMap { message in
            message.mixedContent?.attachments.first.map { ($0.fileName, message.sendStatus) }
        })
        XCTAssertEqual(statesByName["one.pdf"], .sent)
        XCTAssertEqual(statesByName["two.jpg"], .failed)
        XCTAssertEqual(statesByName["three.mov"], .sent)
        let sentMessages = await repository.sentMessages
        XCTAssertEqual(sentMessages.count, 2)
        XCTAssertNotNil(model.errorMessage)
    }

    // [修改] 上传失败只重试失败的那一条，并复用原 clientMsgId；重试成功后删除其暂存文件。
    func testRetryAttachmentUploadKeepsOtherMessagesAndRemovesStagedFileAfterSuccess() async throws {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 99))
        let uploader = RecoveringConversationAttachmentUploader(failingFirstAttemptNames: ["retry.pdf"])
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        let successfulSource = try temporaryFile(name: "success.pdf", contents: "success")
        let retrySource = try temporaryOutgoingAttachment(name: "retry.pdf", contents: "retry")

        await model.sendAttachments([successfulSource, retrySource])

        let successfulBeforeRetry = try XCTUnwrap(model.messages.first { $0.sendStatus == .sent })
        let failedBeforeRetry = try XCTUnwrap(model.messages.first { $0.sendStatus == .failed })
        let failedClientMessageId = try XCTUnwrap(failedBeforeRetry.clientMsgId)
        XCTAssertEqual(successfulBeforeRetry.sendStatus, .sent)
        XCTAssertEqual(failedBeforeRetry.sendStatus, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retrySource.path))

        await model.retry(messageID: failedBeforeRetry.id)

        let successfulAfterRetry = try XCTUnwrap(model.messages.first { $0.clientMsgId == successfulBeforeRetry.clientMsgId })
        let retried = try XCTUnwrap(model.messages.first { $0.clientMsgId == failedClientMessageId })
        XCTAssertEqual(successfulAfterRetry.sendStatus, .sent)
        XCTAssertEqual(retried.sendStatus, .sent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retrySource.path))
        let retryAttempts = await uploader.attempts.filter { $0.name == "retry.pdf" }
        XCTAssertEqual(retryAttempts.map(\.batchId), [failedClientMessageId, failedClientMessageId])
    }

    // [修改] 用户退出会话并释放视图模型后，未重试的失败附件必须回收，不能永久留在暂存目录。
    func testFailedManagedAttachmentIsRemovedWhenConversationModelIsReleased() async throws {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 99))
        let source = try temporaryOutgoingAttachment(name: "abandoned.pdf", contents: "abandoned")
        let uploader = SelectiveConversationAttachmentUploader(
            failingNames: [source.lastPathComponent]
        )
        var model: ChatConversationViewModel? = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )

        await model?.sendAttachments([source])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(model?.messages.first?.sendStatus, .failed)

        model = nil

        XCTAssertNil(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    // [修改] 文件已上传但聊天协议发送失败时，重试只能重发协议，不能重复上传文件。
    func testRetryAttachmentMessageAfterProtocolFailureDoesNotUploadAgain() async throws {
        let repository = ConversationRepository(
            pages: [],
            receipt: ChatReceipt.fixture(messageId: 777),
            mixedSendFailuresRemaining: 1
        )
        let uploader = ConversationAttachmentUploader()
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        let source = try temporaryOutgoingAttachment(name: "protocol.pdf", contents: "protocol")

        await model.sendAttachments([source])

        let failed = try XCTUnwrap(model.messages.first)
        let clientMessageId = try XCTUnwrap(failed.clientMsgId)
        XCTAssertEqual(failed.sendStatus, .failed)
        XCTAssertGreaterThan(failed.mixedContent?.attachments.first?.fileId ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        await model.retry(messageID: failed.id)

        let retried = try XCTUnwrap(model.messages.first)
        XCTAssertEqual(retried.sendStatus, .sent)
        XCTAssertEqual(retried.messageId, 777)
        let uploadedNames = await uploader.uploadedNames
        XCTAssertEqual(uploadedNames.count, 1)
        let sentClientMessageIds = await repository.sentClientMessageIds
        XCTAssertEqual(sentClientMessageIds, [clientMessageId, clientMessageId])
    }

    // [修改] 缓存仓库广播发送成功事件后，附件消息在当前会话中仍只能显示一条。
    func testSendAttachmentsDeduplicatesOutgoingRepositoryEvent() async throws {
        let repository = ConversationRepository(
            pages: [],
            receipt: ChatReceipt.fixture(messageId: 99),
            echoSentMessages: true
        )
        let uploader = ConversationAttachmentUploader()
        let model = ChatConversationViewModel(
            friendId: 9,
            currentUserId: 7,
            repository: repository,
            attachmentUploader: uploader
        )
        let observation = Task { await model.observeIncoming() }
        await Task.yield()
        let file = try temporaryFile(name: "one.pdf", contents: "one")

        await model.sendAttachments([file])
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.messages.count, 1)
        observation.cancel()
    }


    func testSendFailureKeepsFailedMessageAndRetryReusesClientMessageId() async {
        let repository = ConversationRepository(pages: [], receipt: ChatReceipt.fixture(messageId: 88), sendFailuresRemaining: 1)
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        model.draft = "retry me"

        await model.send()

        XCTAssertEqual(model.messages.count, 1)
        let failed = try? XCTUnwrap(model.messages.last)
        XCTAssertEqual(failed?.content, "retry me")
        XCTAssertEqual(failed?.sendStatus, .failed)
        let firstClientId = await repository.firstSentClientMessageId

        await model.retry(messageID: failed?.id ?? "")

        XCTAssertEqual(model.messages.last?.sendStatus, .sent)
        let sentIds = await repository.sentClientMessageIds
        XCTAssertEqual(sentIds.count, 2)
        XCTAssertEqual(sentIds[0], sentIds[1])
        XCTAssertEqual(sentIds[0], firstClientId)
    }

    func testIncomingPushDeduplicatesByClientMessageId() async {
        let repository = ConversationRepository(pages: [])
        let model = ChatConversationViewModel(friendId: 9, currentUserId: 7, repository: repository)
        let observation = Task { await model.observeIncoming() }
        await Task.yield()

        await repository.emit(.fixture(id: 91, senderId: 9, receiverId: 7, content: "once", clientMsgId: "push-1"))
        await repository.emit(.fixture(id: 92, senderId: 9, receiverId: 7, content: "once-again", clientMsgId: "push-1"))
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages.first?.content, "once")
        observation.cancel()
    }


    func testMessageStatusTextShowsLocalSendProgress() {
        let sending = ChatMessage(messageId: 0, senderId: 7, receiverId: 9, content: "hi", clientMsgId: "c1", isMine: true, sendStatus: .sending)
        let failed = ChatMessage(messageId: 0, senderId: 7, receiverId: 9, content: "hi", clientMsgId: "c2", isMine: true, sendStatus: .failed)
        let sent = ChatMessage(messageId: 5, senderId: 7, receiverId: 9, content: "hi", clientMsgId: "c3", isMine: true, sendStatus: .sent)

        XCTAssertEqual(sending.statusText, "发送中")
        XCTAssertEqual(failed.statusText, "发送失败")
        XCTAssertEqual(sent.statusText, "已发送")
    }

    // [修改] 负数 fileId 只是本地发送占位，不能进入远端下载或预览链路。
    func testLocalAttachmentPlaceholderCannotOpenRemotePreview() {
        let local = ChatAttachment(fileId: -1, fileName: "pending.pdf", fileSize: 10, mimeType: "application/pdf")
        let remote = ChatAttachment(fileId: 99, fileName: "sent.pdf", fileSize: 10, mimeType: "application/pdf")

        XCTAssertFalse(local.canOpenRemotePreview)
        XCTAssertTrue(remote.canOpenRemotePreview)
    }

    // [修改] 相册照片最多 9 张；文件入口即使选到媒体文件，也不能混合图片和视频。
    func testAttachmentSelectionRulesRejectTooManyPhotosAndMixedMedia() throws {
        let photos = (1...10).map { URL(fileURLWithPath: "/tmp/photo\($0).jpg") }
        XCTAssertThrowsError(
            try ChatAttachmentSelectionRules.validate(photos, source: .photoLibraryImages)
        ) { error in
            XCTAssertEqual(error as? ChatAttachmentSelectionError, .tooManyPhotos(maximum: 9))
        }

        let mixed = [
            URL(fileURLWithPath: "/tmp/photo.jpg"),
            URL(fileURLWithPath: "/tmp/movie.mov"),
        ]
        XCTAssertThrowsError(
            try ChatAttachmentSelectionRules.validate(mixed, source: .files)
        ) { error in
            XCTAssertEqual(error as? ChatAttachmentSelectionError, .mixedImagesAndVideos)
        }
    }

    // [修改] PhotosPicker 已生成的暂存文件只能通过移动改名，不能再复制出第二份大文件。
    func testAttachmentStagingRenamesTransferredFileWithoutLeavingDuplicate() async throws {
        let source = try temporaryFile(name: "camera.jpg", contents: "image-data")
        let transferred = try ChatAttachmentStaging.copyTransferredFile(source, fallbackExtension: "jpg")

        let renamed = try await ChatAttachmentStaging.renameTransferredFile(
            transferred,
            preferredFileName: "照片 1.jpg"
        )

        XCTAssertNotEqual(renamed.standardizedFileURL, transferred.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transferred.path))
        XCTAssertEqual(try Data(contentsOf: renamed), Data("image-data".utf8))
        ChatAttachmentStaging.removeIfManaged(renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // [修改] “文件”App 的安全域文件在后台复制到受管目录，原文件必须保留。
    func testAttachmentStagingCopiesImportedFileIntoManagedDirectory() async throws {
        let source = try temporaryFile(name: "report.pdf", contents: "report-data")

        let staged = try await ChatAttachmentStaging.copyImportedFile(
            source,
            preferredFileName: "报告.pdf"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(staged.standardizedFileURL.path.hasPrefix(ChatAttachmentStaging.directoryURL.standardizedFileURL.path + "/"))
        XCTAssertEqual(try Data(contentsOf: staged), Data("report-data".utf8))
        ChatAttachmentStaging.removeIfManaged(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    // [修改] 大文件仍在准备时，后选的小文件只能进入同一串行队列，不能反超先选批次。
    func testAttachmentPreparationQueuePreservesSelectionOrder() {
        let queue = ChatAttachmentPreparationQueue<String>()

        XCTAssertTrue(queue.enqueue("large-first"))
        XCTAssertFalse(queue.enqueue("small-second"))
        XCTAssertEqual(queue.dequeue(), "large-first")
        XCTAssertEqual(queue.dequeue(), "small-second")
        XCTAssertNil(queue.dequeue())
        XCTAssertTrue(queue.enqueue("third"))
    }

    // [修改] 来源面板关闭前不能直接弹相册或文件选择器，否则 iOS 会吞掉第二次系统展示请求。
    func testAttachmentPickerPresentsDestinationOnlyAfterSourceSheetDismisses() {
        for destination in ChatAttachmentPickerDestination.allCases {
            var state = ChatAttachmentPickerPresentationState()

            state.showSourcePicker()
            state.select(destination)

            XCTAssertFalse(state.isSourcePickerPresented)
            XCTAssertNil(state.presentedDestination)

            state.sourcePickerDidDismiss()

            XCTAssertEqual(state.presentedDestination, destination)
        }
    }

    // [修改] 取消来源、关闭目标或重复点加号后必须能再次打开系统选择器，不能残留旧目标。
    func testAttachmentPickerRecoversAfterCancellationAndPreventsOverlappingPresentation() {
        var state = ChatAttachmentPickerPresentationState()

        state.showSourcePicker()
        state.setSourcePickerPresented(false)
        state.sourcePickerDidDismiss()
        XCTAssertNil(state.presentedDestination)

        state.showSourcePicker()
        state.select(.files)
        state.sourcePickerDidDismiss()
        XCTAssertEqual(state.presentedDestination, .files)

        state.showSourcePicker()
        XCTAssertFalse(state.isSourcePickerPresented)
        XCTAssertEqual(state.presentedDestination, .files)

        state.setDestinationPresented(false, destination: .files)
        state.showSourcePicker()
        XCTAssertTrue(state.isSourcePickerPresented)
        state.select(.photos)
        state.sourcePickerDidDismiss()
        XCTAssertEqual(state.presentedDestination, .photos)
    }

    // [修改] 并发准备同名资源时，目标名称选择和文件移动必须是一个原子操作，不能互相覆盖或报错。
    func testAttachmentStagingKeepsConcurrentSameNameMovesUnique() async throws {
        var transferred: [URL] = []
        for index in 0..<32 {
            let source = try temporaryFile(name: "camera-\(index).jpg", contents: "image-\(index)")
            transferred.append(try ChatAttachmentStaging.copyTransferredFile(source, fallbackExtension: "jpg"))
        }

        let renamed = try await withThrowingTaskGroup(of: URL.self) { group in
            for source in transferred {
                group.addTask {
                    try await ChatAttachmentStaging.renameTransferredFile(
                        source,
                        preferredFileName: "照片 1.jpg"
                    )
                }
            }
            var values: [URL] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        defer { renamed.forEach(ChatAttachmentStaging.removeIfManaged) }

        XCTAssertEqual(renamed.count, transferred.count)
        XCTAssertEqual(Set(renamed.map(\.lastPathComponent)).count, transferred.count)
        XCTAssertTrue(renamed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func temporaryFile(name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func temporaryOutgoingAttachment(name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStorage/OutgoingAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(contents.utf8).write(to: url)
        return url
    }
}

// [修改] 等待真实聊天状态，避免模拟器繁忙时固定延时导致偶发失败。
@MainActor
private func waitForConversationCondition(
    _ description: String,
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ConversationTestTimeout(description: description)
}

private struct ConversationTestTimeout: Error, CustomStringConvertible {
    let description: String
}

private actor ConversationAttachmentUploader: ChatAttachmentUploading {
    private(set) var uploadedNames: [String] = []

    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        uploadedNames.append(sourceURL.lastPathComponent)
        let fileId = Int64(100 + uploadedNames.count)
        return ChatAttachment(
            kind: sourceURL.pathExtension.lowercased() == "jpg" ? "image" : "file",
            fileId: fileId,
            fileName: sourceURL.lastPathComponent,
            fileSize: Int64(try Data(contentsOf: sourceURL).count),
            mimeType: sourceURL.pathExtension.lowercased() == "jpg" ? "image/jpeg" : "application/pdf"
        )
    }
}

// [修改] 保持上传挂起一小段时间，验证视图模型会先插入每条本地“发送中”消息。
private actor SlowConversationAttachmentUploader: ChatAttachmentUploading {
    private let delay: Duration
    private var nextFileId: Int64 = 200
    private(set) var uploadedNames: [String] = []

    init(delay: Duration) {
        self.delay = delay
    }

    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        uploadedNames.append(sourceURL.lastPathComponent)
        try await Task.sleep(for: delay)
        nextFileId += 1
        return try attachment(for: sourceURL, fileId: nextFileId)
    }
}

// [修改] 精确让一个资源上传失败，锁定同批其他资源仍能继续成功的行为。
private actor SelectiveConversationAttachmentUploader: ChatAttachmentUploading {
    private let failingNames: Set<String>
    private var nextFileId: Int64 = 300

    init(failingNames: Set<String>) {
        self.failingNames = failingNames
    }

    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        if failingNames.contains(sourceURL.lastPathComponent) {
            throw ChatRepositoryError.server(message: "upload failed")
        }
        nextFileId += 1
        return try attachment(for: sourceURL, fileId: nextFileId)
    }
}

private actor RecoveringConversationAttachmentUploader: ChatAttachmentUploading {
    struct Attempt: Equatable, Sendable {
        let name: String
        let batchId: String
    }

    private let failingFirstAttemptNames: Set<String>
    private var failedNames: Set<String> = []
    private var nextFileId: Int64 = 400
    private(set) var attempts: [Attempt] = []

    init(failingFirstAttemptNames: Set<String>) {
        self.failingFirstAttemptNames = failingFirstAttemptNames
    }

    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        let name = sourceURL.lastPathComponent.components(separatedBy: "-").last ?? sourceURL.lastPathComponent
        attempts.append(Attempt(name: name, batchId: batchId))
        if failingFirstAttemptNames.contains(name), failedNames.insert(name).inserted {
            throw ChatRepositoryError.server(message: "upload failed")
        }
        nextFileId += 1
        let uploaded = try attachment(for: sourceURL, fileId: nextFileId)
        return ChatAttachment(
            kind: uploaded.kind,
            fileId: uploaded.fileId,
            fileName: name,
            fileSize: uploaded.fileSize,
            mimeType: uploaded.mimeType
        )
    }
}

private func attachment(for sourceURL: URL, fileId: Int64) throws -> ChatAttachment {
    let fileExtension = sourceURL.pathExtension.lowercased()
    let mimeType: String
    if fileExtension == "jpg" {
        mimeType = "image/jpeg"
    } else if fileExtension == "mov" {
        mimeType = "video/quicktime"
    } else {
        mimeType = "application/pdf"
    }
    return ChatAttachment(
        kind: mimeType.hasPrefix("image/") ? "image" : "file",
        fileId: fileId,
        fileName: sourceURL.lastPathComponent,
        fileSize: Int64(try Data(contentsOf: sourceURL).count),
        mimeType: mimeType
    )
}

private actor ConversationRepository: ChatRepository {
    private var pages: [ChatHistoryPage]
    private let receipt: ChatReceipt
    private let cachedPage: ChatHistoryPage?
    private let historyError: Error?
    private let historyDelay: Duration?
    private let textSendDelay: Duration?
    private let echoSentMessages: Bool
    private let eventBroadcaster = ChatEventBroadcaster()
    nonisolated var messages: AsyncStream<ChatMessage> { messageStream(from: eventStream()) }
    nonisolated func eventStream() -> AsyncStream<ChatEvent> { eventBroadcaster.stream() }
    private(set) var readFriendIds: [Int64] = []
    private(set) var sentContents: [String] = []
    private(set) var sentClientMessageIds: [String] = []
    private(set) var sendFailuresRemaining: Int
    var firstSentClientMessageId: String? { sentClientMessageIds.first }
    private(set) var sentMessages: [(content: String, messageType: String)] = []
    private(set) var historyBeforeMessageIds: [Int64?] = []
    private var mixedSendFailuresRemaining: Int
    private let localDeleteError: Error?
    private let retractError: Error?
    private let clearLocalError: Error?
    private(set) var sentQuotes: [ChatQuote?] = []
    private(set) var locallyDeletedMessageIDs: [String] = []
    private(set) var retractedMessageIDs: [Int64] = []
    private(set) var clearedFriendIDs: [Int64] = []
    private(set) var favoriteUpdates: [FavoriteUpdate] = []
    private(set) var forwardedMessages: [ForwardedMessage] = []
    private(set) var reactionRequests: [ReactionRequest] = []
    private let reactionResult: [String: [Int64]]

    init(
        pages: [ChatHistoryPage],
        receipt: ChatReceipt = .fixture(messageId: 1),
        cachedPage: ChatHistoryPage? = nil,
        historyError: Error? = nil,
        historyDelay: Duration? = nil,
        textSendDelay: Duration? = nil,
        sendFailuresRemaining: Int = 0,
        mixedSendFailuresRemaining: Int = 0,
        echoSentMessages: Bool = false,
        localDeleteError: Error? = nil,
        retractError: Error? = nil,
        clearLocalError: Error? = nil,
        reactionResult: [String: [Int64]] = [:]
    ) {
        self.pages = pages
        self.receipt = receipt
        self.cachedPage = cachedPage
        self.historyError = historyError
        self.historyDelay = historyDelay
        self.textSendDelay = textSendDelay
        self.sendFailuresRemaining = sendFailuresRemaining
        self.mixedSendFailuresRemaining = mixedSendFailuresRemaining
        self.echoSentMessages = echoSentMessages
        self.localDeleteError = localDeleteError
        self.retractError = retractError
        self.clearLocalError = clearLocalError
        self.reactionResult = reactionResult
    }

    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage {
        historyBeforeMessageIds.append(beforeMessageId)
        if let historyError { throw historyError }
        if let historyDelay { try await Task.sleep(for: historyDelay) }
        // [修改] 前置错误判断后不能依赖单表达式隐式返回，显式返回测试页。
        return pages.isEmpty ? ChatHistoryPage(messages: [], hasMore: false, nextBeforeMessageId: nil, latestMessageId: nil) : pages.removeFirst()
    }
    func cachedHistory(friendId: Int64, beforeMessageId: Int64?, limit: Int) async -> ChatHistoryPage? { cachedPage }
    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt {
        sentContents.append(content)
        sentClientMessageIds.append(clientMessageId)
        if let textSendDelay { try await Task.sleep(for: textSendDelay) }
        if sendFailuresRemaining > 0 {
            sendFailuresRemaining -= 1
            throw ChatRepositoryError.server(message: "send failed")
        }
        return receipt
    }
    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String) async throws -> ChatReceipt {
        try await send(friendId: friendId, content: content, messageType: messageType, clientMessageId: clientMessageId, quote: nil)
    }
    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String, quote: ChatQuote?) async throws -> ChatReceipt {
        // [修改] 文本发送即使带引用也仍走文本故障、延时和记录链路，不能被测试夹具误当成附件发送。
        if messageType.caseInsensitiveCompare("TEXT") == .orderedSame {
            sentQuotes.append(quote)
            return try await send(
                friendId: friendId,
                content: content,
                clientMessageId: clientMessageId
            )
        }
        sentMessages.append((content, messageType))
        sentClientMessageIds.append(clientMessageId)
        sentQuotes.append(quote)
        if mixedSendFailuresRemaining > 0 {
            mixedSendFailuresRemaining -= 1
            throw ChatRepositoryError.server(message: "mixed send failed")
        }
        if echoSentMessages {
            eventBroadcaster.yield(.message(ChatMessage(
                messageId: receipt.messageId,
                senderId: 7,
                receiverId: friendId,
                content: content,
                msgType: messageType,
                clientMsgId: clientMessageId,
                isMine: true,
                quote: quote
            )))
            await Task.yield()
        }
        return receipt
    }
    func retract(messageId: Int64, friendId: Int64) async throws {
        retractedMessageIDs.append(messageId)
        if let retractError { throw retractError }
        eventBroadcaster.yield(.messageAction(ChatMessageAction(action: "RETRACT", messageId: messageId, friendId: friendId)))
    }
    func deleteLocal(message: ChatMessage, friendId: Int64) async throws {
        locallyDeletedMessageIDs.append(message.id)
        if let localDeleteError { throw localDeleteError }
    }
    func clearLocalConversation(friendId: Int64) async throws {
        clearedFriendIDs.append(friendId)
        if let clearLocalError { throw clearLocalError }
    }
    func setFavorite(message: ChatMessage, isFavorite: Bool, friendId: Int64) async throws {
        favoriteUpdates.append(FavoriteUpdate(messageID: message.id, isFavorite: isFavorite))
    }
    func favoriteMessages() async -> [ChatMessage] { [] }
    func forward(message: ChatMessage, to friendId: Int64, sourceName: String) async throws {
        forwardedMessages.append(ForwardedMessage(
            friendId: friendId,
            content: message.conversationSummary,
            forwardFrom: sourceName
        ))
    }
    func react(messageId: Int64, friendId: Int64, emoji: String) async throws -> ChatMessageAction {
        reactionRequests.append(ReactionRequest(messageId: messageId, friendId: friendId, emoji: emoji))
        return ChatMessageAction(
            action: "REACTION",
            messageId: messageId,
            friendId: friendId,
            reaction: reactionResult
        )
    }
    func markRead(friendId: Int64) async throws { readFriendIds.append(friendId) }
    func emit(_ message: ChatMessage) { eventBroadcaster.yield(.message(message)) }
    func emitAction(_ action: ChatMessageAction) { eventBroadcaster.yield(.messageAction(action)) }
    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] { [] }
    func addFriend(userId: Int64, message: String) async throws {}
    func pendingRequests() async throws -> [FriendRequestItem] { [] }
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws {}
    func updateAlias(relationshipId: Int64, alias: String) async throws {}
}

private struct FavoriteUpdate: Equatable {
    let messageID: String
    let isFavorite: Bool
}

private struct ForwardedMessage: Equatable {
    let friendId: Int64
    let content: String
    let forwardFrom: String
}

private struct ReactionRequest: Equatable {
    let messageId: Int64
    let friendId: Int64
    let emoji: String
}

private extension ChatMessage {
    static func fixture(id: Int64, senderId: Int64 = 9, receiverId: Int64 = 7, content: String, clientMsgId: String? = nil) -> ChatMessage {
        ChatMessage(messageId: id, senderId: senderId, receiverId: receiverId, content: content, clientMsgId: clientMsgId, createdAt: id)
    }
}

private extension ChatReceipt {
    static func fixture(messageId: Int64) -> ChatReceipt {
        // [修改] 使用调用方传入的回执 ID，避免硬编码 88 掩盖逐条消息替换错误。
        let json = #"{"success":true,"data":{"messageId":\#(messageId),"status":"SUCCESS","clientMsgId":"test"}}"#
        return try! ProtocolJSON.decoder().decode(ChatReceipt.self, from: Data(json.utf8))
    }
}
