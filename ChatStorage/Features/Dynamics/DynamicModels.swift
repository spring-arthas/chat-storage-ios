import Foundation

enum DynamicMediaKind: String, Codable, Equatable, Sendable {
    case image
    case video
    case file
}

struct DynamicMedia: Codable, Equatable, Identifiable, Sendable {
    let kind: DynamicMediaKind
    let fileId: Int64
    let fileName: String
    let fileSize: Int64
    let mimeType: String

    var id: Int64 { fileId }

    init(kind: DynamicMediaKind, fileId: Int64, fileName: String, fileSize: Int64, mimeType: String) {
        self.kind = kind
        self.fileId = fileId
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        kind = try values.first(DynamicMediaKind.self, ["kind"]) ?? .file
        fileId = try values.firstLossyInt64(["fileId", "id"]) ?? 0
        fileName = try values.first(String.self, ["fileName", "name"]) ?? ""
        fileSize = try values.firstLossyInt64(["fileSize", "size"]) ?? 0
        mimeType = try values.first(String.self, ["mimeType", "contentType"]) ?? "application/octet-stream"
    }
}

enum DynamicReferenceSourceType: String, Codable, Equatable, Sendable {
    case chatMessage
    case driveFile
}

struct DynamicReference: Codable, Equatable, Sendable {
    let sourceType: DynamicReferenceSourceType
    let sourceId: String
    let title: String
    let subtitle: String
    let media: [DynamicMedia]
}

struct DynamicAuthor: Codable, Equatable, Sendable {
    let id: Int64
    let username: String
    let nickname: String
    let avatar: String?

    init(id: Int64, username: String, nickname: String, avatar: String?) {
        self.id = id
        self.username = username
        self.nickname = nickname
        self.avatar = avatar
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = try values.firstLossyInt64(["id", "userId"]) ?? 0
        username = try values.first(String.self, ["username", "userName"]) ?? ""
        nickname = try values.first(String.self, ["nickname", "nickName"]) ?? username
        avatar = try values.first(String.self, ["avatar", "avatarUrl"])
    }
}

struct DynamicPost: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let author: DynamicAuthor
    let content: String
    let media: [DynamicMedia]
    let reference: DynamicReference?
    let likeCount: Int
    let replyCount: Int
    let repostCount: Int
    let liked: Bool
    let reposted: Bool
    let originalPost: IndirectDynamicPost?
    let createdAt: Int64
    let isMine: Bool

    init(
        id: Int64,
        author: DynamicAuthor,
        content: String,
        media: [DynamicMedia],
        reference: DynamicReference?,
        likeCount: Int,
        replyCount: Int,
        repostCount: Int,
        liked: Bool,
        reposted: Bool,
        originalPost: DynamicPost?,
        createdAt: Int64,
        isMine: Bool
    ) {
        self.id = id
        self.author = author
        self.content = content
        self.media = media
        self.reference = reference
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.repostCount = repostCount
        self.liked = liked
        self.reposted = reposted
        self.originalPost = originalPost.map(IndirectDynamicPost.init)
        self.createdAt = createdAt
        self.isMine = isMine
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = try values.firstLossyInt64(["id", "dynamicId"]) ?? 0
        if let nestedAuthor = try values.first(DynamicAuthor.self, ["author"]) {
            author = nestedAuthor
        } else {
            author = DynamicAuthor(
                id: try values.firstLossyInt64(["userId", "authorId"]) ?? 0,
                username: try values.first(String.self, ["username", "userName"]) ?? "",
                nickname: try values.first(String.self, ["nickname", "nickName"]) ?? "",
                avatar: try values.first(String.self, ["avatar", "avatarUrl"])
            )
        }
        content = try values.first(String.self, ["content", "text"]) ?? ""
        media = try values.first([DynamicMedia].self, ["media", "images", "attachments"]) ?? []
        reference = try values.first(DynamicReference.self, ["reference"])
        likeCount = try values.firstLossyInt(["likeCount", "likes"]) ?? 0
        replyCount = try values.firstLossyInt(["replyCount", "replies"]) ?? 0
        repostCount = try values.firstLossyInt(["repostCount", "reposts"]) ?? 0
        liked = try values.firstLossyBool(["liked", "isLiked"]) ?? false
        reposted = try values.firstLossyBool(["reposted", "isReposted"]) ?? false
        originalPost = try values.first(IndirectDynamicPost.self, ["originalPost", "repost"])
        createdAt = try values.firstLossyInt64(["createdAt", "gmtCreated", "createTime"]) ?? 0
        isMine = try values.firstLossyBool(["isMine", "mine"]) ?? false
    }
}

// [修改] 转发动态用引用盒打断值类型递归，避免 Swift 6 IRGen 崩溃。
final class IndirectDynamicPost: Codable, Equatable, @unchecked Sendable {
    let value: DynamicPost

    init(_ value: DynamicPost) {
        self.value = value
    }

    static func == (left: IndirectDynamicPost, right: IndirectDynamicPost) -> Bool {
        left.value == right.value
    }

