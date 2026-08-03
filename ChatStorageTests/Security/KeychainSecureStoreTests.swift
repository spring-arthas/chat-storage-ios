import XCTest
@testable import ChatStorage

final class KeychainSecureStoreTests: XCTestCase {
    private var store: KeychainSecureStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = KeychainSecureStore(service: "KeychainSecureStoreTests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try store.removeAll()
        store = nil
        try super.tearDownWithError()
    }

    func testSetAndReadSessionToken() throws {
        let token = Data("session-token".utf8)

        try store.set(token, for: .sessionToken)

        XCTAssertEqual(try store.data(for: .sessionToken), token)
    }

    func testUpdateReplacesExistingValue() throws {
        try store.set(Data("old-token".utf8), for: .transferToken)

        try store.set(Data("new-token".utf8), for: .transferToken)

        XCTAssertEqual(try store.data(for: .transferToken), Data("new-token".utf8))
    }

    func testRemoveDeletesOnlySelectedKey() throws {
        try store.set(Data("session".utf8), for: .sessionToken)
        try store.set(Data("user".utf8), for: .currentUser)

        try store.remove(.sessionToken)

        XCTAssertNil(try store.data(for: .sessionToken))
        XCTAssertEqual(try store.data(for: .currentUser), Data("user".utf8))
    }
}
