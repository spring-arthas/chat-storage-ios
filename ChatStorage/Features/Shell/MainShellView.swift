import SwiftUI

private struct MainShellTransferRuntimeKey: Hashable {
    let serverScopeID: String
    let userId: Int64
    let username: String
}

@MainActor
private final class MainShellTransferRuntime {
    let key: MainShellTransferRuntimeKey
    let credentialStore: TransferCredentialStore
    let store: FileTransferTaskStore
    let manager: TransferManager?
    let attachmentUploader: (any ChatAttachmentUploading)?
    let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    let mediaRepository: any MediaPlaybackProviding

    init(
        user: AuthenticatedUser,
        configuration: ServerConfiguration,
        preferences: ProfilePreferencesController
    ) {
        let token = user.transferToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        key = MainShellTransferRuntimeKey(
            serverScopeID: configuration.storageScopeID,
            userId: user.id,
            username: user.username
        )
        let credentialStore = TransferCredentialStore(
            identity: TransferIdentity(userId: user.id, username: user.username, transferToken: token)
        )
        self.credentialStore = credentialStore
        let store = FileTransferTaskStore.serverScoped(configuration: configuration)
        self.store = store
        // [修改] 播放地址请求使用登录后传输令牌，服务端从令牌派生真实用户。
        let mediaRepository = RemoteMediaRepository(configuration: configuration, credentialStore: credentialStore)
        self.mediaRepository = mediaRepository
        // [修改] 即使首次响应暂缺 transferToken 也保留同一 manager，后续会话激活可原地补齐凭据。
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: user.id, username: user.username, transferToken: token),
            credentialStore: credentialStore,
            store: store,
            wifiOnlyTransfers: preferences.wifiOnlyTransfers
        )
        self.manager = manager
        attachmentUploader = RemoteChatAttachmentUploader(manager: manager)
        attachmentPreviewProvider = DefaultChatAttachmentPreviewProvider(
            downloadManager: manager,
            mediaRepository: mediaRepository,
            username: user.username,
            serverScopeID: configuration.storageScopeID,
            userId: user.id
        )
    }

    func updateCredentials(user: AuthenticatedUser) {
        guard user.id == key.userId, user.username == key.username else { return }
        let token = user.transferToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        credentialStore.update(
            TransferIdentity(userId: user.id, username: user.username, transferToken: token)
        )
    }

    func updateTransferPreferences(_ preferences: ProfilePreferencesController) {
        Task { await manager?.setWifiOnlyTransfers(preferences.wifiOnlyTransfers) }
    }
}

// [修改] SwiftUI 重建或应用锁切换时复用同一传输运行时，避免两套 manager 重复恢复同一任务。
@MainActor
private final class MainShellTransferRuntimeRegistry {
    static let shared = MainShellTransferRuntimeRegistry()
    private var runtimes: [MainShellTransferRuntimeKey: MainShellTransferRuntime] = [:]

    func runtime(
        user: AuthenticatedUser,
        configuration: ServerConfiguration,
        preferences: ProfilePreferencesController
    ) -> MainShellTransferRuntime {
        let key = MainShellTransferRuntimeKey(
            serverScopeID: configuration.storageScopeID,
            userId: user.id,
            username: user.username
        )
        if let existing = runtimes[key] {
            existing.updateCredentials(user: user)
            existing.updateTransferPreferences(preferences)
            return existing
        }
        let runtime = MainShellTransferRuntime(
            user: user,
            configuration: configuration,
            preferences: preferences
        )
        runtimes[key] = runtime
        return runtime
    }

    func shutdownAndRemove(_ runtime: MainShellTransferRuntime) async {
        await runtime.manager?.shutdown()
        if runtimes[runtime.key] === runtime { runtimes.removeValue(forKey: runtime.key) }
    }

    func shutdownForConfigurationChange(_ runtime: MainShellTransferRuntime) async {
        await runtime.manager?.shutdown()
    }

    func remove(_ runtime: MainShellTransferRuntime) {
        if runtimes[runtime.key] === runtime { runtimes.removeValue(forKey: runtime.key) }
    }
}

