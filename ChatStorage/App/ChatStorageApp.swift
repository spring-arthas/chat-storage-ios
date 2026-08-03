import SwiftUI

enum AppIdentity {
    static let displayName = "Chat Storage"
}

@main
struct ChatStorageApp: App {
    @State private var container: AppContainer
    @State private var showsServerSettings = false
    private let uiTestMode: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-uiTestMode"), arguments.indices.contains(index + 1) {
            uiTestMode = arguments[index + 1]
        } else {
            uiTestMode = nil
        }
        let user = uiTestMode == "authenticated" ? AuthenticatedUser.preview : nil
        let store = UserDefaultsServerConfigurationStore(defaults: UserDefaults(suiteName: "ChatStorage.UITests") ?? .standard)
        let container = AppContainer(configurationStore: store, configuration: .default, authRepository: PreviewAuthRepository(user: user))
        _container = State(initialValue: uiTestMode == nil ? AppContainer.live() : container)
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .task {
                    if uiTestMode == "unauthenticated" {
                        return
                    }
                    await container.session.restore()
                }
                .sheet(isPresented: $showsServerSettings) {
                    ServerSettingsView(configuration: container.configuration) { configuration in
                        try container.save(configuration: configuration)
                    }
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if uiTestMode == "unauthenticated" {
            LoginView(
                model: LoginViewModel(repository: container.authRepository),
                serverDescription: "\(container.configuration.host):\(container.configuration.controlPort)",
                onAuthenticated: container.session.authenticate,
                onOpenServerSettings: { showsServerSettings = true }
            )
        } else {
            switch container.session.state {
            case .restoring:
                ZStack { PatternBackground(); ProgressView().tint(.white).controlSize(.large) }
            case .unauthenticated:
                LoginView(
                    model: LoginViewModel(repository: container.authRepository),
                    serverDescription: "\(container.configuration.host):\(container.configuration.controlPort)",
                    onAuthenticated: container.session.authenticate,
                    onOpenServerSettings: { showsServerSettings = true }
                )
            case .authenticated(let user):
                MainShellView(user: user, sampleMode: uiTestMode == "authenticated")
            }
        }
    }
}
