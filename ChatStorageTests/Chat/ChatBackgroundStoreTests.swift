import XCTest
@testable import ChatStorage

final class ChatBackgroundStoreTests: XCTestCase {
    func testSaveLoadAndRemoveAreScopedByFriend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatBackgroundStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatBackgroundStore(directory: directory)
        let image = Data([0x01, 0x02, 0x03])

        try await store.save(image, friendId: 42)

        let saved = try await store.load(friendId: 42)
        let otherFriend = try await store.load(friendId: 43)
        XCTAssertEqual(saved, image)
        XCTAssertNil(otherFriend)
        try await store.remove(friendId: 42)
        let removed = try await store.load(friendId: 42)
        XCTAssertNil(removed)
    }
}
