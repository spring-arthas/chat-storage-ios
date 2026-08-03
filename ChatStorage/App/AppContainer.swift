import Foundation

@MainActor
final class AppContainer {
    let configurationStore: UserDefaultsServerConfigurationStore
    var configuration: ServerConfiguration
    let authRepository: any AuthRepository
    let friendRepository: any FriendRepository
    let session: AppSession

    init(
        configurationStore: UserDefaultsServerConfigurationStore,
        configuration: ServerConfiguration,
        authRepository: any AuthRepository,
        friendRepository: any FriendRepository
    ) {
        self.configurationStore = configurationStore
        self.configuration = configuration
        self.authRepository = authRepository
        self.friendRepository = friendRepository
        self.session = AppSession(repository: authRepository)
    }

    static func live() -> AppContainer {
        let configurationStore = UserDefaultsServerConfigurationStore()
        let configuration = (try? configurationStore.load()) ?? .default
        let connection = NWControlConnection(configuration: configuration)
        let client = RequestResponseClient(connection: connection)
        let authRepository = RemoteAuthRepository(client: client, secureStore: KeychainSecureStore())
        let friendRepository = RemoteFriendRepository(client: client)
        return AppContainer(
            configurationStore: configurationStore,
            configuration: configuration,
            authRepository: authRepository,
            friendRepository: friendRepository
        )
    }

    func save(configuration: ServerConfiguration) throws {
        try configurationStore.save(configuration)
        self.configuration = configuration
    }
}

actor PreviewAuthRepository: AuthRepository {
    let user: AuthenticatedUser?
    init(user: AuthenticatedUser?) { self.user = user }
    func login(account: String, password: String) async throws -> AuthenticatedUser { user ?? .preview }
    func resumeSession() async throws -> AuthenticatedUser? { user }
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
