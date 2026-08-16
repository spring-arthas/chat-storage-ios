import XCTest
@testable import ChatStorage

@MainActor
final class AppSessionTests: XCTestCase {
    func testRestoreAuthenticatesStoredSessionOnlyOnce() async {
        let repository = SessionAuthRepository(resumedUser: .fixture)
        let session = AppSession(repository: repository)

        await session.restore()
        await session.restore()

        XCTAssertEqual(session.state, .authenticated(.fixture))
        let restoreCount = await repository.restoreCount
        XCTAssertEqual(restoreCount, 1)
    }

    func testRestoreWithoutStoredSessionBecomesUnauthenticated() async {
        let session = AppSession(repository: SessionAuthRepository(resumedUser: nil))

        await session.restore()

        XCTAssertEqual(session.state, .unauthenticated)
    }

    // [修改] 慢恢复期间用户手动登录后，迟到的旧恢复结果不能覆盖新会话。
    func testLateRestoreResultCannotOverwriteManualLogin() async {
        let restoredUser = AuthenticatedUser.fixture(
            transferToken: "restored-transfer",
            sessionToken: "restored-session"
        )
        let manuallyLoggedInUser = AuthenticatedUser.fixture(
            transferToken: "manual-transfer",
            sessionToken: "manual-session"
        )
        let repository = BlockingRestoreAuthRepository(restoredUser: restoredUser)
        let session = AppSession(repository: repository)

        let restoring = Task { await session.restore() }
        await repository.waitUntilRestoreStarted()
        session.authenticate(manuallyLoggedInUser)
        await repository.releaseRestore()
        await restoring.value

        XCTAssertEqual(session.state, .authenticated(manuallyLoggedInUser))
    }

    func testLogoutClearsAuthenticatedState() async {
        let repository = SessionAuthRepository(resumedUser: .fixture)
        let session = AppSession(repository: repository)
        await session.restore()

        await session.logout()

        XCTAssertEqual(session.state, .unauthenticated)
        let logoutCount = await repository.logoutCount
        XCTAssertEqual(logoutCount, 1)
    }

    func testProfileMutationUpdatesAuthenticatedSessionUser() {
        let session = AppSession(repository: SessionAuthRepository(resumedUser: .fixture))
        session.authenticate(.fixture)
        let updated = AuthenticatedUser(
            id: AuthenticatedUser.fixture.id,
            username: AuthenticatedUser.fixture.username,
            nickname: AuthenticatedUser.fixture.nickname,
            avatar: "new-avatar",
            email: AuthenticatedUser.fixture.email,
            phone: AuthenticatedUser.fixture.phone,
            status: AuthenticatedUser.fixture.status,
            transferToken: AuthenticatedUser.fixture.transferToken,
            sessionToken: AuthenticatedUser.fixture.sessionToken
        )

        // [修改] 头像更新必须回写根会话，避免 Tab 页面和 AppSession 各持有一份不同用户。
        session.updateAuthenticatedUser(updated)

        XCTAssertEqual(session.state, .authenticated(updated))
    }

    func testProfileMutationCannotRestoreSessionAfterLogout() async {
        let session = AppSession(repository: SessionAuthRepository(resumedUser: .fixture))
        session.authenticate(.fixture)
        await session.logout()

        session.updateAuthenticatedUser(.fixture)

        XCTAssertEqual(session.state, .unauthenticated)
    }

    // [修改] 远程登出依赖控制连接，容器销毁时必须先发登出请求再关闭客户端。
    func testContainerShutdownLogsOutBeforeClosingClient() async throws {
        let recorder = ShutdownOrderRecorder()
        let authRepository = ShutdownAuthRepository(recorder: recorder)
        let client = ShutdownFrameClient(recorder: recorder)
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppContainerTests.\(UUID().uuidString)"))
        let container = AppContainer(
            configurationStore: UserDefaultsServerConfigurationStore(defaults: defaults),
            configuration: configuration,
            authRepository: authRepository,
            friendRepository: PreviewFriendRepository(friends: []),
            chatRepository: PreviewChatRepository(),
            driveRepository: PreviewDriveRepository(),
            dynamicRepository: PreviewDynamicRepository(),
            client: client
        )

        await container.shutdown()

        let events = await recorder.events
        XCTAssertEqual(events, [.logout, .close])
    }

