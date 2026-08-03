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

    func testLogoutClearsAuthenticatedState() async {
        let repository = SessionAuthRepository(resumedUser: .fixture)
        let session = AppSession(repository: repository)
        await session.restore()

        await session.logout()

        XCTAssertEqual(session.state, .unauthenticated)
        let logoutCount = await repository.logoutCount
        XCTAssertEqual(logoutCount, 1)
    }
}

private actor SessionAuthRepository: AuthRepository {
    let resumedUser: AuthenticatedUser?
    private(set) var restoreCount = 0
    private(set) var logoutCount = 0

    init(resumedUser: AuthenticatedUser?) {
        self.resumedUser = resumedUser
    }

    func login(account: String, password: String) async throws -> AuthenticatedUser { .fixture }

    func resumeSession() async throws -> AuthenticatedUser? {
        restoreCount += 1
        return resumedUser
    }

    func logout() async {
        logoutCount += 1
    }
}
