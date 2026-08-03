import XCTest
@testable import ChatStorage

final class RemoteFriendRepositoryTests: XCTestCase {
    func testRefreshDecodesAndroidFriendListAndPinState() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":[{"id":12,"userId":7,"friendId":9,"alias":"老王","userName":"bob","nickName":"Bob","avatar":"avatar-data","unread_count":3,"latestMsg":"晚上见","onlineStatus":"ONLINE","pinned":true,"pinnedAt":1785360000123}]}"#.utf8)
        let client = FriendFrameClient(responses: [Frame(type: .friendListResponse, payload: payload)])
        let repository = RemoteFriendRepository(client: client)

        let friends = try await repository.refresh()

        let friend = try XCTUnwrap(friends.first)
        XCTAssertEqual(friend.relationshipId, 12)
        XCTAssertEqual(friend.friendId, 9)
        XCTAssertEqual(friend.displayName, "老王")
        XCTAssertEqual(friend.unreadCount, 3)
        XCTAssertEqual(friend.latestMessage, "晚上见")
        XCTAssertTrue(friend.isOnline)
        XCTAssertTrue(friend.isPinned)
        XCTAssertEqual(friend.pinnedAt, 1_785_360_000_123)
        let sentFrames = await client.sentFrames
        XCTAssertEqual(sentFrames.first?.type, .friendListRequest)
        XCTAssertTrue(sentFrames.first?.payload.isEmpty == true)
    }

    func testLegacyFriendWithoutPinFieldsDefaultsToUnpinned() async throws {
        let payload = Data(#"{"success":true,"data":{"id":12,"userId":7,"friendId":9,"userName":"bob"}}"#.utf8)
        let repository = RemoteFriendRepository(client: FriendFrameClient(responses: [Frame(type: .friendListResponse, payload: payload)]))

        let friends = try await repository.refresh()
        let friend = try XCTUnwrap(friends.first)

        XCTAssertFalse(friend.isPinned)
        XCTAssertNil(friend.pinnedAt)
    }

    func testUpdatePinUsesRelationshipIdAndReturnsCanonicalState() async throws {
        let payload = Data(#"{"success":true,"data":{"relationshipId":12,"pinned":true,"pinnedAt":1785360000123}}"#.utf8)
        let client = FriendFrameClient(responses: [Frame(type: .friendPinUpdateResponse, payload: payload)])
        let repository = RemoteFriendRepository(client: client)

        let result = try await repository.updatePin(relationshipId: 12, pinned: true)

        XCTAssertEqual(result, FriendPinState(relationshipId: 12, isPinned: true, pinnedAt: 1_785_360_000_123))
        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        XCTAssertEqual(sent.type, .friendPinUpdateRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["relationshipId"] as? Int, 12)
        XCTAssertEqual(object["pinned"] as? Bool, true)
        XCTAssertNil(object["friendId"])
    }

    func testUpdatePinBusinessFailureThrowsWithoutResult() async {
        let payload = Data(#"{"success":false,"code":400,"message":"好友关系不存在","errorCode":"INVALID_REQUEST"}"#.utf8)
        let repository = RemoteFriendRepository(client: FriendFrameClient(responses: [Frame(type: .friendPinUpdateResponse, payload: payload)]))

        do {
            _ = try await repository.updatePin(relationshipId: 12, pinned: true)
            XCTFail("Expected server failure")
        } catch let error as FriendRepositoryError {
            XCTAssertEqual(error, .server(message: "好友关系不存在", code: "INVALID_REQUEST"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor FriendFrameClient: FrameRequesting {
    private var responses: [Frame]
    private(set) var sentFrames: [Frame] = []

    init(responses: [Frame]) {
        self.responses = responses
    }

    func connect() async throws {}

    func request(_ frame: Frame, expecting: Set<FrameType>, timeout: Duration) async throws -> Frame {
        sentFrames.append(frame)
        guard !responses.isEmpty else { throw RequestResponseError.closed }
        return responses.removeFirst()
    }
}