    // [修改] 切换服务器只关闭旧 socket，不发 logout，Keychain 会话才能交给新地址继续恢复。
    func testContainerConfigurationChangeClosesClientWithoutLogout() async throws {
        let recorder = ShutdownOrderRecorder()
        let authRepository = ShutdownAuthRepository(recorder: recorder)
        let client = ShutdownFrameClient(recorder: recorder)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ConfigurationShutdownTests.\(UUID().uuidString)"))
        let container = AppContainer(
            configurationStore: UserDefaultsServerConfigurationStore(defaults: defaults),
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            authRepository: authRepository,
            friendRepository: PreviewFriendRepository(friends: []),
            chatRepository: PreviewChatRepository(),
            driveRepository: PreviewDriveRepository(),
            dynamicRepository: PreviewDynamicRepository(),
            client: client
        )
        container.session.authenticate(.fixture)

        await container.shutdownForConfigurationChange()

        let events = await recorder.events
        XCTAssertEqual(events, [.close])
    }

    // [修改] 旧客户端 close 完成前必须维持退出门禁，不能提前开放登录页使用旧 repository。
    func testContainerKeepsLoginBlockedUntilClientCloseFinishes() async throws {
        let authRepository = SessionAuthRepository(resumedUser: .fixture)
        let client = BlockingCloseFrameClient()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ShutdownGateTests.\(UUID().uuidString)"))
        let container = AppContainer(
            configurationStore: UserDefaultsServerConfigurationStore(defaults: defaults),
            configuration: .default,
            authRepository: authRepository,
            friendRepository: PreviewFriendRepository(friends: []),
            chatRepository: PreviewChatRepository(),
            driveRepository: PreviewDriveRepository(),
            dynamicRepository: PreviewDynamicRepository(),
            client: client
        )
        container.session.authenticate(.fixture)

        let shutdown = Task { await container.shutdown() }
        let closeStarted = await waitUntil(timeout: 1) {
            await client.closeStarted
        }
        XCTAssertTrue(closeStarted)
        XCTAssertNotEqual(container.session.state, .unauthenticated)

        await client.finishClose()
        await shutdown.value
        XCTAssertEqual(container.session.state, .unauthenticated)
    }

    func testActivateReconnectsAnAuthenticatedSession() async {
        let repository = SessionAuthRepository(resumedUser: .fixture)
        let session = AppSession(repository: repository)
        await session.restore()

        await session.activate()

        XCTAssertEqual(session.state, .authenticated(.fixture))
        let activationCount = await repository.activationCount
        XCTAssertEqual(activationCount, 1)
    }

    // [修改] 前台 0x46 返回晚于退出时，旧激活结果不能把已退出账号重新登录。
    func testForegroundActivationCannotRestoreSessionAfterLogout() async {
        let repository = BlockingActivationAuthRepository()
        let session = AppSession(repository: repository)
        session.authenticate(.fixture)
        let activation = Task { await session.activate() }
        let activationStarted = await waitUntil(timeout: 1) {
            await repository.activationStarted
        }
        XCTAssertTrue(activationStarted)

        let logout = Task { await session.logout() }
        let becameUnauthenticated = await waitUntil(timeout: 1) {
            await MainActor.run { session.state != .authenticated(.fixture) }
        }
        XCTAssertTrue(becameUnauthenticated)
        await repository.releaseActivation()
        await activation.value
        await logout.value

        XCTAssertEqual(session.state, .unauthenticated)
    }

    // [修改] logout 必须等待前台 0x46 真正退出，不能先向服务端发送登出再留下旧请求。
    func testLogoutWaitsForInFlightForegroundActivation() async {
        let repository = BlockingActivationAuthRepository()
        let session = AppSession(repository: repository)
        session.authenticate(.fixture)
        let activation = Task { await session.activate() }
        let activationStarted = await waitUntil(timeout: 1) {
            await repository.activationStarted
        }
        XCTAssertTrue(activationStarted)

        let logout = Task { await session.logout() }
        try? await Task.sleep(for: .milliseconds(50))
        let logoutCountBeforeRelease = await repository.logoutCount
        XCTAssertEqual(logoutCountBeforeRelease, 0)

        await repository.releaseActivation()
        await activation.value
        await logout.value
        let finalLogoutCount = await repository.logoutCount
        XCTAssertEqual(finalLogoutCount, 1)
    }

