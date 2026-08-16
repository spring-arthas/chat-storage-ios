import XCTest
@testable import ChatStorage

@MainActor
final class LoginViewModelTests: XCTestCase {
    func testProductionLoginModelPrefillsTestCredentials() {
        let repository = FakeAuthRepository(loginResult: .success(.fixture))

        let model = LoginViewModel.production(repository: repository)

        XCTAssertEqual(model.account, "18806504525")
        XCTAssertEqual(model.password, "spring")
    }

    func testRegistrationRejectsMismatchedPasswordsWithoutCallingRepository() async {
        let repository = FakeAuthRepository(loginResult: .success(.fixture))
        let model = RegistrationViewModel(repository: repository)
        model.account = "18806504525"
        model.email = "alice@example.com"
        model.password = "secret"
        model.confirmPassword = "different"

        await model.register()

        XCTAssertEqual(model.state, .failed("两次输入的密码不一致"))
        let registerCallCount = await repository.registerCallCount
        XCTAssertEqual(registerCallCount, 0)
    }

    func testRegistrationSuccessClearsPasswordsAndReturnsRegisteredUser() async {
        let repository = FakeAuthRepository(loginResult: .success(.fixture))
        let model = RegistrationViewModel(repository: repository)
        model.account = "18806504525"
        model.email = "alice@example.com"
        model.password = "secret"
        model.confirmPassword = "secret"
        model.avatarData = "avatar-base64"

        await model.register()

        XCTAssertEqual(model.state, .registered(.fixture))
        XCTAssertEqual(model.password, "")
        XCTAssertEqual(model.confirmPassword, "")
        let request = await repository.lastRegisterRequest
        XCTAssertEqual(request?.account, "18806504525")
        XCTAssertEqual(request?.email, "alice@example.com")
        XCTAssertEqual(request?.avatarData, "avatar-base64")
    }

    func testLoginSuccessTransitionsToAuthenticatedAndClearsPassword() async {
        let repository = FakeAuthRepository(loginResult: .success(.fixture))
        let model = LoginViewModel(repository: repository)
        model.account = "alice"
        model.password = "secret"

        await model.login()

        XCTAssertEqual(model.state, .authenticated(.fixture))
        XCTAssertEqual(model.password, "")
    }

    func testEmptyAccountShowsValidationErrorWithoutCallingRepository() async {
        let repository = FakeAuthRepository(loginResult: .success(.fixture))
        let model = LoginViewModel(repository: repository)
        model.password = "secret"

        await model.login()

        XCTAssertEqual(model.state, .failed("请输入用户名"))
        let loginCallCount = await repository.loginCallCount
        XCTAssertEqual(loginCallCount, 0)
    }

    func testEmptyPasswordShowsValidationError() async {
        let model = LoginViewModel(repository: FakeAuthRepository(loginResult: .success(.fixture)))
        model.account = "alice"

        await model.login()

        XCTAssertEqual(model.state, .failed("请输入密码"))
    }

    func testDoubleSubmitIsPreventedWhileLoading() async {
        let repository = FakeAuthRepository(loginResult: .success(.fixture), delay: .milliseconds(50))
        let model = LoginViewModel(repository: repository)
        model.account = "alice"
        model.password = "secret"

        async let first: Void = model.login()
        await Task.yield()
        await model.login()
        await first

        let loginCallCount = await repository.loginCallCount
        XCTAssertEqual(loginCallCount, 1)
    }

    func testServerErrorTextIsPresented() async {
        let repository = FakeAuthRepository(loginResult: .failure(AuthError.server(message: "密码错误", code: nil)))
        let model = LoginViewModel(repository: repository)
        model.account = "alice"
        model.password = "wrong"

        await model.login()

        XCTAssertEqual(model.state, .failed("密码错误"))
    }

    func testFaceIDRestoresStoredSession() async {
        let repository = FakeAuthRepository(loginResult: .success(.fixture), resumedUser: .fixture)
        let model = LoginViewModel(repository: repository)

        await model.loginWithBiometrics(using: LoginBiometricAuthenticator(result: true))

        XCTAssertEqual(model.state, .authenticated(.fixture))
        let resumeCallCount = await repository.resumeCallCount
        XCTAssertEqual(resumeCallCount, 1)
    }
}

actor FakeAuthRepository: AuthRepository {
    private let loginResult: Result<AuthenticatedUser, Error>
    private let delay: Duration?
    private let resumedUser: AuthenticatedUser?
    private(set) var loginCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var registerCallCount = 0
    private(set) var lastRegisterRequest: RegisterCall?

    init(loginResult: Result<AuthenticatedUser, Error>, delay: Duration? = nil, resumedUser: AuthenticatedUser? = nil) {
        self.loginResult = loginResult
        self.delay = delay
        self.resumedUser = resumedUser
    }

    func login(account: String, password: String) async throws -> AuthenticatedUser {
        loginCallCount += 1
        if let delay { try await Task.sleep(for: delay) }
        return try loginResult.get()
    }

    func register(
        account: String,
        email: String,
        password: String,
        avatarData: String?,
        avatarName: String?
    ) async throws -> AuthenticatedUser {
        registerCallCount += 1
        lastRegisterRequest = RegisterCall(
            account: account,
            email: email,
            password: password,
            avatarData: avatarData,
            avatarName: avatarName
        )
        return .fixture
    }

    func resumeSession() async throws -> AuthenticatedUser? {
        resumeCallCount += 1
        return resumedUser
    }

    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser {
        AuthenticatedUser(
            id: 42,
            username: "alice",
            nickname: "Alice",
            avatar: avatarData,
            email: "alice@example.com",
            phone: nil,
            status: 1,
            transferToken: "transfer",
            sessionToken: "session"
        )
    }
    func logout() async {}
}

struct RegisterCall: Equatable, Sendable {
    let account: String
    let email: String
    let password: String
    let avatarData: String?
    let avatarName: String?
}

private struct LoginBiometricAuthenticator: BiometricAuthenticating {
    let result: Bool
    func authenticate(reason: String) async throws -> Bool { result }
}

extension AuthenticatedUser {
    static let fixture = AuthenticatedUser(id: 42, username: "alice", nickname: "Alice", avatar: nil, email: "alice@example.com", phone: nil, status: 1, transferToken: "transfer", sessionToken: "session")
}
