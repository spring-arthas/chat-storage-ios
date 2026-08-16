import Foundation
import UniformTypeIdentifiers

struct ChatHistoryRequest: Codable, Equatable, Sendable {
    let friendId: Int64
    let beforeMessageId: Int64?
    let afterMessageId: Int64?
    let offset: Int?
    let limit: Int

    init(friendId: Int64, beforeMessageId: Int64? = nil, afterMessageId: Int64? = nil, offset: Int? = nil, limit: Int = 20) {
        self.friendId = friendId
        self.beforeMessageId = beforeMessageId
        self.afterMessageId = afterMessageId
        self.offset = offset
        self.limit = limit
    }
}

struct ChatQuote: Codable, Equatable, Sendable {
    let messageId: Int64?
    let content: String
    let senderName: String
}

struct SendChatMessageRequest: Codable, Equatable, Sendable {
    let receiverId: Int64
    let content: String
    let msgType: String
    let clientMsgId: String
    let quoteMsgId: Int64?
    let quoteMsgContent: String?
    let quoteMsgSenderName: String?

    init(receiverId: Int64, content: String, msgType: String = "TEXT", clientMsgId: String, quote: ChatQuote? = nil) {
        self.receiverId = receiverId
        self.content = content
        self.msgType = msgType
        self.clientMsgId = clientMsgId
        quoteMsgId = quote?.messageId
        quoteMsgContent = quote?.content
        quoteMsgSenderName = quote?.senderName
    }
}

// [修改] 与 Android 的 MIXED 消息协议保持字段一致，附件上传完成后才发送聊天消息。
struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    let kind: String
    let fileId: Int64
    let fileName: String
    let fileSize: Int64
    let mimeType: String
    let width: Int?
    let height: Int?
    let thumbnailFileId: Int64?
    let thumbnailFileSize: Int64?
    let previewFileId: Int64?
    let previewFileSize: Int64?

    var id: Int64 { fileId }
    var isImage: Bool { kind.caseInsensitiveCompare("image") == .orderedSame || mimeType.hasPrefix("image/") }
    var isVideo: Bool { mimeType.hasPrefix("video/") }
    // [修改] 非正数 ID 是本地上传占位，不能发给服务端预览接口。
    var canOpenRemotePreview: Bool { fileId > 0 }

    init(
        kind: String = "file",
        fileId: Int64,
        fileName: String,
        fileSize: Int64,
        mimeType: String,
        width: Int? = nil,
        height: Int? = nil,
        thumbnailFileId: Int64? = nil,
        thumbnailFileSize: Int64? = nil,
        previewFileId: Int64? = nil,
        previewFileSize: Int64? = nil
    ) {
        self.kind = kind
        self.fileId = fileId
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.thumbnailFileId = thumbnailFileId
        self.thumbnailFileSize = thumbnailFileSize
        self.previewFileId = previewFileId
        self.previewFileSize = previewFileSize
    }
}

// [修改] 附件入口按照片、视频、文件拆分，并在进入上传链路前再次校验媒体类型。
enum ChatAttachmentSelectionSource: Sendable {
    case photoLibraryImages
    case photoLibraryVideos
    case files
}

enum ChatAttachmentSelectionError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case tooManyPhotos(maximum: Int)
    case mixedImagesAndVideos
    case invalidPhotoSelection
    case invalidVideoSelection

    var errorDescription: String? {
        switch self {
        case .empty: "没有选择可发送的附件"
        case .tooManyPhotos(let maximum): "照片最多选择\(maximum)张"
        case .mixedImagesAndVideos: "图片和视频不能同时选择"
        case .invalidPhotoSelection: "所选内容不是照片"
        case .invalidVideoSelection: "所选内容不是视频"
        }
    }
}

enum ChatAttachmentSelectionRules {
    static let maximumPhotoCount = 9