    // [修改] 首次进入前台恢复本地会话，之后每次回到前台都重新绑定控制连接并刷新令牌。
    func testResumeForForegroundRestoresThenActivatesOnNextForeground() async {
        let refreshed = AuthenticatedUser.fixture(
            transferToken: "refreshed-transfer",
            sessionToken: "refreshed-session"
        )
        let repository = SessionAuthRepository(resumedUser: .fixture, activatedUser: refreshed)
        let session = AppSession(repository: repository)

        await session.resumeForForeground()
        await session.resumeForForeground()

        let restoreCount = await repository.restoreCount
        let activationCount = await repository.activationCount
        XCTAssertEqual(session.state, .authenticated(refreshed))
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(activationCount, 1)
    }

    // [修改] 认证成功后必须周期发送真实心跳，不能只依赖 TCP 连接对象的表面状态。
    func testAuthenticatedSessionSendsPeriodicHeartbeat() async {
        let repository = SessionAuthRepository(resumedUser: .fixture)
        let session = AppSession(
            repository: repository,
            heartbeatInterval: 0.02,
            reconnectDelays: [0, 0.02]
        )

        session.authenticate(.fixture)

        let heartbeatSent = await waitUntil(timeout: 1) {
            await repository.heartbeatCount >= 1
        }
        XCTAssertTrue(heartbeatSent)
        await session.logout()
    }

    // [修改] 心跳失败后先重建 TLS 连接，再用 0x46 恢复会话和最新令牌。
    func testHeartbeatFailureReconnectsAndResumesSession() async {
        let refreshed = AuthenticatedUser.fixture(
            transferToken: "transfer-after-reconnect",
            sessionToken: "session-after-reconnect"
        )
        let repository = SessionAuthRepository(
            resumedUser: .fixture,
            activatedUser: refreshed,
            heartbeatFailuresRemaining: 1
        )
        let session = AppSession(
            repository: repository,
            heartbeatInterval: 0.01,
            reconnectDelays: [0, 0.02]
        )
        session.authenticate(.fixture)

        let recovered = await waitUntil(timeout: 1) {
            await repository.activationCount >= 1
        }

        XCTAssertTrue(recovered)
        XCTAssertEqual(session.state, .authenticated(refreshed))
        let reconnectCount = await repository.reconnectCount
        let networkEvents = await repository.networkEvents
        XCTAssertEqual(reconnectCount, 1)
        XCTAssertEqual(Array(networkEvents.prefix(3)), ["heartbeat", "reconnect", "activate"])
        await session.logout()
    }

    // [修改] Wi-Fi/蜂窝网络从离线恢复时立即重连，不等待旧退避计时结束。
    func testNetworkRecoveryReconnectsImmediately() async {
        let monitor = TestNetworkAvailabilityMonitor()
        let repository = SessionAuthRepository(resumedUser: .fixture)
        let session = AppSession(
            repository: repository,
            heartbeatInterval: 60,
            reconnectDelays: [30],
            networkMonitor: monitor
        )
        session.authenticate(.fixture)

        monitor.send(isAvailable: false)
        monitor.send(isAvailable: true)

        let recovered = await waitUntil(timeout: 1) {
            await repository.activationCount >= 1
        }
        XCTAssertTrue(recovered)
        await session.logout()
    }

    // [修改] 被新代次替换的旧 0x46 即使忽略取消并返回 nil，也不能注销新重连会话。
    func testCancelledReconnectReturningNilCannotLogoutNewGeneration() async {
        let monitor = TestNetworkAvailabilityMonitor()
        let refreshed = AuthenticatedUser.fixture(
            transferToken: "new-generation-transfer",
            sessionToken: "new-generation-session"
        )
        let repository = ReplacedReconnectAuthRepository(refreshedUser: refreshed)
        let session = AppSession(
            repository: repository,
            heartbeatInterval: 0.01,
            reconnectDelays: [0, 0.01],
            networkMonitor: monitor
        )
        session.authenticate(.fixture)
        let firstActivationStarted = await waitUntil(timeout: 1) {
            await repository.firstActivationStarted
        }
        XCTAssertTrue(firstActivationStarted)

        monitor.send(isAvailable: false)
        monitor.send(isAvailable: true)
        let oldGenerationCancelled = await waitUntil(timeout: 1) {
            await repository.firstActivationCancellationObserved
        }
        XCTAssertTrue(oldGenerationCancelled)
        await repository.releaseFirstActivation()

        let newGenerationRecovered = await waitUntil(timeout: 1) {
            let activationCount = await repository.activationCount
            let state = await MainActor.run { session.state }
            return activationCount >= 2 && state == .authenticated(refreshed)
        }
        XCTAssertTrue(newGenerationRecovered)
        XCTAssertEqual(session.state, .authenticated(refreshed))
        await session.logout()
    }

