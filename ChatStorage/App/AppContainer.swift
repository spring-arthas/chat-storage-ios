import Foundation

@MainActor
final class AppContainer {
    let configurationStore: UserDefaultsServerConfigurationStore
    var configuration: ServerConfiguration
    let authRepository: any AuthRepository
    let friendRepository: any FriendRepository
    let chatRepository: any ChatRepository
    let driveRepository: any DriveRepository
    let dynamicRepository: any DynamicRepository
    let session: AppSession
    private let client: (any FrameRequesting)?

    init(
        configurationStore: UserDefaultsServerConfigurationStore,
        configuration: ServerConfiguration,
        authRepository: any AuthRepository,
        friendRepository: any FriendRepository,
        chatRepository: any ChatRepository,
        driveRepository: any DriveRepository,
        dynamicRepository: any DynamicRepository,
        client: (any FrameRequesting)? = nil,
        networkMonitor: any NetworkAvailabilityMonitoring = DisabledNetworkAvailabilityMonitor()
    ) {
        self.configurationStore = configurationStore
        self.configuration = configuration
        self.authRepository = authRepository
        self.friendRepository = friendRepository
        self.chatRepository = chatRepository
        self.driveRepository = driveRepository
        self.dynamicRepository = dynamicRepository
        self.client = client
        self.session = AppSession(repository: authRepository, networkMonitor: networkMonitor)
    }

    static func live(
        configurationStore: UserDefaultsServerConfigurationStore = UserDefaultsServerConfigurationStore(),
        configuration: ServerConfiguration? = nil
    ) -> AppContainer {
        let configuration = configuration ?? (try? configurationStore.load()) ?? .default
        let connection = NWControlConnection(configuration: configuration)
        let client = RequestResponseClient(connection: connection)
        let secureStore = KeychainSecureStore()
        let authRepository = RemoteAuthRepository(client: client, secureStore: secureStore)
        let identityProvider = SecureCurrentUserIDProvider(secureStore: secureStore)
        // [修改] 同一 userId 在不同服务器使用不同缓存文件，杜绝切服串好友和聊天记录。
        let cache = ChatCacheStore.serverScoped(configuration: configuration)
        let friendRepository = CachedFriendRepository(
            remote: RemoteFriendRepository(client: client),
            cache: cache,
            identityProvider: identityProvider
        )
        let chatRepository = CachedChatRepository(
            remote: RemoteChatRepository(client: client),
            cache: cache,
            identityProvider: identityProvider
        )
        let driveRepository = RemoteDriveRepository(client: client)
        // [修改] 动态与登录、聊天、网盘复用同一条控制 Socket，不新增服务或端口。
        let dynamicRepository = RemoteDynamicRepository(client: client)
        return AppContainer(
            configurationStore: configurationStore,
            configuration: configuration,
            authRepository: authRepository,
            friendRepository: friendRepository,
            chatRepository: chatRepository,
            driveRepository: driveRepository,
            dynamicRepository: dynamicRepository,
            client: client,
            networkMonitor: NWPathAvailabilityMonitor()
        )
    }

    func save(configuration: ServerConfiguration) throws {
        try configurationStore.save(configuration)
        self.configuration = configuration
    }

    // [修改] 远程登出必须复用仍可用的控制连接，完成后再关闭旧客户端。
    func shutdown() async {
        // [修改] 整个旧容器关闭阶段保持登录门禁，防止新登录复用即将关闭的客户端。
        await session.beginLogout()
        await client?.close()
        session.completeLogout()
    }

    // [修改] 配置切换关闭旧连接，但保留 Keychain 会话，由新容器向新地址执行恢复。
    func shutdownForConfigurationChange() async {
        await session.beginConfigurationChange()
        await client?.close()
    }
}

actor PreviewAuthRepository: AuthRepository {
    let user: AuthenticatedUser?
    private let resumeDelay: Duration?

    init(user: AuthenticatedUser?, resumeDelay: Duration? = nil) {
        self.user = user
        self.resumeDelay = resumeDelay
    }
    func login(account: String, password: String) async throws -> AuthenticatedUser { user ?? .preview }
    func register(
        account: String,
        email: String,
        password: String,
        avatarData: String?,
        avatarName: String?
    ) async throws -> AuthenticatedUser {
        AuthenticatedUser(
            id: 99,
            username: account,
            nickname: nil,
            avatar: avatarData,
            email: email,
            phone: nil,
            status: 1,
            transferToken: nil,
            sessionToken: nil
        )
    }
    func resumeSession() async throws -> AuthenticatedUser? {
        // [修改] 仅供 UI 测试稳定复现慢 Socket 恢复，不改变正式仓库行为。
        if let resumeDelay { try await Task.sleep(for: resumeDelay) }
        return user
    }
    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser {
        let current = user ?? .preview
        return AuthenticatedUser(
            id: current.id,
            username: current.username,
            nickname: current.nickname,
            avatar: avatarData,
            email: current.email,
            phone: current.phone,
            status: current.status,
            transferToken: current.transferToken,
            sessionToken: current.sessionToken
        )
    }
    func logout() async {}
}

