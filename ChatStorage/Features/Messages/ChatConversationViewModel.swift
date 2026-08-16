import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ChatConversationViewModel {
    let friendId: Int64
    let currentUserId: Int64
    private(set) var messages: [ChatMessage] = []
    private(set) var hasOlderMessages = true
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var errorMessage: String?
    var draft = ""
    private(set) var quotedMessage: ChatQuote?
    private(set) var favoriteMessages: [ChatMessage] = []

    private let repository: any ChatRepository
    private let attachmentUploader: (any ChatAttachmentUploading)?
    private var beforeMessageId: Int64?
    private var hasLoadedRemoteHistory = false
    // [修改] 上传阶段失败时保留本地资源，用户点击单条“重试”会重新上传这一条，不影响同批其他消息。
    private let retryAttachmentSources = ManagedChatAttachmentSourceStore()
    // [修改] 附件批次串行排队，用户连续选择时后一批不会被全局发送状态丢弃。
    private var pendingAttachmentBatches: [PendingAttachmentBatch] = []
    private var nextLocalAttachmentId: Int64 = -1

    init(
        friendId: Int64,
        currentUserId: Int64,
        repository: any ChatRepository,
        attachmentUploader: (any ChatAttachmentUploading)? = nil
    ) {
        self.friendId = friendId
        self.currentUserId = currentUserId
        self.repository = repository
        self.attachmentUploader = attachmentUploader
    }

    func load() async {
        guard !isLoading else { return }
        if messages.isEmpty,
           let cached = await repository.cachedHistory(friendId: friendId, beforeMessageId: nil, limit: 20) {
            messages = merging(
                cached.messages.map { $0.withMine(currentUserId: currentUserId) },
                with: messages
            )
            refreshFavoriteMessages()
            beforeMessageId = cached.nextBeforeMessageId
            hasOlderMessages = cached.hasMore
        }
        isLoading = true
        errorMessage = nil
        let shouldReplacePagination = !hasLoadedRemoteHistory
        defer { isLoading = false }
        do {
            let page = try await repository.history(friendId: friendId, beforeMessageId: nil, limit: 20)
            // [修改] 历史响应只补齐服务端数据，保留请求期间到达的推送和本地发送状态。
            messages = merging(
                page.messages.map { $0.withMine(currentUserId: currentUserId) },
                with: messages
            )
            refreshFavoriteMessages()
            // [修改] 首次远端加载建立游标；后续下拉刷新只补最新页，保留已加载到的旧历史位置。
            if shouldReplacePagination {
                beforeMessageId = page.nextBeforeMessageId
                hasOlderMessages = page.hasMore
            }
            hasLoadedRemoteHistory = true
            try? await repository.markRead(friendId: friendId)
        } catch {
            if messages.isEmpty { errorMessage = (error as? LocalizedError)?.errorDescription ?? "聊天记录加载失败" }
        }
    }

    func loadOlder() async {
        guard hasOlderMessages, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.history(friendId: friendId, beforeMessageId: beforeMessageId, limit: 20)
            let older = page.messages.map { $0.withMine(currentUserId: currentUserId) }
            messages = merging(older, with: messages)
            refreshFavoriteMessages()
            beforeMessageId = page.nextBeforeMessageId
            hasOlderMessages = page.hasMore
            hasLoadedRemoteHistory = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "更多聊天记录加载失败"
        }
    }

    func send() async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isSending else { return }
        // [修改] 文本进入本地发送队列后立即释放输入框，迟到回执不能清掉用户随后输入的新内容。
        draft = ""
        let quote = quotedMessage
        quotedMessage = nil
        isSending = true
        errorMessage = nil
        let clientMessageId = UUID().uuidString
        let localMessage = ChatMessage(
            messageId: 0,
            senderId: currentUserId,
            receiverId: friendId,
            content: content,
            clientMsgId: clientMessageId,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
            isMine: true,
            sendStatus: .sending,
            quote: quote
        )
        messages.append(localMessage)
        do {
            let receipt = try await repository.send(
                friendId: friendId,
                content: content,
                messageType: "TEXT",
                clientMessageId: clientMessageId,
                quote: quote
            )
            replace(localMessage.id, with: ChatMessage(
                messageId: receipt.messageId,
                senderId: currentUserId,
                receiverId: friendId,
                content: content,
                clientMsgId: clientMessageId,
                createdAt: localMessage.createdAt,
                isMine: true,
                sendStatus: .sent,
                quote: quote
            ))
        } catch {
            replace(localMessage.id, with: localMessage.withSendStatus(.failed))
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "消息发送失败"
        }
        isSending = false
        // [修改] 文本请求期间进入的附件批次在文本结束后自动继续。
        await drainPendingAttachmentBatchesIfPossible()
    }

    // [修改] 失败消息重试复用原 clientMsgId，服务端按 clientMsgId 幂等去重，不生成新消息。
    func retry(messageID: String) async {
        guard let failed = messages.first(where: { $0.id == messageID && $0.sendStatus == .failed }), !isSending else { return }
        isSending = true
        errorMessage = nil
        let clientMessageId = failed.clientMsgId ?? UUID().uuidString
        replace(messageID, with: failed.withSendStatus(.sending))
        if let sourceURL = retryAttachmentSources[clientMessageId] {
            await retryAttachmentUpload(
                failed: failed,
                sourceURL: sourceURL,
                clientMessageId: clientMessageId
            )
            isSending = false
            await drainPendingAttachmentBatchesIfPossible()
            return
        }
        do {
            let receipt: ChatReceipt
            if failed.msgType.caseInsensitiveCompare("MIXED") == .orderedSame {
                receipt = try await repository.send(friendId: friendId, content: failed.content, messageType: failed.msgType, clientMessageId: clientMessageId, quote: failed.quote)
            } else {
                receipt = try await repository.send(friendId: friendId, content: failed.content, messageType: failed.msgType, clientMessageId: clientMessageId, quote: failed.quote)
            }
            replace(messageID, with: ChatMessage(
                messageId: receipt.messageId,
                senderId: currentUserId,
                receiverId: friendId,
                content: failed.content,
                msgType: failed.msgType,
                clientMsgId: clientMessageId,
                createdAt: failed.createdAt,
                isMine: true,
                sendStatus: .sent,
                quote: failed.quote
            ))
        } catch {
            replace(messageID, with: failed.withSendStatus(.failed))
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "消息发送失败"
        }
        isSending = false
        await drainPendingAttachmentBatchesIfPossible()
    }

    func observeIncoming() async {
        // [修改] 每个页面订阅独立事件流，避免聊天页和好友列表抢同一条推送。
        for await event in repository.eventStream() {
            switch event {
            case .message(let message):
                guard message.senderId == friendId || message.receiverId == friendId else { continue }
                let normalized = message.withMine(currentUserId: currentUserId)
                guard !messages.contains(where: { sameMessage($0, normalized) }) else { continue }
                messages.append(normalized)
                refreshFavoriteMessages()
                // [修改] 正在打开的会话收到对方消息后立即上报已读，好友列表随后收到 read 事件清角标。
                if message.senderId == friendId && message.senderId != currentUserId {
                    try? await repository.markRead(friendId: friendId)
                }
            case .messageAction(let action):
                guard action.friendId == friendId else { continue }
                if action.isRetraction {
                    applyRetraction(messageId: action.messageId)
                } else if action.isReaction, let reactions = action.reaction {
                    applyReactions(messageId: action.messageId, reactions: reactions)
                }
            case .read, .friendRelationshipChanged:
                continue
            }
        }
    }

    func insertEmoji(_ emoji: String) {
        draft.append(emoji)
    }

    func selectQuote(_ message: ChatMessage, senderName: String) {
        guard !message.retracted else { return }
        quotedMessage = ChatQuote(
            messageId: message.messageId > 0 ? message.messageId : nil,
            content: message.conversationSummary,
            senderName: senderName
        )
    }

    func cancelQuote() {
        quotedMessage = nil
    }

    func deleteLocal(messageID: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages.remove(at: index)
        errorMessage = nil
        do {
            try await repository.deleteLocal(message: message, friendId: friendId)
            if let clientMessageId = message.clientMsgId,
               let sourceURL = retryAttachmentSources.removeValue(forKey: clientMessageId) {
                ChatAttachmentStaging.removeIfManaged(sourceURL)
            }
        } catch {
            messages.insert(message, at: min(index, messages.count))
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "本地删除失败"
        }
    }

    func retract(messageID: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].isMine,
              messages[index].messageId > 0,
              !messages[index].retracted else { return }
        let original = messages[index]
        messages[index] = original.withRetraction()
        errorMessage = nil
        do {
            try await repository.retract(messageId: original.messageId, friendId: friendId)
        } catch {
            guard let currentIndex = messages.firstIndex(where: { $0.id == messageID }) else { return }
            messages[currentIndex] = original
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "消息撤回失败"
        }
    }

    func clearLocalConversation() async {
        let snapshot = messages
        messages = []
        beforeMessageId = nil
        hasOlderMessages = false
        errorMessage = nil
        do {
            try await repository.clearLocalConversation(friendId: friendId)
        } catch {
            messages = snapshot
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "清空聊天记录失败"
        }
    }

    // [修改] 收藏是本机功能，失败时恢复原状态，避免 UI 和磁盘缓存不一致。
    func toggleFavorite(messageID: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let original = messages[index]
        let next = !original.isFavorite
        messages[index] = original.withFavorite(next)
        refreshFavoriteMessages()
        errorMessage = nil
        do {
            try await repository.setFavorite(message: original, isFavorite: next, friendId: friendId)
        } catch {
            guard let currentIndex = messages.firstIndex(where: { $0.id == messageID }) else { return }
            messages[currentIndex] = original
            refreshFavoriteMessages()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "稍后处理操作失败"
        }
    }

    func loadFavorites() async {
        favoriteMessages = await repository.favoriteMessages()
    }

    func forward(messageID: String, to targetFriendId: Int64, sourceName: String) async {
        guard targetFriendId > 0,
              let message = messages.first(where: { $0.id == messageID }),
              !message.retracted else { return }
        errorMessage = nil
        do {
            try await repository.forward(message: message, to: targetFriendId, sourceName: sourceName)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "消息转发失败"
        }
    }

    func sendReaction(messageID: String, emoji: String) async {
        guard !emoji.isEmpty,
              let message = messages.first(where: { $0.id == messageID }),
              message.messageId > 0,
              !message.retracted else { return }
        errorMessage = nil
        do {
            let action = try await repository.react(
                messageId: message.messageId,
                friendId: friendId,
                emoji: emoji
            )
            if let reactions = action.reaction {
                applyReactions(messageId: action.messageId, reactions: reactions)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "表情回应失败"
        }
    }

    // [修改] 每个资源独立生成一条 MIXED 消息；每条都有自己的 clientMsgId、发送中、成功和失败状态。
    func sendAttachments(_ sourceURLs: [URL]) async {
        guard attachmentUploader != nil else {
            // [修改] 调用方交付后由视图模型接管暂存文件；无上传器时也要立即回收。
            sourceURLs.forEach(ChatAttachmentStaging.removeIfManaged)
            errorMessage = "当前账号没有可用的附件传输凭据"
            return
        }
        guard !sourceURLs.isEmpty else { return }

        let draftText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = quotedMessage
        draft = ""
        quotedMessage = nil
        pendingAttachmentBatches.append(PendingAttachmentBatch(
            sourceURLs: sourceURLs,
            draftText: draftText,
            quote: quote
        ))

        await drainPendingAttachmentBatchesIfPossible()
    }

    private func drainPendingAttachmentBatchesIfPossible() async {
        // [修改] 已有批次、文本或重试正在发送时只保留队列，由当前操作结束点再次触发。
        guard !isSending,
              !pendingAttachmentBatches.isEmpty,
              let attachmentUploader else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        while !pendingAttachmentBatches.isEmpty {
            let batch = pendingAttachmentBatches.removeFirst()
            await sendAttachmentBatch(batch, using: attachmentUploader)
        }
    }

    private func sendAttachmentBatch(
        _ batch: PendingAttachmentBatch,
        using attachmentUploader: any ChatAttachmentUploading
    ) async {
        let createdAt = Int64(Date().timeIntervalSince1970 * 1_000)
        var pendingMessages: [PendingAttachmentMessage] = []

        // [修改] 网络上传前先一次性插入全部本地消息，选择多个大文件时每条都会立即显示“发送中”。
        for (index, sourceURL) in batch.sourceURLs.enumerated() {
            let clientMessageId = UUID().uuidString
            let text = index == 0 ? batch.draftText : ""
            let quote = index == 0 ? batch.quote : nil
            let placeholder = localAttachment(for: sourceURL)
            guard let content = try? encodedMixedContent(text: text, attachment: placeholder) else { continue }
            let localMessage = ChatMessage(
                messageId: 0,
                senderId: currentUserId,
                receiverId: friendId,
                content: content,
                msgType: "MIXED",
                clientMsgId: clientMessageId,
                createdAt: createdAt + Int64(index),
                isMine: true,
                sendStatus: .sending,
                quote: quote
            )
            messages.append(localMessage)
            pendingMessages.append(PendingAttachmentMessage(
                messageID: localMessage.id,
                clientMessageId: clientMessageId,
                sourceURL: sourceURL,
                text: text,
                createdAt: localMessage.createdAt,
                quote: quote
            ))
        }

        var failedNames: [String] = []
        for pending in pendingMessages {
            var uploadedContent: String?
            do {
                let attachment = try await attachmentUploader.upload(
                    sourceURL: pending.sourceURL,
                    batchId: pending.clientMessageId
                )
                // [修改] 上传已完成后不再需要本地副本；协议发送失败可直接复用真实 fileId 重试。
                ChatAttachmentStaging.removeIfManaged(pending.sourceURL)
                let content = try encodedMixedContent(text: pending.text, attachment: attachment)
                uploadedContent = content
                // [修改] 上传成功后立即把占位附件替换成真实 fileId；后续消息发送失败可直接重发协议消息。
                replace(pending.messageID, with: outgoingAttachmentMessage(
                    messageId: 0,
                    content: content,
                    clientMessageId: pending.clientMessageId,
                    createdAt: pending.createdAt,
                    sendStatus: .sending,
                    quote: pending.quote
                ))
                retryAttachmentSources.removeValue(forKey: pending.clientMessageId)
                let receipt = try await repository.send(
                    friendId: friendId,
                    content: content,
                    messageType: "MIXED",
                    clientMessageId: pending.clientMessageId,
                    quote: pending.quote
                )
                replace(pending.messageID, with: outgoingAttachmentMessage(
                    messageId: receipt.messageId,
                    content: content,
                    clientMessageId: pending.clientMessageId,
                    createdAt: pending.createdAt,
                    sendStatus: .sent,
                    quote: pending.quote
                ))
            } catch {
                if uploadedContent == nil {
                    // [修改] 只有上传失败才需要保存源文件；服务端发消息失败已经有真实附件协议，可直接重发。
                    retryAttachmentSources[pending.clientMessageId] = pending.sourceURL
                }
                if let current = messages.first(where: { $0.id == pending.messageID }) {
                    replace(pending.messageID, with: current.withSendStatus(.failed))
                }
                failedNames.append(pending.sourceURL.lastPathComponent)
            }
        }
        if !failedNames.isEmpty {
            errorMessage = failedNames.count == 1
                ? "附件发送失败：\(failedNames[0])"
                : "\(failedNames.count) 个附件发送失败，可逐条重试"
        }
    }

    func clearError() { errorMessage = nil }

    private func merging(_ serverMessages: [ChatMessage], with currentMessages: [ChatMessage]) -> [ChatMessage] {
        deduplicating(serverMessages + currentMessages).sorted(by: Self.messageOrder)
    }

    private func deduplicating(_ values: [ChatMessage]) -> [ChatMessage] {
        var seenServerMessageIDs = Set<Int64>()
        var seenClientMessageIDs = Set<String>()
        var result: [ChatMessage] = []
        for message in values {
            if message.messageId > 0, seenServerMessageIDs.contains(message.messageId) {
                if let index = result.firstIndex(where: { $0.messageId == message.messageId }) {
                    result[index] = result[index].mergingLocalState(from: message)
                }
                continue
            }
            if let clientMessageId = message.clientMsgId,
               !clientMessageId.isEmpty,
               seenClientMessageIDs.contains(clientMessageId) {
                if let index = result.firstIndex(where: { $0.clientMsgId == clientMessageId }) {
                    result[index] = result[index].mergingLocalState(from: message)
                }
                continue
            }
            if message.messageId > 0 { seenServerMessageIDs.insert(message.messageId) }
            if let clientMessageId = message.clientMsgId, !clientMessageId.isEmpty { seenClientMessageIDs.insert(clientMessageId) }
            result.append(message)
        }
        return result
    }

    private func sameMessage(_ left: ChatMessage, _ right: ChatMessage) -> Bool {
        if left.messageId > 0, right.messageId > 0, left.messageId == right.messageId { return true }
        guard let leftClientMessageId = left.clientMsgId,
              let rightClientMessageId = right.clientMsgId,
              !leftClientMessageId.isEmpty else {
            return false
        }
        return leftClientMessageId == rightClientMessageId
    }

    private func replace(_ messageID: String, with replacement: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index] = replacement
    }

    private func applyRetraction(messageId: Int64) {
        guard let index = messages.firstIndex(where: { $0.messageId == messageId }) else { return }
        messages[index] = messages[index].withRetraction()
    }

    private func applyReactions(messageId: Int64, reactions: [String: [Int64]]) {
        guard let index = messages.firstIndex(where: { $0.messageId == messageId }) else { return }
        messages[index] = messages[index].withReactions(reactions)
        refreshFavoriteMessages()
    }

    private func refreshFavoriteMessages() {
        favoriteMessages = messages.filter(\.isFavorite)
    }

    private func retryAttachmentUpload(
        failed: ChatMessage,
        sourceURL: URL,
        clientMessageId: String
    ) async {
        guard let attachmentUploader else {
            replace(failed.id, with: failed.withSendStatus(.failed))
            errorMessage = "当前账号没有可用的附件传输凭据"
            return
        }
        do {
            let text = failed.mixedContent?.text ?? ""
            let attachment = try await attachmentUploader.upload(sourceURL: sourceURL, batchId: clientMessageId)
            // [修改] 重传成功即释放暂存文件，后续协议发送失败不再重复上传。
            ChatAttachmentStaging.removeIfManaged(sourceURL)
            let content = try encodedMixedContent(text: text, attachment: attachment)
            let sendingMessage = outgoingAttachmentMessage(
                messageId: 0,
                content: content,
                clientMessageId: clientMessageId,
                createdAt: failed.createdAt,
                sendStatus: .sending,
                quote: failed.quote
            )
            replace(failed.id, with: sendingMessage)
            retryAttachmentSources.removeValue(forKey: clientMessageId)
            let receipt = try await repository.send(
                friendId: friendId,
                content: content,
                messageType: "MIXED",
                clientMessageId: clientMessageId,
                quote: failed.quote
            )
            replace(failed.id, with: outgoingAttachmentMessage(
                messageId: receipt.messageId,
                content: content,
                clientMessageId: clientMessageId,
                createdAt: failed.createdAt,
                sendStatus: .sent,
                quote: failed.quote
            ))
        } catch {
            if let current = messages.first(where: { $0.id == failed.id }) {
                replace(failed.id, with: current.withSendStatus(.failed))
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "附件发送失败"
        }
    }

    private func localAttachment(for sourceURL: URL) -> ChatAttachment {
        let contentType = UTType(filenameExtension: sourceURL.pathExtension)
        let mimeType = contentType?.preferredMIMEType ?? "application/octet-stream"
        let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        defer { nextLocalAttachmentId -= 1 }
        return ChatAttachment(
            kind: contentType?.conforms(to: .image) == true ? "image" : "file",
            fileId: nextLocalAttachmentId,
            fileName: sourceURL.lastPathComponent,
            fileSize: fileSize,
            mimeType: mimeType
        )
    }

    private func encodedMixedContent(text: String, attachment: ChatAttachment) throws -> String {
        let payload = ChatMixedMessageContent(text: text, attachments: [attachment])
        let data = try ProtocolJSON.encoder().encode(payload)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ChatRepositoryError.invalidResponse
        }
        return content
    }

    private func outgoingAttachmentMessage(
        messageId: Int64,
        content: String,
        clientMessageId: String,
        createdAt: Int64,
        sendStatus: ChatMessageSendStatus,
        quote: ChatQuote?
    ) -> ChatMessage {
        ChatMessage(
            messageId: messageId,
            senderId: currentUserId,
            receiverId: friendId,
            content: content,
            msgType: "MIXED",
            clientMsgId: clientMessageId,
            createdAt: createdAt,
            isMine: true,
            sendStatus: sendStatus,
            quote: quote
        )
    }

    private static func messageOrder(_ left: ChatMessage, _ right: ChatMessage) -> Bool {
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        if left.messageId != right.messageId { return left.messageId < right.messageId }
        return left.id < right.id
    }
}