    // [修改] 退出登录必须停止心跳和退避重连，旧任务不能把用户重新登录。
    func testLogoutCancelsHeartbeatAndReconnectTasks() async {
        let repository = SessionAuthRepository(
            resumedUser: .fixture,
            heartbeatFailuresRemaining: 1,
            activationError: RequestResponseError.closed
        )
        let session = AppSession(
            repository: repository,
            heartbeatInterval: 0.01,
            reconnectDelays: [0, 0.03]
        )
        session.authenticate(.fixture)
        _ = await waitUntil(timeout: 1) {
            await repository.activationCount >= 1
        }

        await session.logout()
        let heartbeatCountAfterLogout = await repository.heartbeatCount
        let activationCountAfterLogout = await repository.activationCount
        try? await Task.sleep(for: .milliseconds(120))
        let finalHeartbeatCount = await repository.heartbeatCount
        let finalActivationCount = await repository.activationCount

        XCTAssertEqual(session.state, .unauthenticated)
        XCTAssertEqual(finalHeartbeatCount, heartbeatCountAfterLogout)
        XCTAssertEqual(finalActivationCount, activationCountAfterLogout)
    }

    // [修改] logout 返回前必须等旧重连任务退出，避免返回后仍有 0x46 在后台发送。
    func testLogoutWaitsForInFlightReconnectTaskToFinishCancellation() async {
        let repository = SlowCancellationAuthRepository()
        let session = AppSession(
            repository: repository,
            heartbeatInterval: 0.01,
            reconnectDelays: [0]
        )
        session.authenticate(.fixture)
        let activationStarted = await waitUntil(timeout: 1) {
            await repository.activationStarted
        }
        XCTAssertTrue(activationStarted)

        await session.logout()

        let activationFinished = await repository.activationFinished
        XCTAssertTrue(activationFinished)
        XCTAssertEqual(session.state, .unauthenticated)
    }

    // [修改] transferToken 带服务端毫秒过期时间，客户端只读取过期字段用于提前刷新，不信任其中身份。
    func testTransferTokenExpirationParsesServerTokenFormat() {
        let expiration = Date(timeIntervalSince1970: 1_900_000_000)
        let token = makeTransferToken(expiresAt: expiration)

        XCTAssertEqual(
            TransferTokenExpiration.expirationDate(from: token),
            expiration
        )
        XCTAssertNil(TransferTokenExpiration.expirationDate(from: "opaque-token"))
        XCTAssertNil(TransferTokenExpiration.expirationDate(from: "1:name:not-a-date:nonce:signature"))
    }

    // [修改] 网盘令牌到期前自动走会话恢复，拿到新 transferToken 后更新 AppSession 用户。
    func testRestoreSchedulesAutomaticTransferTokenRefresh() async {
        let initial = AuthenticatedUser.fixture(
            transferToken: makeTransferToken(expiresAt: Date().addingTimeInterval(0.35)),
            sessionToken: "session-before-refresh"
        )
        let refreshed = AuthenticatedUser.fixture(
            transferToken: "opaque-refreshed-token",
            sessionToken: "session-after-refresh"
        )
        let repository = SessionAuthRepository(resumedUser: initial, activatedUser: refreshed)
        let session = AppSession(
            repository: repository,
            transferTokenRefreshLeadTime: 0.20,
            refreshRetryDelay: 0.05
        )

        await session.restore()

        let refreshedInTime = await waitUntil(timeout: 1.5) {
            await repository.activationCount == 1
        }
        XCTAssertTrue(refreshedInTime)
        XCTAssertEqual(session.state, .authenticated(refreshed))
    }