    required init(from decoder: Decoder) throws {
        value = try DynamicPost(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

enum DynamicTimelineScope: String, Codable, Equatable, Sendable {
    case following = "FOLLOWING"
    case mine = "MINE"
}

struct DynamicCreateRequest: Codable, Equatable, Sendable {
    let content: String
    let media: [DynamicMedia]
    let imagePaths: String?
    let reference: DynamicReference?

    init(content: String, media: [DynamicMedia] = [], imagePaths: String? = nil, reference: DynamicReference? = nil) {
        self.content = content
        self.media = media
        self.imagePaths = imagePaths
        self.reference = reference
    }
}

struct DynamicCreateResult: Codable, Equatable, Sendable {
    let dynamicId: Int64
    let post: DynamicPost?

    init(dynamicId: Int64, post: DynamicPost?) {
        self.dynamicId = dynamicId
        self.post = post
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        dynamicId = try values.firstLossyInt64(["dynamicId", "id"]) ?? 0
        post = try values.first(DynamicPost.self, ["post", "dynamic"])
    }
}

struct DynamicTimelinePage: Codable, Equatable, Sendable {
    let posts: [DynamicPost]
    let nextBeforeId: Int64?
    let hasMore: Bool

    init(posts: [DynamicPost], nextBeforeId: Int64?, hasMore: Bool) {
        self.posts = posts
        self.nextBeforeId = nextBeforeId
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        posts = try values.first([DynamicPost].self, ["posts", "records", "items"]) ?? []
        nextBeforeId = try values.firstLossyInt64(["nextBeforeId", "nextCursor", "beforeId"])
        hasMore = try values.firstLossyBool(["hasMore"]) ?? (nextBeforeId != nil)
    }
}

enum DynamicAction: Equatable, Sendable {
    case like
    case unlike
    case reply(content: String)
    case repost
    case unrepost

    var wireValue: String {
        switch self {
        case .like: "LIKE"
        case .unlike: "UNLIKE"
        case .reply: "REPLY"
        case .repost: "REPOST"
        case .unrepost: "UNREPOST"
        }
    }

    var content: String? {
        guard case .reply(let content) = self else { return nil }
        return content
    }

    init?(wireValue: String, content: String? = nil) {
        switch wireValue.uppercased() {
        case "LIKE": self = .like
        case "UNLIKE": self = .unlike
        case "REPLY": self = .reply(content: content ?? "")
        case "REPOST": self = .repost
        case "UNREPOST": self = .unrepost
        default: return nil
        }
    }
}

struct DynamicActionResult: Equatable, Sendable {
    let dynamicId: Int64
    let action: DynamicAction
    let likeCount: Int
    let replyCount: Int
    let repostCount: Int
    let liked: Bool
    let reposted: Bool

    init(
        dynamicId: Int64,
        action: DynamicAction,
        likeCount: Int,
        replyCount: Int,
        repostCount: Int,
        liked: Bool,
        reposted: Bool
    ) {
        self.dynamicId = dynamicId
        self.action = action
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.repostCount = repostCount
        self.liked = liked
        self.reposted = reposted
    }
}

extension DynamicActionResult: Decodable {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        dynamicId = try values.firstLossyInt64(["dynamicId", "id"]) ?? 0
        let actionValue = try values.first(String.self, ["action"]) ?? ""
        action = DynamicAction(wireValue: actionValue, content: try values.first(String.self, ["content"])) ?? .like
        likeCount = try values.firstLossyInt(["likeCount", "likes"]) ?? 0
        replyCount = try values.firstLossyInt(["replyCount", "replies"]) ?? 0
        repostCount = try values.firstLossyInt(["repostCount", "reposts"]) ?? 0
        liked = try values.firstLossyBool(["liked", "isLiked"]) ?? false
        reposted = try values.firstLossyBool(["reposted", "isReposted"]) ?? false
    }
}

struct DynamicPostDetail: Codable, Equatable, Sendable {
    let post: DynamicPost
    let replies: [DynamicPost]
    // [修改] 保存服务端回复分页游标，详情页才能继续请求下一页。
    let nextBeforeReplyId: Int64?
    let hasMore: Bool

    init(
        post: DynamicPost,
        replies: [DynamicPost],
        nextBeforeReplyId: Int64? = nil,
        hasMore: Bool = false
    ) {
        self.post = post
        self.replies = replies
        self.nextBeforeReplyId = nextBeforeReplyId
        self.hasMore = hasMore
    }

    // [修改] 游标兼容数字和字符串，避免服务端 JSON 数值形态变化导致整页解析失败。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard let post = try values.first(DynamicPost.self, ["post", "dynamic"]) else {
            throw DecodingError.keyNotFound(
                DynamicCodingKey("post"),
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing dynamic post")
            )
        }
        self.post = post
        replies = try values.first([DynamicPost].self, ["replies", "records", "items"]) ?? []
        nextBeforeReplyId = try values.firstLossyInt64(["nextBeforeReplyId", "nextCursor"])
        hasMore = try values.firstLossyBool(["hasMore"]) ?? (nextBeforeReplyId != nil)
    }
}

