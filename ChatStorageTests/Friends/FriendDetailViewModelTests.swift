import XCTest
@testable import ChatStorage

@MainActor
final class FriendDetailViewModelTests: XCTestCase {
    func testSaveAliasTrimsAndPublishesUpdatedAlias() async {
        let repository = FriendDetailRepository()
        let model = FriendDetailViewModel(friend: .fixture, repository: repository)
        model.alias = "  新备注  "

        let saved = await model.saveAlias()

        XCTAssertTrue(saved)
        XCTAssertEqual(model.alias, "新备注")
        XCTAssertEqual(model.savedAlias, "新备注")
        let updates = await repository.aliasUpdates
        XCTAssertEqual(updates, [.init(relationshipId: 12, alias: "新备注")])
    }

    func testSaveAliasRejectsBlankValueWithoutCallingRepository() async {
        let repository = FriendDetailRepository()
        let model = FriendDetailViewModel(friend: .fixture, repository: repository)
        model.alias = "   "

        let saved = await model.saveAlias()

        XCTAssertFalse(saved)
        XCTAssertEqual(model.errorMessage, "备注不能为空")
        let updates = await repository.aliasUpdates
        XCTAssertTrue(updates.isEmpty)
    }
}

private actor FriendDetailRepository: ChatRepository {
    struct AliasUpdate: Equatable {
        let relationshipId: Int64
        let alias: String
    }

    nonisolated let messages = AsyncStream<ChatMessage> { $0.finish() }
    private(set) var aliasUpdates: [AliasUpdate] = []

    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage {
        .init(messages: [], hasMore: false, nextBeforeMessageId: nil, latestMessageId: nil)
    }
    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt { fatalError() }
    func markRead(friendId: Int64) async throws {}
    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] { [] }
    func addFriend(userId: Int64, message: String) async throws {}
    func pendingRequests() async throws -> [FriendRequestItem] { [] }
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws {}
    func updateAlias(relationshipId: Int64, alias: String) async throws {
        aliasUpdates.append(.init(relationshipId: relationshipId, alias: alias))
    }
}

private extension ChatFriend {
    static let fixture = ChatFriend(
        relationshipId: 12,
        userId: 7,
        friendId: 9,
        alias: "旧备注",
        username: "bob",
        nickname: "Bob"
    )
}
