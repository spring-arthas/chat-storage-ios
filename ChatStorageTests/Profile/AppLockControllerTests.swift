import XCTest
@testable import ChatStorage

@MainActor
final class AppLockControllerTests: XCTestCase {
    func testEnablingLockAuthenticatesAndPersistsPreference() async {
        let preferences = ProfilePreferencesController(store: MemoryProfilePreferencesStore())
        let authenticator = ProfileBiometricAuthenticator(results: [.success(true)])
        let controller = AppLockController(preferences: preferences, authenticator: authenticator)

        await controller.setEnabled(true)

        XCTAssertTrue(preferences.appLockEnabled)
        XCTAssertFalse(controller.isLocked)
        let requestCount = await authenticator.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testBackgroundLocksAndSuccessfulAuthenticationUnlocks() async {
        let store = MemoryProfilePreferencesStore(initial: ProfilePreferences(appLockEnabled: true))
        let preferences = ProfilePreferencesController(store: store)
        let authenticator = ProfileBiometricAuthenticator(results: [.success(true)])
        let controller = AppLockController(preferences: preferences, authenticator: authenticator)

        controller.lockIfNeeded()
        XCTAssertTrue(controller.isLocked)

        await controller.unlock()

        XCTAssertFalse(controller.isLocked)
    }

    func testFailedAuthenticationDoesNotEnableLock() async {
        let preferences = ProfilePreferencesController(store: MemoryProfilePreferencesStore())
        let controller = AppLockController(
            preferences: preferences,
            authenticator: ProfileBiometricAuthenticator(results: [.success(false)])
        )

        await controller.setEnabled(true)

        XCTAssertFalse(preferences.appLockEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }
}

private final class MemoryProfilePreferencesStore: ProfilePreferencesStoring, @unchecked Sendable {
    private var value: ProfilePreferences

    init(initial: ProfilePreferences = .default) { value = initial }
    func load() -> ProfilePreferences { value }
    func save(_ preferences: ProfilePreferences) { value = preferences }
}

private actor ProfileBiometricAuthenticator: BiometricAuthenticating {
    private var results: [Result<Bool, Error>]
    private(set) var requestCount = 0

    init(results: [Result<Bool, Error>]) { self.results = results }

    func authenticate(reason: String) async throws -> Bool {
        requestCount += 1
        return try results.removeFirst().get()
    }
}