    // [修改] 退出登录必须取消后台令牌刷新，不能在已退出后重新建立认证状态。
    func testLogoutCancelsScheduledTransferTokenRefresh() async {
        let initial = AuthenticatedUser.fixture(
            transferToken: makeTransferToken(expiresAt: Date().addingTimeInterval(0.30)),
            sessionToken: "session-before-logout"
        )
        let repository = SessionAuthRepository(resumedUser: initial, activatedUser: .fixture)
        let session = AppSession(
            repository: repository,
            transferTokenRefreshLeadTime: 0.15,
            refreshRetryDelay: 0.05
        )
        await session.restore()

        await session.logout()
        try? await Task.sleep(for: .milliseconds(350))

        let activationCount = await repository.activationCount
        XCTAssertEqual(session.state, .unauthenticated)
        XCTAssertEqual(activationCount, 0)
    }

    // [修改] 应用锁或 SwiftUI 重建主界面时必须复用同一传输运行时，不能重复恢复持久任务。
    func testMainShellReusesTransferRuntimeForSameServerAndUser() throws {
        let configuration = try ServerConfiguration(host: "runtime-\(UUID().uuidString).local")
        let first = makeMainShell(configuration: configuration)
        let second = makeMainShell(configuration: configuration)

        let firstManager = try XCTUnwrap(transferManager(in: first))
        let secondManager = try XCTUnwrap(transferManager(in: second))
        let firstStore = try XCTUnwrap(transferStore(in: first))
        let secondStore = try XCTUnwrap(transferStore(in: second))
        XCTAssertTrue(firstManager === secondManager)
        XCTAssertTrue(firstStore === secondStore)
    }

    // [修改] transferToken 刷新不能创建第二套 manager；同一账号运行时原地更新凭据。
    func testMainShellReusesTransferRuntimeWhenTransferTokenRefreshes() throws {
        let configuration = try ServerConfiguration(host: "runtime-refresh-\(UUID().uuidString).local")
        let firstUser = AuthenticatedUser.fixture(transferToken: "old-token", sessionToken: "session-1")
        let refreshedUser = AuthenticatedUser.fixture(transferToken: "new-token", sessionToken: "session-2")
        let first = makeMainShell(user: firstUser, configuration: configuration)
        let second = makeMainShell(user: refreshedUser, configuration: configuration)

        let firstManager = try XCTUnwrap(transferManager(in: first))
        let secondManager = try XCTUnwrap(transferManager(in: second))
        XCTAssertTrue(firstManager === secondManager)
    }

    private func makeMainShell(
        user: AuthenticatedUser = .fixture,
        configuration: ServerConfiguration
    ) -> MainShellView {
        let defaults = UserDefaults(suiteName: "MainShellRuntimeTests.\(UUID().uuidString)") ?? .standard
        let preferences = ProfilePreferencesController(
            store: UserDefaultsProfilePreferencesStore(defaults: defaults)
        )
        let lockController = AppLockController(
            preferences: preferences,
            authenticator: RuntimeBiometricAuthenticator()
        )
        return MainShellView(
            user: user,
            authRepository: SessionAuthRepository(resumedUser: user),
            friendRepository: PreviewFriendRepository(friends: []),
            chatRepository: PreviewChatRepository(),
            driveRepository: PreviewDriveRepository(),
            // [修改] MainShellView 新增动态依赖，测试继续使用本地预览仓库保持隔离。
            dynamicRepository: PreviewDynamicRepository(),
            configuration: configuration,
            sampleMode: true,
            preferences: preferences,
            appLockController: lockController,
            onSaveConfiguration: { _ in },
            onLogout: {}
        )
    }

    private func transferManager(in shell: MainShellView) -> TransferManager? {
        guard let value = Mirror(reflecting: shell).children.first(where: { $0.label == "transferManager" })?.value else {
            return nil
        }
        return Mirror(reflecting: value).children.first?.value as? TransferManager
    }

    private func transferStore(in shell: MainShellView) -> FileTransferTaskStore? {
        Mirror(reflecting: shell).children.first(where: { $0.label == "transferStore" })?.value as? FileTransferTaskStore
    }

