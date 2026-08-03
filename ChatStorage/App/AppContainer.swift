import Foundation

@MainActor
final class AppContainer {
    let configurationStore: UserDefaultsServerConfigurationStore
    var configuration: ServerConfiguration
    let authRepository: any AuthRepository
    let session: AppSession

    init(
        configurationStore: UserDefaultsServerConfigurationStore,
        configuration: ServerConfiguration,
        authRepository: any AuthRepository
    ) {
        self.configurationStore = configurationStore
        self.configuration = configuration
        self.authRepository = authRepository
        self.session = AppSession(repository: authRepository)
    }

    static func live() -> AppContainer {
        let configurationStore = UserDefaultsServerConfigurationStore()
        let configuration = (try? configurationStore.load()) ?? .default
        let connection = NWControlConnection(configuration: configuration)
        let client = RequestResponseClient(connection: connection)
        let repository = RemoteAuthRepository(client: client, secureStore: KeychainSecureStore())
        return AppContainer(configurationStore: configurationStore, configuration: configuration, authRepository: repository)
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

extension AuthenticatedUser {
    static let preview = AuthenticatedUser(id: 1, username: "spring-arthas", nickname: "Veneno", avatar: nil, email: nil, phone: nil, status: 1, transferToken: "preview", sessionToken: "preview")
}
