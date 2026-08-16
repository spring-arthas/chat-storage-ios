import XCTest
@testable import ChatStorage

@MainActor
final class FriendManagementViewModelTests: XCTestCase {
    // [修改] 服务端用 friendStatus=3、friendStatusDesc=添加 表示可申请，不能因为描述非空就隐藏按钮。
    func testSearchResultWithServerAddStatusExposesAddAction() throws {
        let result = try ProtocolJSON.decoder().decode(
            ChatUserSearchResult.self,
            from: Data(#"{"userId":9,"userName":"bob","friendStatus":3,"friendStatusDesc":"添加"}"#.utf8)
        )

        XCTAssertTrue(result.canSendFriendRequest)
        XCTAssertEqual(result.friendActionTitle, "添加")
    }

    func testExistingFriendDoesNotExposeAddAction() throws {
        let result = try ProtocolJSON.decoder().decode(
            ChatUserSearchResult.self,
            from: Data(#"{"userId":9,"userName":"bob","friendStatus":1,"friendStatusDesc":"已是好友"}"#.utf8)
        )

        XCTAssertFalse(result.canSendFriendRequest)
    }

    func testSearchAndAddFriendUpdatesResultStatus() async {
        let repository = FriendManagementRepository()
        let model = FriendManagementViewModel(repository: repository)

        await model.search(keyword: "bob")
        XCTAssertEqual(model.results.first?.username, "bob")
        await model.add(model.results[0])

        XCTAssertEqual(model.results.first?.friendStatusDescription, "等待对方同意")
        let searched = await repository.searchedKeywords
        let added = await repository.addedUserIds
        XCTAssertEqual(searched, ["bob"])
        XCTAssertEqual(added, [9])
    }

    func testAcceptRequestRefreshesPendingList() async {
        let repository = FriendManagementRepository(requests: [.fixture(id: 5)])
        let model = FriendManagementViewModel(repository: repository)

        await model.loadRequests()
        XCTAssertEqual(model.pendingRequests.count, 1)
        await model.handle(model.pendingRequests[0], accept: true)

        XCTAssertTrue(model.pendingRequests.isEmpty)
        let actions = await repository.handledActions
        XCTAssertEqual(actions.first?.0, 5)
        XCTAssertEqual(actions.first?.1, true)
    }
}

private actor FriendManagementRepository: ChatRepository {
    nonisolated let messages = AsyncStream<ChatMessage> { $0.finish() }
    private(set) var searchedKeywords: [String] = []
    private(set) var addedUserIds: [Int64] = []
    private(set) var handledActions: [(Int64, Bool)] = []
    private var requests: [FriendRequestItem]

    init(requests: [FriendRequestItem] = []) { self.requests = requests }
    func history(friendId: Int64, beforeMessageId: Int64?, limit: Int) async throws -> ChatHistoryPage { .init(messages: [], hasMore: false, nextBeforeMessageId: nil, latestMessageId: nil) }
    func send(friendId: Int64, content: String, clientMessageId: String) async throws -> ChatReceipt { fatalError() }
    func markRead(friendId: Int64) async throws {}
    func searchUsers(keyword: String) async throws -> [ChatUserSearchResult] { searchedKeywords.append(keyword); return [.init(id: 9, username: "bob", nickname: "Bob", avatar: nil, status: 1, friendStatus: nil, friendStatusDescription: nil, incomingRequestId: nil)] }
    func addFriend(userId: Int64, message: String) async throws { addedUserIds.append(userId) }
    func pendingRequests() async throws -> [FriendRequestItem] { requests }
    func handleFriendRequest(requestId: Int64, accept: Bool, alias: String?) async throws { handledActions.append((requestId, accept)); requests.removeAll { $0.id == requestId } }
    func updateAlias(relationshipId: Int64, alias: String) async throws {}
}

private extension FriendRequestItem {
    static func fixture(id: Int64) -> FriendRequestItem {
        try! ProtocolJSON.decoder().decode(FriendRequestItem.self, from: Data(#"{"id":5,"senderId":8,"receiverId":7,"requestMsg":"hello","status":0,"createTime":1,"userName":"alice","nickName":"Alice"}"#.utf8))
    }
}