    private func makeTransferToken(expiresAt: Date) -> String {
        let milliseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000)
        return "42:YWxpY2U:\(milliseconds):nonce:signature"
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

private struct RuntimeBiometricAuthenticator: BiometricAuthenticating {
    func authenticate(reason: String) async throws -> Bool { true }
}

private actor BlockingRestoreAuthRepository: AuthRepository {
    private let restoredUser: AuthenticatedUser
    private var restoreStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreContinuation: CheckedContinuation<Void, Never>?

    init(restoredUser: AuthenticatedUser) {
        self.restoredUser = restoredUser
    }

    func login(account: String, password: String) async throws -> AuthenticatedUser { restoredUser }

    func resumeSession() async throws -> AuthenticatedUser? {
        restoreStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { restoreContinuation = $0 }
        return restoredUser
    }

    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser {
        restoredUser
    }

    func logout() async {}

    func waitUntilRestoreStarted() async {
        guard !restoreStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseRestore() {
        restoreContinuation?.resume()
        restoreContinuation = nil
    }
}

private actor ShutdownOrderRecorder {
    enum Event: Equatable, Sendable {
        case logout
        case close
    }

    private(set) var events: [Event] = []

    func append(_ event: Event) {
        events.append(event)
    }
}

private actor ShutdownAuthRepository: AuthRepository {
    private let recorder: ShutdownOrderRecorder

    init(recorder: ShutdownOrderRecorder) {
        self.recorder = recorder
    }

    func login(account: String, password: String) async throws -> AuthenticatedUser { .fixture }
    func resumeSession() async throws -> AuthenticatedUser? { .fixture }
    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser { .fixture }
    func logout() async { await recorder.append(.logout) }
}

private actor ShutdownFrameClient: FrameRequesting {
    private let recorder: ShutdownOrderRecorder

    init(recorder: ShutdownOrderRecorder) {
        self.recorder = recorder
    }

    func connect() async throws {}
    func close() async { await recorder.append(.close) }

    func request(
        _ frame: Frame,
        expecting expectedTypes: Set<FrameType>,
        timeout: Duration
    ) async throws -> Frame {
        throw RequestResponseError.closed
    }
}

// [修改] 模拟 logout 后 client.close 仍在收尾，验证整个 shutdown 期间登录入口保持关闭。
private actor BlockingCloseFrameClient: FrameRequesting {
    private(set) var closeStarted = false
    private var closeContinuation: CheckedContinuation<Void, Never>?

    func connect() async throws {}

    func close() async {
        closeStarted = true
        await withCheckedContinuation { continuation in
            closeContinuation = continuation
        }
    }

    func request(
        _ frame: Frame,
        expecting expectedTypes: Set<FrameType>,
        timeout: Duration
    ) async throws -> Frame {
        throw RequestResponseError.closed
    }

    func finishClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }
}

private actor SessionAuthRepository: AuthRepository {
    let resumedUser: AuthenticatedUser?
    let activatedUser: AuthenticatedUser?
    private var heartbeatFailuresRemaining: Int
    private let activationError: Error?
    private(set) var restoreCount = 0
    private(set) var logoutCount = 0
    private(set) var activationCount = 0
    private(set) var heartbeatCount = 0
    private(set) var reconnectCount = 0
    private(set) var networkEvents: [String] = []

    init(
        resumedUser: AuthenticatedUser?,
        activatedUser: AuthenticatedUser? = nil,
        heartbeatFailuresRemaining: Int = 0,
        activationError: Error? = nil
    ) {
        self.resumedUser = resumedUser
        self.activatedUser = activatedUser ?? resumedUser
        self.heartbeatFailuresRemaining = heartbeatFailuresRemaining
        self.activationError = activationError
    }

    func login(account: String, password: String) async throws -> AuthenticatedUser { .fixture }

    func resumeSession() async throws -> AuthenticatedUser? {
        restoreCount += 1
        return resumedUser
    }

    func logout() async {
        logoutCount += 1
    }

    func activate() async throws -> AuthenticatedUser? {
        activationCount += 1
        networkEvents.append("activate")
        if let activationError { throw activationError }
        return activatedUser
    }

    func reconnect() async throws {
        reconnectCount += 1
        networkEvents.append("reconnect")
    }

    func heartbeat() async throws {
        heartbeatCount += 1
        networkEvents.append("heartbeat")
        if heartbeatFailuresRemaining > 0 {
            heartbeatFailuresRemaining -= 1
            throw RequestResponseError.closed
        }
    }

    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser {
        let fallback = AuthenticatedUser.fixture
        return AuthenticatedUser(
            id: resumedUser?.id ?? fallback.id,
            username: resumedUser?.username ?? fallback.username,
            nickname: resumedUser?.nickname,
            avatar: avatarData,
            email: resumedUser?.email,
            phone: resumedUser?.phone,
            status: resumedUser?.status,
            transferToken: resumedUser?.transferToken,
            sessionToken: resumedUser?.sessionToken
        )
    }
}

// [修改] 模拟已经进入 0x46 的任务，即使收到取消也要稍后才退出，用于验证 logout 会等待收尾。
private actor SlowCancellationAuthRepository: AuthRepository {
    private(set) var activationStarted = false
    private(set) var activationFinished = false

    func login(account: String, password: String) async throws -> AuthenticatedUser { .fixture }
    func resumeSession() async throws -> AuthenticatedUser? { .fixture }
    func reconnect() async throws {}

    func activate() async throws -> AuthenticatedUser? {
        activationStarted = true
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                continuation.resume()
            }
        }
        activationFinished = true
        throw RequestResponseError.closed
    }

    func heartbeat() async throws {
        throw RequestResponseError.closed
    }

    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser {
        .fixture
    }

    func logout() async {}
}