    static func validate(
        _ urls: [URL],
        source: ChatAttachmentSelectionSource
    ) throws -> [URL] {
        guard !urls.isEmpty else { throw ChatAttachmentSelectionError.empty }
        let imageFlags = urls.map(isImage)
        let videoFlags = urls.map(isVideo)
        if imageFlags.contains(true) && videoFlags.contains(true) {
            throw ChatAttachmentSelectionError.mixedImagesAndVideos
        }
        switch source {
        case .photoLibraryImages:
            guard imageFlags.allSatisfy({ $0 }) else { throw ChatAttachmentSelectionError.invalidPhotoSelection }
            guard urls.count <= maximumPhotoCount else {
                throw ChatAttachmentSelectionError.tooManyPhotos(maximum: maximumPhotoCount)
            }
        case .photoLibraryVideos:
            guard videoFlags.allSatisfy({ $0 }) else { throw ChatAttachmentSelectionError.invalidVideoSelection }
        case .files:
            break
        }
        return urls
    }

    private static func isImage(_ url: URL) -> Bool {
        url.pathExtension.isEmpty == false &&
            (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true)
    }

    private static func isVideo(_ url: URL) -> Bool {
        url.pathExtension.isEmpty == false &&
            (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true ||
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .video) == true)
    }
}

struct ChatMixedMessageContent: Codable, Equatable, Sendable {
    let kind: String
    let version: Int
    let text: String
    let attachments: [ChatAttachment]

    init(kind: String = "mixed", version: Int = 2, text: String = "", attachments: [ChatAttachment]) {
        self.kind = kind
        self.version = version
        self.text = text
        self.attachments = attachments
    }
}

struct ClearUnreadRequest: Codable, Equatable, Sendable {
    let friendId: Int64
}

struct UserSearchRequest: Codable, Equatable, Sendable {
    let userName: String
}

struct AddFriendRequest: Codable, Equatable, Sendable {
    let userId: Int64
    let requestMsg: String
}

struct FriendRequestItem: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let senderId: Int64
    let receiverId: Int64
    let requestMessage: String
    let status: Int
    let createdAt: Int64
    let senderUsername: String
    let senderNickname: String?
    let senderAvatar: String?

    var displayName: String { senderNickname?.nilIfBlank ?? senderUsername.nilIfBlank ?? "新朋友" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try values.first(Int64.self, ["id", "applyId"]) ?? 0
        senderId = try values.first(Int64.self, ["senderId", "userId"]) ?? 0
        receiverId = try values.first(Int64.self, ["receiverId", "friendId"]) ?? 0
        requestMessage = try values.first(String.self, ["requestMsg", "applyInfo", "applyMsg"]) ?? ""
        status = try values.first(Int.self, ["status"]) ?? 0
        createdAt = try values.first(Int64.self, ["createTime", "gmtCreated"]) ?? 0
        senderUsername = try values.first(String.self, ["senderUserName", "userName"]) ?? ""
        senderNickname = try values.first(String.self, ["senderNickName", "nickName"])
        senderAvatar = try values.first(String.self, ["senderAvatar", "avatar"])
    }
}

struct ChatUserSearchResult: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let username: String
    let nickname: String?
    let avatar: String?
    let status: Int?
    let friendStatus: Int?
    let friendStatusDescription: String?
    let incomingRequestId: Int64?

    var displayName: String { nickname?.nilIfBlank ?? username.nilIfBlank ?? "用户" }
    // [修改] 服务端 3=可添加、2=冷却期结束后可重新申请；旧服务端未返回状态时继续兼容添加。
    var canSendFriendRequest: Bool { friendStatus == nil || friendStatus == 2 || friendStatus == 3 }
    var friendActionTitle: String {
        guard canSendFriendRequest else { return "" }
        return friendStatusDescription?.nilIfBlank ?? "添加"
    }

    init(id: Int64, username: String, nickname: String?, avatar: String?, status: Int?, friendStatus: Int?, friendStatusDescription: String?, incomingRequestId: Int64?) {
        self.id = id
        self.username = username
        self.nickname = nickname
        self.avatar = avatar
        self.status = status
        self.friendStatus = friendStatus
        self.friendStatusDescription = friendStatusDescription
        self.incomingRequestId = incomingRequestId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try values.first(Int64.self, ["userId", "id"]) ?? 0
        username = try values.first(String.self, ["userName", "username"]) ?? ""
        nickname = try values.first(String.self, ["nickName", "nickname"])
        avatar = try values.first(String.self, ["avatar"])
        status = try values.first(Int.self, ["status"])
        friendStatus = try values.first(Int.self, ["friendStatus"])
        friendStatusDescription = try values.first(String.self, ["friendStatusDesc", "friendStatusDescription"])
        incomingRequestId = try values.first(Int64.self, ["incomingRequestId"])
    }
}