struct DynamicComposerDraft: Equatable, Sendable {
    let text: String
    let reference: DynamicReference?

    init(text: String = "", reference: DynamicReference? = nil) {
        self.text = text
        self.reference = reference
    }
}

enum DynamicComposerMediaState: String, Codable, Equatable, Sendable {
    case preparing
    case uploading
    case succeeded
    case failed
}

struct DynamicComposerMediaItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    // [修改] 先创建传输任务时使用占位 URL，PhotosPicker 读取完成后替换为真实暂存文件。
    var localURL: URL
    let kind: DynamicMediaKind
    // [修改] 每个媒体项固定一个上传批次标识，失败重试和重启恢复都接回同一传输任务。
    let uploadBatchID: String
    // [修改] 相册视频不复制到本地，保存资源标识和传输中心任务 ID 以便重启后续传。
    let photoLibraryAssetIdentifier: String?
    var transferTaskID: String?
    var state: DynamicComposerMediaState
    var progress: Double
    var uploadedMedia: DynamicMedia?

    // [修改] 发布页的展示状态统一由媒体项计算，避免卡片各自判断导致上传中误开放预览。
    var normalizedProgress: Double {
        min(max(progress, 0), 1)
    }

    var canPreview: Bool {
        state == .succeeded && uploadedMedia != nil
    }

    var shouldDimPreview: Bool {
        !canPreview
    }

    var uploadStatusTitle: String {
        switch state {
        case .preparing: "准备发送"
        case .uploading: "正在上传"
        case .succeeded: "上传完成"
        case .failed: "上传失败"
        }
    }

    init(
        id: UUID = UUID(),
        localURL: URL,
        kind: DynamicMediaKind,
        uploadBatchID: String? = nil,
        photoLibraryAssetIdentifier: String? = nil,
        transferTaskID: String? = nil,
        state: DynamicComposerMediaState = .preparing,
        progress: Double = 0,
        uploadedMedia: DynamicMedia? = nil
    ) {
        self.id = id
        self.localURL = localURL
        self.kind = kind
        self.uploadBatchID = uploadBatchID ?? "dynamic-media-\(id.uuidString)"
        self.photoLibraryAssetIdentifier = photoLibraryAssetIdentifier
        self.transferTaskID = transferTaskID
        self.state = state
        self.progress = min(max(progress, 0), 1)
        self.uploadedMedia = uploadedMedia
    }

    private enum CodingKeys: String, CodingKey {
        case id, localURL, kind, uploadBatchID, photoLibraryAssetIdentifier, transferTaskID, state, progress, uploadedMedia
    }

    // [修改] 兼容首版动态草稿，新增字段缺失时仍能恢复旧草稿。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        localURL = try values.decode(URL.self, forKey: .localURL)
        kind = try values.decode(DynamicMediaKind.self, forKey: .kind)
        uploadBatchID = try values.decodeIfPresent(String.self, forKey: .uploadBatchID) ?? "dynamic-media-\(id.uuidString)"
        photoLibraryAssetIdentifier = try values.decodeIfPresent(String.self, forKey: .photoLibraryAssetIdentifier)
        transferTaskID = try values.decodeIfPresent(String.self, forKey: .transferTaskID)
        state = try values.decodeIfPresent(DynamicComposerMediaState.self, forKey: .state) ?? .preparing
        progress = min(max(try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0, 0), 1)
        uploadedMedia = try values.decodeIfPresent(DynamicMedia.self, forKey: .uploadedMedia)
    }
}

// [修改] 发布页将上传状态收敛为一条底部状态栏，避免准备中再额外绘制独立转圈。
struct DynamicComposerMediaStatusPresentation: Equatable, Sendable {
    let title: String
    let progress: Double
    let showsProgressTrack: Bool
    let showsActivityIndicator: Bool
    let allowsRetry: Bool

    init(item: DynamicComposerMediaItem) {
        title = item.uploadStatusTitle
        progress = item.normalizedProgress
        showsProgressTrack = item.state == .uploading
        showsActivityIndicator = false
        allowsRetry = item.state == .failed
    }
}

// [修改] 动态协议字段需要兼容 Java DTO 的不同命名和数字字符串。
private struct DynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == DynamicCodingKey {
    func first<T: Decodable>(_ type: T.Type, _ names: [String]) throws -> T? {
        for name in names {
            let key = DynamicCodingKey(name)
            if contains(key), let value = try decodeIfPresent(type, forKey: key) { return value }
        }
        return nil
    }

    func firstLossyInt64(_ names: [String]) throws -> Int64? {
        for name in names {
            let key = DynamicCodingKey(name)
            guard contains(key) else { continue }
            if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return Int64(value) }
            if let value = try? decodeIfPresent(String.self, forKey: key), let parsed = Int64(value) { return parsed }
        }
        return nil
    }

    func firstLossyInt(_ names: [String]) throws -> Int? {
        guard let value = try firstLossyInt64(names) else { return nil }
        return Int(exactly: value)
    }

    func firstLossyBool(_ names: [String]) throws -> Bool? {
        for name in names {
            let key = DynamicCodingKey(name)
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