actor PreviewFriendRepository: FriendRepository {
    private var friends: [ChatFriend]

    init(friends: [ChatFriend]) {
        self.friends = friends
    }

    func refresh() async throws -> [ChatFriend] { friends }

    func updatePin(relationshipId: Int64, pinned: Bool) async throws -> FriendPinState {
        let pinnedAt = pinned ? Int64(Date().timeIntervalSince1970 * 1_000) : nil
        let result = FriendPinState(relationshipId: relationshipId, isPinned: pinned, pinnedAt: pinnedAt)
        if let index = friends.firstIndex(where: { $0.relationshipId == relationshipId }) {
            let friend = friends[index]
            friends[index] = ChatFriend(
                relationshipId: friend.relationshipId,
                userId: friend.userId,
                friendId: friend.friendId,
                alias: friend.alias,
                username: friend.username,
                nickname: friend.nickname,
                avatar: friend.avatar,
                unreadCount: friend.unreadCount,
                latestMessage: friend.latestMessage,
                isOnline: friend.isOnline,
                isPinned: pinned,
                pinnedAt: pinnedAt
            )
        }
        return result
    }
}

actor PreviewChatRepository: ChatRepository {
    nonisolated let messages: AsyncStream<ChatMessage>
    private var continuation: AsyncStream<ChatMessage>.Continuation?
    private var pages: [Int64: [ChatMessage]] = [:]
    // [修改] 固定 3 条待处理申请，让消息页 UI 测试不依赖网络和时间数据。
    private static let previewPendingRequests: [FriendRequestItem] = {
        let data = Data(#"""
        [
          {"id":201,"senderId":21,"receiverId":1,"requestMsg":"一起整理旅行相册","status":0,"createTime":1,"senderUserName":"lin-one","senderNickName":"林一"},
          {"id":202,"senderId":22,"receiverId":1,"requestMsg":"你好","status":0,"createTime":2,"senderUserName":"zhou-two","senderNickName":"周二"},
          {"id":203,"senderId":23,"receiverId":1,"requestMsg":"申请添加好友","status":0,"createTime":3,"senderUserName":"chen-three","senderNickName":"陈三"}
        ]
        """#.utf8)
        return try! ProtocolJSON.decoder().decode([FriendRequestItem].self, from: data)
    }()

    init() {
        var captured: AsyncStream<ChatMessage>.Continuation!
        messages = AsyncStream { captured = $0 }
        continuation = captured
        let previewVideoPayload = ChatMixedMessageContent(
            attachments: [ChatAttachment(
                fileId: 88,
                fileName: "旅行视频.mp4",
                fileSize: 8 * 1_024 * 1_024,
                mimeType: "video/mp4"
            )]
        )
        let previewVideoContent = String(
            data: try! ProtocolJSON.encoder().encode(previewVideoPayload),
            encoding: .utf8
        )!
        pages = [
            // [修改] UI 专项固定覆盖收藏、转发来源和表情回应的气泡展示与长按入口。
            2: [
                ChatMessage(
                    messageId: 1,
                    senderId: 2,
                    receiverId: 1,
                    content: "晚点把照片传到网盘",
                    createdAt: 1,
                    isFavorite: true,
                    reactions: ["👍": [1, 2]],
                    forwardFrom: "小周"
                ),
                // [修改] 真机 UI 专项直接从聊天样例进入视频预览，不依赖上传或正式服务数据。
                ChatMessage(
                    messageId: 3,
                    senderId: 2,
                    receiverId: 1,
                    content: previewVideoContent,
                    msgType: "MIXED",
                    createdAt: 3
                )
            ],
            3: [ChatMessage(messageId: 2, senderId: 3, receiverId: 1, content: "新的聊天背景很舒服", createdAt: 2)],
            4: []
        ]
    }

    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage {
        ChatHistoryPage(messages: pages[friendId] ?? [], hasMore: false, nextBeforeMessageId: nil, latestMessageId: nil)
    }
    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt {
        try! ProtocolJSON.decoder().decode(ChatReceipt.self, from: Data(#"{"success":true,"data":{"messageId":999,"status":"SUCCESS"}}"#.utf8))
    }
    func send(friendId: Int64, content: String, messageType: String, clientMessageId: String) async throws -> ChatReceipt {
        try await send(friendId: friendId, content: content, clientMessageId: clientMessageId)
    }
    func markRead(friendId: Int64) async throws {}
    func searchMessages(friendId: Int64?, keyword: String, limit: Int) async throws -> [ChatMessage] {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return pages
            .filter { friendId == nil || $0.key == friendId }
            .flatMap(\.value)
            .filter { $0.conversationSummary.localizedCaseInsensitiveContains(normalized) }
            .prefix(max(1, limit))
            .map { $0 }
    }
    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] { [] }
    func addFriend(userId: Int64, message: String) async throws {}
    func pendingRequests() async throws -> [FriendRequestItem] { Self.previewPendingRequests }
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws {}
    func updateAlias(relationshipId: Int64, alias: String) async throws {}
}

actor PreviewDriveRepository: DriveRepository {
    // [修改] 预览数据也提供递归目录树，UI 测试和首次体验能看到真实的目录导航。
    private let root = try! ProtocolJSON.decoder().decode(DriveFileEntry.self, from: Data(#"{"id":1,"pId":0,"fileName":"我的网盘","isFile":"N","hasChild":"Y","childFileList":[{"id":2,"pId":1,"fileName":"照片","isFile":"N","hasChild":"Y","childFileList":[{"id":5,"pId":2,"fileName":"旅行","isFile":"N","hasChild":"N"}]}]}"#.utf8))
    private let sampleFiles = [
        try! ProtocolJSON.decoder().decode(DriveFileEntry.self, from: Data(#"{"id":2,"pId":1,"fileName":"照片","isFile":"N","hasChild":"N"}"#.utf8)),
        try! ProtocolJSON.decoder().decode(DriveFileEntry.self, from: Data(#"{"id":3,"pId":1,"fileName":"产品设计稿.pdf","fileSize":2437120,"fileType":"pdf","isFile":"Y"}"#.utf8)),
        try! ProtocolJSON.decoder().decode(DriveFileEntry.self, from: Data(#"{"id":4,"pId":1,"fileName":"旅行演示.mp4","fileSize":8388608,"fileType":"mp4","isFile":"Y"}"#.utf8))
    ]
    func roots() async throws -> [DriveFileEntry] { [root] }
    func directoryChildren(id: Int64) async throws -> [DriveFileEntry] {
        id == root.id ? root.children : []
    }
    func listFiles(directoryId: Int64, page: Int, pageSize: Int, search: String) async throws -> DrivePage {
        let responsePage = try! ProtocolJSON.decoder().decode(DrivePage.self, from: Data(#"{"recordList":[{"id":3,"pId":1,"fileName":"产品设计稿.pdf","fileSize":2437120,"fileType":"pdf","isFile":"Y"},{"id":4,"pId":1,"fileName":"旅行演示.mp4","fileSize":8388608,"fileType":"mp4","isFile":"Y"}],"currentPage":1,"pageSize":20,"totalCount":2}"#.utf8))
        guard !search.isEmpty else { return responsePage }
        // [修改] 预览仓库也遵守服务端搜索形态，方便 UI 样例验证。
        let records = responsePage.records.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return DrivePage(records: records, currentPage: 1, pageSize: pageSize, totalCount: Int64(records.count))
    }
    func createDirectory(parentId: Int64, name: String) async throws {}
    func renameDirectory(id: Int64, name: String) async throws {}
    func deleteDirectory(id: Int64) async throws {}
    func moveDirectory(id: Int64, targetParentId: Int64) async throws {}
    func fileDetail(id: Int64) async throws -> DriveFileEntry {
        sampleFiles.first(where: { $0.id == id }) ?? root
    }
    func renameFile(id: Int64, name: String) async throws {}
    func deleteFile(id: Int64) async throws {}
}

// [修改] UI 测试使用稳定的本地动态时间线，不依赖真机网络和数据库迁移状态。
actor PreviewDynamicRepository: DynamicRepository {
    private var posts: [DynamicPost] = [
        DynamicPost(
            id: 1001,
            author: DynamicAuthor(id: 2, username: "xiaolin", nickname: "林晓", avatar: nil),
            content: "把旅行照片整理进网盘后，终于可以慢慢翻看这段夏天。",
            media: [
                DynamicMedia(kind: .image, fileId: 77, fileName: "海边.jpg", fileSize: 2_048_000, mimeType: "image/jpeg")
            ],
            reference: nil,
            likeCount: 12,
            replyCount: 3,
            repostCount: 2,
            liked: false,
            reposted: false,
            originalPost: nil,
            createdAt: Int64(Date().addingTimeInterval(-1_800).timeIntervalSince1970 * 1_000),
            isMine: false
        ),
        DynamicPost(
            id: 1002,
            author: DynamicAuthor(id: 1, username: "spring-arthas", nickname: "Veneno", avatar: nil),
            content: "新的聊天和网盘体验已经连起来了。",
            media: [],
            reference: nil,
            likeCount: 5,
            replyCount: 1,
            repostCount: 0,
            liked: true,
            reposted: false,
            originalPost: nil,
            createdAt: Int64(Date().addingTimeInterval(-7_200).timeIntervalSince1970 * 1_000),
            isMine: true
        )
    ]

    func create(_ request: DynamicCreateRequest) async throws -> DynamicCreateResult {
        let post = DynamicPost(
            id: (posts.map(\.id).max() ?? 1000) + 1,
            author: DynamicAuthor(id: 1, username: "spring-arthas", nickname: "Veneno", avatar: nil),
            content: request.content,
            media: request.media,
            reference: request.reference,
            likeCount: 0,
            replyCount: 0,
            repostCount: 0,
            liked: false,
            reposted: false,
            originalPost: nil,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
            isMine: true
        )
        posts.insert(post, at: 0)
        return DynamicCreateResult(dynamicId: post.id, post: post)
    }

    func timeline(scope: DynamicTimelineScope, beforeId: Int64?, limit: Int) async throws -> DynamicTimelinePage {
        let scoped = scope == .mine ? posts.filter(\.isMine) : posts
        let filtered = beforeId.map { cursor in scoped.filter { $0.id < cursor } } ?? scoped
        let page = Array(filtered.prefix(max(1, limit)))
        return DynamicTimelinePage(posts: page, nextBeforeId: nil, hasMore: false)
    }

    func action(dynamicId: Int64, action: DynamicAction) async throws -> DynamicActionResult {
        guard let post = posts.first(where: { $0.id == dynamicId }) else {
            throw DynamicRepositoryError.server(message: "动态不存在", code: "NOT_FOUND")
        }
        return DynamicActionResult(
            dynamicId: dynamicId,
            action: action,
            likeCount: max(0, post.likeCount + (action == .like ? 1 : action == .unlike ? -1 : 0)),
            replyCount: post.replyCount + (action.content == nil ? 0 : 1),
            repostCount: max(0, post.repostCount + (action == .repost ? 1 : action == .unrepost ? -1 : 0)),
            liked: action == .like ? true : action == .unlike ? false : post.liked,
            reposted: action == .repost ? true : action == .unrepost ? false : post.reposted
        )
    }

    func detail(dynamicId: Int64, beforeReplyId: Int64?, limit: Int) async throws -> DynamicPostDetail {
        guard let post = posts.first(where: { $0.id == dynamicId }) else {
            throw DynamicRepositoryError.server(message: "动态不存在", code: "NOT_FOUND")
        }
        // [修改] 样例仓库遵守详情分页协议，当前固定数据没有更多回复。
        return DynamicPostDetail(post: post, replies: [], nextBeforeReplyId: nil, hasMore: false)
    }

    func delete(dynamicId: Int64) async throws {
        posts.removeAll { $0.id == dynamicId && $0.isMine }
    }
}

// [修改] UI 测试只需要稳定的签名播放地址，不依赖本机 net-server 或真实媒体文件。
actor PreviewMediaRepository: MediaPlaybackProviding {
    func playback(fileId: Int64, username: String) async throws -> MediaPlayback {
        guard let url = URL(string: "https://127.0.0.1:9/media/preview-\(fileId).mp4") else {
            throw MediaRepositoryError.invalidResponse
        }
        return MediaPlayback(
            fileId: fileId,
            playURL: url,
            fileSize: 8 * 1_024 * 1_024,
            mimeType: "video/mp4",
            expiresInSeconds: 300
        )
    }
}

// [修改] 样例聊天视频只走媒体流，非视频附件下载在该模式下明确不可用。
actor PreviewAttachmentDownloadManager: FileDownloadManaging {
    func download(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        destinationURL: URL
    ) async throws -> DownloadResult {
        throw ChatAttachmentPreviewError.invalidFile
    }
}

enum PreviewFriends {
    static let all = [
        ChatFriend(relationshipId: 12, userId: 1, friendId: 2, alias: "小林", username: "xiaolin", nickname: "林晓", unreadCount: 2, latestMessage: "晚点把照片传到网盘", isOnline: true),
        ChatFriend(relationshipId: 13, userId: 1, friendId: 3, username: "design-team", nickname: "设计讨论", latestMessage: "新的聊天背景很舒服", isPinned: true, pinnedAt: 100),
        ChatFriend(relationshipId: 14, userId: 1, friendId: 4, username: "azhe", nickname: "阿哲", latestMessage: "收到，明天见")
    ]
}

extension AuthenticatedUser {
    static let preview = AuthenticatedUser(id: 1, username: "spring-arthas", nickname: "Veneno", avatar: nil, email: nil, phone: nil, status: 1, transferToken: "preview", sessionToken: "preview")
}