private struct PendingAttachmentBatch: Sendable {
    let sourceURLs: [URL]
    let draftText: String
    let quote: ChatQuote?
}

private struct PendingAttachmentMessage: Sendable {
    let messageID: String
    let clientMessageId: String
    let sourceURL: URL
    let text: String
    let createdAt: Int64
    let quote: ChatQuote?
}

// [修改] 失败附件的暂存文件由会话视图模型持有；会话释放时自动回收用户放弃重试的文件。
private final class ManagedChatAttachmentSourceStore {
    private var values: [String: URL] = [:]

    subscript(clientMessageId: String) -> URL? {
        get { values[clientMessageId] }
        set { values[clientMessageId] = newValue }
    }

    @discardableResult
    func removeValue(forKey clientMessageId: String) -> URL? {
        values.removeValue(forKey: clientMessageId)
    }

    deinit {
        Set(values.values).forEach(ChatAttachmentStaging.removeIfManaged)
    }
}

private extension ChatMessage {
    func withMine(currentUserId: Int64) -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: senderId == currentUserId, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: sendStatus, quote: quote, retracted: retracted, isFavorite: isFavorite, reactions: reactions, forwardFrom: forwardFrom)
    }

    func withSendStatus(_ status: ChatMessageSendStatus) -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: self.status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: isMine, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: status, quote: quote, retracted: retracted, isFavorite: isFavorite, reactions: reactions, forwardFrom: forwardFrom)
    }

    func withRetraction() -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: isMine, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: sendStatus, quote: quote, retracted: true, isFavorite: isFavorite, reactions: reactions, forwardFrom: forwardFrom)
    }

    func withFavorite(_ value: Bool) -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: isMine, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: sendStatus, quote: quote, retracted: retracted, isFavorite: value, reactions: reactions, forwardFrom: forwardFrom)
    }

    func withReactions(_ value: [String: [Int64]]) -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: isMine, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: sendStatus, quote: quote, retracted: retracted, isFavorite: isFavorite, reactions: value, forwardFrom: forwardFrom)
    }

    func mergingLocalState(from existing: ChatMessage) -> ChatMessage {
        ChatMessage(messageId: messageId, senderId: senderId, receiverId: receiverId, content: content, msgType: msgType, status: status, avatar: avatar, groupTime: groupTime, messageTime: messageTime, clientMsgId: clientMsgId, createdAt: createdAt, isMine: isMine, conversationSeq: conversationSeq, senderDeviceId: senderDeviceId, encryptionMode: encryptionMode, keyId: keyId, sendStatus: sendStatus, quote: quote, retracted: retracted, isFavorite: isFavorite || existing.isFavorite, reactions: reactions.isEmpty ? existing.reactions : reactions, forwardFrom: forwardFrom ?? existing.forwardFrom)
    }
}