struct HandleFriendRequest: Codable, Equatable, Sendable {
    let requestId: Int64
    let action: Int
    let alias: String?
}

struct UpdateFriendAliasRequest: Codable, Equatable, Sendable {
    let id: Int64
    let alias: String
}

enum ChatMessageSendStatus: String, Codable, Equatable, Sendable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

// [修改] 0x3E 好友关系推送统一进入聊天事件流，供申请红点和好友列表实时刷新。
struct FriendRelationshipEvent: Codable, Equatable, Sendable {
    let event: String
    let requestId: Int64
    let actorUserId: Int64
}

// [修改] 0x59/0x5A/0x5B 共用同一动作模型；服务端兼容 RETRACT 和旧名 RECALL。
struct ChatMessageAction: Codable, Equatable, Sendable {
    let action: String
    let messageId: Int64
    let friendId: Int64
    let notifyText: String?
    // [修改] 服务端以 JSON 对象返回每个表情对应的用户 ID，iOS 直接解码后展示数量。
    let reaction: [String: [Int64]]?

    private enum CodingKeys: String, CodingKey {
        case action, messageId, friendId, notifyText, reaction
    }

    init(
        action: String,
        messageId: Int64,
        friendId: Int64,
        notifyText: String? = nil,
        reaction: [String: [Int64]]? = nil
    ) {
        self.action = action
        self.messageId = messageId
        self.friendId = friendId
        self.notifyText = notifyText
        self.reaction = reaction
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decode(String.self, forKey: .action)
        messageId = try values.decode(Int64.self, forKey: .messageId)
        friendId = try values.decode(Int64.self, forKey: .friendId)
        notifyText = try values.decodeIfPresent(String.self, forKey: .notifyText)
        if let object = try? values.decodeIfPresent([String: [Int64]].self, forKey: .reaction) {
            reaction = object
        } else if let encoded = try? values.decodeIfPresent(String.self, forKey: .reaction),
                  let data = encoded.data(using: .utf8) {
            reaction = try? ProtocolJSON.decoder().decode([String: [Int64]].self, from: data)
        } else {
            reaction = nil
        }
    }

    var isRetraction: Bool {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.contains("RETRACT") || normalized.contains("RECALL")
    }

    var isReaction: Bool {
        action.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .contains("REACTION")
    }
}

// [修改] 消息推送和已读状态统一走广播事件，保证列表页与聊天页各收一份。
enum ChatEvent: Equatable, Sendable {
    case message(ChatMessage)
    case messageAction(ChatMessageAction)
    case read(friendId: Int64)
    case friendRelationshipChanged(FriendRelationshipEvent)
}

struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    let messageId: Int64
    let senderId: Int64
    let receiverId: Int64
    let content: String
    let msgType: String
    let status: Int
    let avatar: String?
    let groupTime: String?
    let messageTime: String?
    let clientMsgId: String?
    let createdAt: Int64
    let isMine: Bool
    let conversationSeq: Int64?
    let senderDeviceId: String?
    let encryptionMode: String?
    let keyId: String?
    let sendStatus: ChatMessageSendStatus
    let quote: ChatQuote?
    let retracted: Bool
    // [修改] 收藏是当前 iPhone 的本地状态；表情回应由服务端同步；转发来源随消息落本地缓存。
    let isFavorite: Bool
    let reactions: [String: [Int64]]
    let forwardFrom: String?
    var id: String { clientMsgId ?? "server-\(messageId)" }
    var statusText: String? {
        switch sendStatus {
        case .sending: "发送中"
        case .failed: "发送失败"
        case .sent: "已发送"
        case .delivered: "已送达"
        case .read: "已读"
        }
    }
    var mixedContent: ChatMixedMessageContent? {
        guard msgType.caseInsensitiveCompare("MIXED") == .orderedSame else { return nil }
        return try? ProtocolJSON.decoder().decode(ChatMixedMessageContent.self, from: Data(content.utf8))
    }
    // [修改] 好友列表和本地缓存共用可读摘要，附件消息不能显示协议 JSON。
    var conversationSummary: String {
        if retracted { return "[消息已撤回]" }
        if let mixed = mixedContent {
            var parts: [String] = []
            let text = mixed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
            let imageCount = mixed.attachments.filter(\.isImage).count
            let fileCount = mixed.attachments.count - imageCount
            if imageCount > 0 { parts.append(imageCount == 1 ? "[图片]" : "[图片]×\(imageCount)") }
            if fileCount > 0 { parts.append(fileCount == 1 ? "[文件]" : "[文件]×\(fileCount)") }
            return parts.isEmpty ? "[附件]" : parts.joined(separator: " ")
        }
        switch msgType.uppercased() {
        case "IMAGE": return "[图片]"
        case "FILE", "VIDEO", "AUDIO": return "[文件]"
        default:
            let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "[消息]" : value
        }
    }

    init(messageId: Int64, senderId: Int64, receiverId: Int64, content: String, msgType: String = "TEXT", status: Int = 1, avatar: String? = nil, groupTime: String? = nil, messageTime: String? = nil, clientMsgId: String? = nil, createdAt: Int64 = 0, isMine: Bool = false, conversationSeq: Int64? = nil, senderDeviceId: String? = nil, encryptionMode: String? = nil, keyId: String? = nil, sendStatus: ChatMessageSendStatus = .sent, quote: ChatQuote? = nil, retracted: Bool = false, isFavorite: Bool = false, reactions: [String: [Int64]] = [:], forwardFrom: String? = nil) {
        self.messageId = messageId; self.senderId = senderId; self.receiverId = receiverId; self.content = content; self.msgType = msgType; self.status = status; self.avatar = avatar; self.groupTime = groupTime; self.messageTime = messageTime; self.clientMsgId = clientMsgId; self.createdAt = createdAt; self.isMine = isMine; self.conversationSeq = conversationSeq; self.senderDeviceId = senderDeviceId; self.encryptionMode = encryptionMode; self.keyId = keyId; self.sendStatus = sendStatus; self.quote = quote; self.retracted = retracted; self.isFavorite = isFavorite; self.reactions = reactions; self.forwardFrom = forwardFrom
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AnyCodingKey.self)
        messageId = try values.first(Int64.self, ["id", "messageId"]) ?? 0
        senderId = try values.first(Int64.self, ["senderId"]) ?? 0
        receiverId = try values.first(Int64.self, ["receiverId"]) ?? 0
        content = try values.first(String.self, ["content"]) ?? ""
        msgType = try values.first(String.self, ["msgType"]) ?? "TEXT"
        status = try values.first(Int.self, ["status"]) ?? 1
        avatar = try values.first(String.self, ["avatar"])
        groupTime = try values.first(String.self, ["groupTime"])
        messageTime = try values.first(String.self, ["msgTimeStr", "messageTime"])
        clientMsgId = try values.first(String.self, ["clientMsgId"])
        createdAt = try values.first(Int64.self, ["gmtCreated", "createdAt"]) ?? 0
        isMine = false
        conversationSeq = try values.first(Int64.self, ["conversationSeq"])
        senderDeviceId = try values.first(String.self, ["senderDeviceId"])
        encryptionMode = try values.first(String.self, ["encryptionMode"])
        keyId = try values.first(String.self, ["keyId"])
        sendStatus = .sent
        if let cachedQuote = try values.first(ChatQuote.self, ["quote"]) {
            quote = cachedQuote
        } else if let quoteContent = try values.first(String.self, ["quoteMsgContent"]), !quoteContent.isEmpty {
            quote = ChatQuote(
                messageId: try values.first(Int64.self, ["quoteMsgId"]),
                content: quoteContent,
                senderName: try values.first(String.self, ["quoteMsgSenderName"]) ?? "引用消息"
            )
        } else {
            quote = nil
        }
        retracted = try values.firstLossyBool(["retracted"]) ?? false
        isFavorite = try values.firstLossyBool(["isFavorite", "favorite"]) ?? false
        // [修改] 历史接口兼容 JSON 对象和 JSON 字符串两种 reaction 返回格式。
        if let object = try? values.first([String: [Int64]].self, ["reactions", "reaction"]) {
            reactions = object
        } else if let encoded = try? values.first(String.self, ["reactions", "reaction"]),
                  let data = encoded.data(using: .utf8) {
            reactions = (try? ProtocolJSON.decoder().decode([String: [Int64]].self, from: data)) ?? [:]
        } else {
            reactions = [:]
        }
        forwardFrom = try values.first(String.self, ["forwardFrom"])
    }
}

