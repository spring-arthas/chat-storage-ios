import SwiftUI
import UIKit
import UserNotifications

// [修改] 应用默认只允许竖屏，只有视频全屏期间临时开放横屏，退出后立即恢复竖屏。
@MainActor
enum AppOrientationController {
    private(set) static var videoFullscreen = false

    static var currentMask: UIInterfaceOrientationMask {
        supportedOrientations(videoFullscreen: videoFullscreen)
    }

    static func supportedOrientations(videoFullscreen: Bool) -> UIInterfaceOrientationMask {
        videoFullscreen ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }

    static func setVideoFullscreen(_ fullscreen: Bool) {
        videoFullscreen = fullscreen
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let preferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: supportedOrientations(videoFullscreen: fullscreen)
        )
        scene.requestGeometryUpdate(preferences) { _ in }
        // [修改] 通知当前控制器重新读取方向掩码，避免使用已废弃的全局旋转 API。
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

final class ChatStorageAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var notificationRouteStore: MessageNotificationRouteStore? {
        didSet {
            guard let pendingNotificationFriendId else { return }
            notificationRouteStore?.open(friendId: pendingNotificationFriendId)
            self.pendingNotificationFriendId = nil
        }
    }
    @MainActor private var pendingNotificationFriendId: Int64?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationController.currentMask
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let value = response.notification.request.content.userInfo[MessageNotificationUserInfo.friendIdKey]
        let friendId: Int64?
        switch value {
        case let number as NSNumber: friendId = number.int64Value
        case let text as String: friendId = Int64(text)
        default: friendId = nil
        }
        guard let friendId, friendId > 0 else { return }
        await MainActor.run {
            if let notificationRouteStore = self.notificationRouteStore {
                notificationRouteStore.open(friendId: friendId)
            } else {
                // [修改] 冷启动时 SwiftUI 根视图尚未绑定，先保留点击目标，绑定后再转交。
                self.pendingNotificationFriendId = friendId
            }
        }
    }
}

enum AppIdentity {
    static let displayName = "Chat Storage"
}

@main
struct ChatStorageApp: App {
    @UIApplicationDelegateAdaptor(ChatStorageAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer
    @State private var preferences: ProfilePreferencesController
    @State private var appLockController: AppLockController
    @State private var messageRouteStore: MessageNotificationRouteStore
    @State private var showsServerSettings = false
    private let biometricAuthenticator: any BiometricAuthenticating
    private let uiTestMode: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-uiTestMode"), arguments.indices.contains(index + 1) {
            uiTestMode = arguments[index + 1]
        } else {
            uiTestMode = nil
        }

        let user = uiTestMode == "authenticated" ? AuthenticatedUser.preview : nil
        // [修改] UI 回归测试可把会话恢复保持在进行中，验证首屏不会被网络等待阻塞。
        let restoreDelay: Duration? = {
            guard let modeIndex = arguments.firstIndex(of: "-uiTestMode"),
                  arguments.indices.contains(modeIndex + 1),
                  arguments[modeIndex + 1] == "slow-restoring",
                  let index = arguments.firstIndex(of: "-uiRestoreDelayMilliseconds"),
                  arguments.indices.contains(index + 1),
                  let milliseconds = Int64(arguments[index + 1]) else { return nil }
            return .milliseconds(max(0, milliseconds))
        }()
        let defaults = uiTestMode == nil
            ? UserDefaults.standard
            : (UserDefaults(suiteName: "ChatStorage.UITests") ?? .standard)
        let configurationStore = UserDefaultsServerConfigurationStore(defaults: defaults)
        let previewContainer = AppContainer(
            configurationStore: configurationStore,
            configuration: .default,
            authRepository: PreviewAuthRepository(user: user, resumeDelay: restoreDelay),
            friendRepository: PreviewFriendRepository(friends: PreviewFriends.all),
            chatRepository: PreviewChatRepository(),
            driveRepository: PreviewDriveRepository(),
            dynamicRepository: PreviewDynamicRepository()
        )
        let preferences = ProfilePreferencesController(
            store: UserDefaultsProfilePreferencesStore(defaults: defaults)
        )
        let authenticator: any BiometricAuthenticating = uiTestMode == nil
            ? SystemBiometricAuthenticator()
            : PreviewBiometricAuthenticator()

