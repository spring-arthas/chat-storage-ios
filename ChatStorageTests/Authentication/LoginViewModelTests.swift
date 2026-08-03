import XCTest
@testable import ChatStorage

@MainActor
final class LoginViewModelTests: XCTestCase {
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
}

actor FakeAuthRepository: AuthRepository {
    private let loginResult: Result<AuthenticatedUser, Error>
    private let delay: Duration?
    private(set) var loginCallCount = 0

    init(loginResult: Result<AuthenticatedUser, Error>, delay: Duration? = nil) {
        self.loginResult = loginResult
        self.delay = delay
    }

    func login(account: String, password: String) async throws -> AuthenticatedUser {
        loginCallCount += 1
        if let delay { try await Task.sleep(for: delay) }
        return try loginResult.get()
    }

    func resumeSession() async throws -> AuthenticatedUser? { nil }
    func logout() async {}
}

extension AuthenticatedUser {
    static let fixture = AuthenticatedUser(id: 42, username: "alice", nickname: "Alice", avatar: nil, email: "alice@example.com", phone: nil, status: 1, transferToken: "transfer", sessionToken: "session")
}