struct ChatHistoryPage: Decodable, Equatable, Sendable {
    let messages: [ChatMessage]
    let hasMore: Bool
    let nextBeforeMessageId: Int64?
    let latestMessageId: Int64?

    init(messages: [ChatMessage], hasMore: Bool, nextBeforeMessageId: Int64?, latestMessageId: Int64?) {
        self.messages = messages; self.hasMore = hasMore; self.nextBeforeMessageId = nextBeforeMessageId; self.latestMessageId = latestMessageId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AnyCodingKey.self)
        let list = try values.decodeIfPresent([ChatMessage].self, forKey: AnyCodingKey("list")) ?? []
        messages = list
        hasMore = try values.first(Bool.self, ["hasMore"]) ?? (list.count >= 20)
        nextBeforeMessageId = try values.first(Int64.self, ["nextBeforeMessageId"]) ?? list.first?.messageId
        latestMessageId = try values.first(Int64.self, ["latestMessageId"]) ?? list.last?.messageId
    }
}

struct ChatReceipt: Decodable, Equatable, Sendable {
    let messageId: Int64
    let status: String
    let clientMsgId: String?
    let message: String?
    let errorCode: String?

    var isSuccess: Bool { ["SUCCESS", "SUCCEED", "OK", "TRUE", "200"].contains(status.uppercased()) }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        let data = try root.decodeIfPresent(ReceiptData.self, forKey: AnyCodingKey("data"))
        let rootMessageId = try root.first(Int64.self, ["messageId", "id"])
        let rootStatus = try root.first(String.self, ["status"])
        let rootSuccess = try root.first(Bool.self, ["success"])
        messageId = data?.messageId ?? rootMessageId ?? -1
        status = data?.status ?? rootStatus ?? (rootSuccess == true ? "SUCCESS" : "FALSE")
        let rootClientMsgId = try root.first(String.self, ["clientMsgId"])
        let rootMessage = try root.first(String.self, ["message", "msg"])
        let rootErrorCode = try root.first(String.self, ["errorCode"])
        clientMsgId = data?.clientMsgId ?? rootClientMsgId
        message = data?.message ?? rootMessage
        errorCode = data?.errorCode ?? rootErrorCode
    }

    private struct ReceiptData: Decodable {
        let messageId: Int64?
        let status: String?
        let clientMsgId: String?
        let message: String?
        let errorCode: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            messageId = try c.first(Int64.self, ["messageId", "id"])
            status = try c.first(String.self, ["status"])
            clientMsgId = try c.first(String.self, ["clientMsgId"])
            message = try c.first(String.self, ["message", "msg"])
            errorCode = try c.first(String.self, ["errorCode"])
        }
    }
}

struct FriendOperationEnvelope: Decodable, Sendable {
    let success: Bool?
    let code: Int
    let message: String
    var isSuccess: Bool { success ?? (code == 200) }
    enum CodingKeys: String, CodingKey { case success, code, message, msg }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        code = try values.decodeIfPresent(Int.self, forKey: .code) ?? (success == true ? 200 : 400)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? values.decodeIfPresent(String.self, forKey: .msg) ?? ""
    }
}

private struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == AnyCodingKey {
    func first<T: Decodable>(_ type: T.Type, _ names: [String]) throws -> T? {
        for name in names {
            let key = AnyCodingKey(name)
            if contains(key), let value = try decodeIfPresent(type, forKey: key) { return value }
        }
        return nil
    }

    func firstLossyBool(_ names: [String]) throws -> Bool? {
        for name in names {
            let key = AnyCodingKey(name)
            guard contains(key) else { continue }
            if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: continue
                }
            }
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