        _container = State(initialValue: uiTestMode == nil ? AppContainer.live(configurationStore: configurationStore) : previewContainer)
        _preferences = State(initialValue: preferences)
        _appLockController = State(initialValue: AppLockController(preferences: preferences, authenticator: authenticator))
        _messageRouteStore = State(initialValue: MessageNotificationRouteStore())
        biometricAuthenticator = authenticator
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(preferredColorScheme)
                .task { await resumeIfUnlocked() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await resumeIfUnlocked() }
                    } else {
                        appLockController.lockIfNeeded()
                    }
                }
                .sheet(isPresented: $showsServerSettings) {
                    ServerSettingsView(configuration: container.configuration, onSave: replaceConfiguration)
                }
                .task {
                    // [修改] AppDelegate 必须在系统通知点击发生前持有同一个路由对象。
                    appDelegate.notificationRouteStore = messageRouteStore
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if appLockController.isLocked {
            AppLockView(controller: appLockController, onUnlocked: resumeIfUnlocked)
        } else if uiTestMode == "unauthenticated" {
            loginView
        } else {
            switch container.session.state {
            case .restoring:
                // [修改] Socket 会话恢复在后台继续，登录控件先展示，弱网时用户仍可直接手动登录。
                loginView
                    .overlay(alignment: .top) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在恢复登录")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.34), in: Capsule())
                        .padding(.top, 12)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("session.restore-indicator")
                    }
            case .loggingOut:
                // [修改] 旧连接彻底关闭前只显示等待态，不暴露仍绑定旧 repository 的登录页。
                ZStack { PatternBackground(); ProgressView().tint(.white).controlSize(.large) }
            case .unauthenticated:
                loginView
            case .authenticated(let user):
                MainShellView(
                    user: user,
                    authRepository: container.authRepository,
                    friendRepository: container.friendRepository,
                    chatRepository: container.chatRepository,
                    driveRepository: container.driveRepository,
                    dynamicRepository: container.dynamicRepository,
                    configuration: container.configuration,
                    sampleMode: uiTestMode == "authenticated",
                    preferences: preferences,
                    messageRouteStore: messageRouteStore,
                    appLockController: appLockController,
                    onSaveConfiguration: replaceConfiguration,
                    onLogout: logout,
                    onUserUpdated: container.session.updateAuthenticatedUser
                )
            }
        }
    }

    private var loginView: some View {
        LoginView(
            // 测试阶段使用预填的联调账号和密码。
            model: LoginViewModel.production(repository: container.authRepository),
            authRepository: container.authRepository,
            serverDescription: "\(container.configuration.host):\(container.configuration.controlPort)",
            biometricAuthenticator: biometricAuthenticator,
            onAuthenticated: container.session.authenticate,
            onOpenServerSettings: { showsServerSettings = true }
        )
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    @MainActor
    private func resumeIfUnlocked() async {
        guard uiTestMode != "unauthenticated", !appLockController.isLocked else { return }
        await container.session.resumeForForeground()
    }

    @MainActor
    private func replaceConfiguration(_ configuration: ServerConfiguration) async throws {
        let store = container.configurationStore
        try store.save(configuration)
        await container.shutdownForConfigurationChange()
        container = AppContainer.live(configurationStore: store, configuration: configuration)
    }

    @MainActor
    private func logout() async {
        let store = container.configurationStore
        let configuration = container.configuration
        await container.shutdown()
        messageRouteStore.reset()
        if uiTestMode == nil {
            container = AppContainer.live(configurationStore: store, configuration: configuration)
        } else {
            container = AppContainer(
                configurationStore: store,
                configuration: configuration,
                authRepository: PreviewAuthRepository(user: nil),
                friendRepository: PreviewFriendRepository(friends: PreviewFriends.all),
                chatRepository: PreviewChatRepository(),
                driveRepository: PreviewDriveRepository(),
                dynamicRepository: PreviewDynamicRepository()
            )
        }
    }
}

private struct PreviewBiometricAuthenticator: BiometricAuthenticating {
    func authenticate(reason: String) async throws -> Bool { true }
}