// [修改] 首次重连激活忽略取消并迟到返回 nil，第二代次返回有效用户。
private actor ReplacedReconnectAuthRepository: AuthRepository {
    private let refreshedUser: AuthenticatedUser
    private var heartbeatFailuresRemaining = 1
    private var firstActivationContinuation: CheckedContinuation<Void, Never>?
    private(set) var firstActivationStarted = false
    private(set) var firstActivationCancellationObserved = false
    private(set) var activationCount = 0

    init(refreshedUser: AuthenticatedUser) {
        self.refreshedUser = refreshedUser
    }

    func login(account: String, password: String) async throws -> AuthenticatedUser { .fixture }
    func resumeSession() async throws -> AuthenticatedUser? { .fixture }
    func reconnect() async throws {}

    func activate() async throws -> AuthenticatedUser? {
        activationCount += 1
        if activationCount == 1 {
            firstActivationStarted = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    firstActivationContinuation = continuation
                }
            } onCancel: {
                Task { await self.recordFirstActivationCancellation() }
            }
            return nil
        }
        return refreshedUser
    }

    func heartbeat() async throws {
        if heartbeatFailuresRemaining > 0 {
            heartbeatFailuresRemaining -= 1
            throw RequestResponseError.closed
        }
    }

    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser {
        .fixture
    }

    func logout() async {}

    func releaseFirstActivation() {
        firstActivationContinuation?.resume()
        firstActivationContinuation = nil
    }

    private func recordFirstActivationCancellation() {
        firstActivationCancellationObserved = true
    }
}

// [修改] 模拟不响应任务取消的前台 0x46，验证 AppSession 自己管理激活任务的生命周期。
private actor BlockingActivationAuthRepository: AuthRepository {
    private(set) var activationStarted = false
    private(set) var logoutCount = 0
    private var activationContinuation: CheckedContinuation<Void, Never>?

    func login(account: String, password: String) async throws -> AuthenticatedUser { .fixture }
    func resumeSession() async throws -> AuthenticatedUser? { .fixture }

    func activate() async throws -> AuthenticatedUser? {
        activationStarted = true
        await withCheckedContinuation { continuation in
            activationContinuation = continuation
        }
        return AuthenticatedUser.fixture(
            transferToken: "late-transfer-token",
            sessionToken: "late-session-token"
        )
    }

    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser {
        .fixture
    }

    func logout() async {
        logoutCount += 1
    }

    func releaseActivation() {
        activationContinuation?.resume()
        activationContinuation = nil
    }
}

// [修改] 单元测试手动推送网络状态，验证离线到在线的恢复时机。
private final class TestNetworkAvailabilityMonitor: NetworkAvailabilityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?

    func start(_ handler: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func cancel() {
        lock.withLock { handler = nil }
    }

    func send(isAvailable: Bool) {
        let callback = lock.withLock { handler }
        callback?(isAvailable)
    }
}

private extension AuthenticatedUser {
    static func fixture(transferToken: String?, sessionToken: String?) -> AuthenticatedUser {
        AuthenticatedUser(
            id: fixture.id,
            username: fixture.username,
            nickname: fixture.nickname,
            avatar: fixture.avatar,
            email: fixture.email,
            phone: fixture.phone,
            status: fixture.status,
            transferToken: transferToken,
            sessionToken: sessionToken
        )
    }
}