@MainActor
struct MainShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    let user: AuthenticatedUser
    let authRepository: any AuthRepository
    let friendRepository: any FriendRepository
    let chatRepository: any ChatRepository
    let driveRepository: any DriveRepository
    let dynamicRepository: any DynamicRepository
    let configuration: ServerConfiguration
    let sampleMode: Bool
    let preferences: ProfilePreferencesController
    let messageRouteStore: MessageNotificationRouteStore
    let appLockController: AppLockController
    let onSaveConfiguration: (ServerConfiguration) async throws -> Void
    let onLogout: () async -> Void
    let onUserUpdated: (AuthenticatedUser) -> Void
    private let transferStore: FileTransferTaskStore
    private let transferManager: TransferManager?
    private let attachmentUploader: (any ChatAttachmentUploading)?
    private let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    private let mediaRepository: any MediaPlaybackProviding
    private let transferRuntime: MainShellTransferRuntime
    // [修改] 头像更新后由 onUserUpdated 刷新本地用户信息。
    @State private var currentUser: AuthenticatedUser
    @State private var totalUnreadCount = 0
    @State private var selectedTab: MainShellTab = .messages
    // [修改] 动态未完成草稿按服务器和用户隔离，切换账号后不会串出上一账号的媒体。
    @State private var dynamicComposerRouteStore: DynamicComposerRouteStore
    @State private var messageNotificationVisibility = MessageNotificationVisibilityState()
    private let messageNotificationCoordinator: MessageNotificationCoordinator

    init(
        user: AuthenticatedUser,
        authRepository: any AuthRepository,
        friendRepository: any FriendRepository,
        chatRepository: any ChatRepository,
        driveRepository: any DriveRepository,
        dynamicRepository: any DynamicRepository,
        configuration: ServerConfiguration,
        sampleMode: Bool,
        preferences: ProfilePreferencesController,
        messageRouteStore: MessageNotificationRouteStore = MessageNotificationRouteStore(),
        appLockController: AppLockController,
        onSaveConfiguration: @escaping (ServerConfiguration) async throws -> Void,
        onLogout: @escaping () async -> Void,
        onUserUpdated: @escaping (AuthenticatedUser) -> Void = { _ in }
    ) {
        self.user = user
        _currentUser = State(initialValue: user)
        self.authRepository = authRepository
        self.friendRepository = friendRepository
        self.chatRepository = chatRepository
        self.driveRepository = driveRepository
        self.dynamicRepository = dynamicRepository
        self.configuration = configuration
        self.sampleMode = sampleMode
        self.preferences = preferences
        self.messageRouteStore = messageRouteStore
        self.appLockController = appLockController
        self.onSaveConfiguration = onSaveConfiguration
        self.onLogout = onLogout
        self.onUserUpdated = onUserUpdated
        _dynamicComposerRouteStore = State(initialValue: DynamicComposerRouteStore(
            persistenceKey: "\(configuration.storageScopeID)-\(user.id)"
        ))
        let runtime = MainShellTransferRuntimeRegistry.shared.runtime(
            user: user,
            configuration: configuration,
            preferences: preferences
        )
        transferRuntime = runtime
        transferStore = runtime.store
        transferManager = runtime.manager
        attachmentUploader = runtime.attachmentUploader
        // [修改] UI 测试使用本地预览仓库，避免视频控件测试被真实网络和证书环境阻塞。
        let selectedMediaRepository: any MediaPlaybackProviding = sampleMode
            ? PreviewMediaRepository()
            : runtime.mediaRepository
        mediaRepository = selectedMediaRepository
        // [修改] 样例聊天附件与网盘共用同一个预览媒体仓库，正式模式继续使用真实传输凭据。
        attachmentPreviewProvider = sampleMode
            ? DefaultChatAttachmentPreviewProvider(
                downloadManager: PreviewAttachmentDownloadManager(),
                mediaRepository: selectedMediaRepository,
                username: user.username,
                serverScopeID: configuration.storageScopeID,
                userId: user.id
            )
            : runtime.attachmentPreviewProvider
        messageNotificationCoordinator = MessageNotificationCoordinator(
            center: SystemMessageNotificationCenter(),
            routeStore: messageRouteStore,
            previewEnabled: { preferences.notificationPreviewEnabled }
        )
    }

    var body: some View {
        shellTabs
            .tint(AppTheme.primaryGreen)
            .task { await transferManager?.reschedulePending() }
            .onChange(of: messageRouteStore.pendingFriendId, initial: true) { _, friendId in
                if friendId != nil { selectedTab = .messages }
            }
            .onChange(of: selectedTab, initial: true) { _, tab in
                messageNotificationVisibility.isMessagesTabActive = tab == .messages
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                messageNotificationVisibility.isSceneActive = phase == .active
            }
            .onChange(of: user) { _, refreshedUser in
                // [修改] 会话激活拿到新头像或 token 后同步当前页面用户，运行时凭据已由 registry 原地更新。
                currentUser = refreshedUser
            }
    }

    // [修改] Tab 容器与生命周期监听分别类型推断，避免真机构建时单个 body 超过编译器时限。
    private var shellTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("消息", systemImage: "bubble.left.and.bubble.right.fill", value: MainShellTab.messages) {
                messagesPage
            }
            .badge(totalUnreadCount)
            // [修改] 动态固定放在消息和网盘之间，复用同一控制 Socket 和附件上传链路。
            Tab("动态", systemImage: "quote.bubble.fill", value: MainShellTab.dynamics) {
                dynamicsPage
            }
            Tab("网盘", systemImage: "externaldrive.fill", value: MainShellTab.drive) {
                drivePage
            }
            Tab("我的", systemImage: "person.crop.circle.fill", value: MainShellTab.profile) {
                profilePage
            }
        }
    }

    // [修改] 拆开大段 TabView 泛型表达式，避免 Swift 编译器在真机构建时类型推断超时。
    private var messagesPage: some View {
        MessagesPlaceholderView(
            repository: friendRepository,
            chatRepository: chatRepository,
            user: currentUser,
            attachmentUploader: attachmentUploader,
            attachmentPreviewProvider: attachmentPreviewProvider,
            sampleMode: sampleMode,
            totalUnreadCount: $totalUnreadCount,
            messageRouteStore: messageRouteStore,
            notificationCoordinator: messageNotificationCoordinator,
            // [修改] Tab/前后台变化写入持久状态，长期 Socket 监听每条消息都读取最新值。
            notificationVisibility: messageNotificationVisibility,
            dynamicComposerRouteStore: dynamicComposerRouteStore,
            onOpenDynamicComposer: { selectedTab = .dynamics }
        )
    }

    private var dynamicsPage: some View {
        DynamicTimelineView(
            repository: dynamicRepository,
            composerRouteStore: dynamicComposerRouteStore,
            attachmentUploader: attachmentUploader,
            attachmentPreviewProvider: attachmentPreviewProvider,
            currentUser: currentUser
        )
    }

    private var drivePage: some View {
        DrivePlaceholderView(
            repository: driveRepository,
            transferStore: transferStore,
            transferManager: transferManager,
            transferCenterManager: transferManager,
            mediaRepository: mediaRepository,
            userId: currentUser.id,
            username: currentUser.username,
            serverScopeID: configuration.storageScopeID,
            dynamicComposerRouteStore: dynamicComposerRouteStore,
            onOpenDynamicComposer: { selectedTab = .dynamics }
        )
    }

    private var profilePage: some View {
        ProfilePlaceholderView(
            user: currentUser,
            authRepository: authRepository,
            configuration: configuration,
            preferences: preferences,
            appLockController: appLockController,
            transferStore: transferStore,
            transferManager: transferManager,
            userId: currentUser.id,
            serverScopeID: configuration.storageScopeID,
            onSaveConfiguration: saveConfiguration,
            onLogout: logout,
            onUserUpdated: updateUser
        )
    }

    private func saveConfiguration(_ configuration: ServerConfiguration) async throws {
        await MainShellTransferRuntimeRegistry.shared.shutdownForConfigurationChange(transferRuntime)
        do {
            try await onSaveConfiguration(configuration)
            MainShellTransferRuntimeRegistry.shared.remove(transferRuntime)
        } catch {
            // [修改] 切服保存失败时恢复原队列，当前页面不能永久停在等待登录状态。
            await transferManager?.reschedulePending()
            throw error
        }
    }

    private func logout() async {
        await MainShellTransferRuntimeRegistry.shared.shutdownAndRemove(transferRuntime)
        await onLogout()
    }

    private func updateUser(_ user: AuthenticatedUser) {
        transferRuntime.updateCredentials(user: user)
        currentUser = user
        // [修改] 页面头像、传输凭据和根 AppSession 使用同一个用户事实源。
        onUserUpdated(user)
    }
}

private enum MainShellTab: Hashable {
    case messages
    case dynamics
    case drive
    case profile
}
