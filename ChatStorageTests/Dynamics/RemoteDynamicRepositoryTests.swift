import XCTest
@testable import ChatStorage

final class RemoteDynamicRepositoryTests: XCTestCase {
    // [修改] 发布协议允许纯媒体，并把引用卡片和兼容 imagePaths 一并编码到 0x60。
    func testCreateEncodesMediaReferenceAndDecodesFullPost() async throws {
        let response = dynamicFrame(.dynamicCreateResponse, #"{"success":true,"code":200,"data":{"dynamicId":90,"post":{"id":90,"author":{"userId":7,"userName":"alice","nickName":"Alice"},"content":"","media":[{"kind":"image","fileId":11,"fileName":"a.jpg","fileSize":12,"mimeType":"image/jpeg"}],"reference":{"sourceType":"driveFile","sourceId":"11","title":"a.jpg","subtitle":"12 B","media":[]},"likeCount":1,"replyCount":2,"repostCount":3,"liked":true,"reposted":false,"createdAt":1786500000000,"isMine":true}}}"#)
        let client = DynamicFrameClient(responses: [response])
        let repository = RemoteDynamicRepository(client: client)
        let media = DynamicMedia(kind: .image, fileId: 11, fileName: "a.jpg", fileSize: 12, mimeType: "image/jpeg")
        let reference = DynamicReference(sourceType: .driveFile, sourceId: "11", title: "a.jpg", subtitle: "12 B", media: [])

        let result = try await repository.create(DynamicCreateRequest(content: "", media: [media], imagePaths: "11", reference: reference))

        XCTAssertEqual(result.dynamicId, 90)
        XCTAssertEqual(result.post?.author.nickname, "Alice")
        XCTAssertEqual(result.post?.media, [media])
        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        XCTAssertEqual(sent.type, .dynamicCreateRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, "")
        XCTAssertEqual(object["imagePaths"] as? String, "11")
        XCTAssertEqual((object["media"] as? [[String: Any]])?.first?["fileId"] as? Int, 11)
        XCTAssertEqual((object["reference"] as? [String: Any])?["sourceType"] as? String, "driveFile")
    }

    // [修改] 时间线必须发送大写 scope，并兼容 records/items、大小写字段和 nextCursor 游标。
    func testTimelineUsesUppercaseScopeAndDecodesFlexiblePage() async throws {
        let payload = #"{"success":true,"data":{"records":[{"dynamicId":101,"userId":9,"userName":"bob","nickname":"Bob","content":"hello","images":[{"kind":"video","fileId":"22","fileName":"clip.mov","fileSize":"30","mimeType":"video/quicktime"}],"likes":"4","replyCount":2,"repostCount":1,"isLiked":1,"isReposted":"true","gmtCreated":"1786500000000","mine":false}],"nextCursor":"99","hasMore":true}}"#
        let client = DynamicFrameClient(responses: [dynamicFrame(.dynamicTimelineResponse, payload)])
        let repository = RemoteDynamicRepository(client: client)

        let page = try await repository.timeline(scope: .following, beforeId: 120, limit: 20)

        XCTAssertEqual(page.posts.map(\.id), [101])
        XCTAssertEqual(page.posts.first?.author.nickname, "Bob")
        XCTAssertEqual(page.posts.first?.media.first?.fileId, 22)
        XCTAssertEqual(page.posts.first?.likeCount, 4)
        XCTAssertTrue(page.posts.first?.liked == true)
        XCTAssertEqual(page.nextBeforeId, 99)
        XCTAssertTrue(page.hasMore)
        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(sent.type, .dynamicTimelineRequest)
        XCTAssertEqual(object["scope"] as? String, "FOLLOWING")
        XCTAssertEqual(object["beforeId"] as? Int, 120)
        XCTAssertEqual(object["limit"] as? Int, 20)
    }

    // [修改] 互动共用 0x64/0x65；回复正文原样发送并返回服务端权威计数。
    func testActionEncodesReplyAndDecodesCanonicalState() async throws {
        let payload = #"{"success":true,"data":{"dynamicId":101,"action":"REPLY","likeCount":5,"replyCount":3,"repostCount":2,"liked":true,"reposted":false}}"#
        let client = DynamicFrameClient(responses: [dynamicFrame(.dynamicActionResponse, payload)])
        let repository = RemoteDynamicRepository(client: client)

        let result = try await repository.action(dynamicId: 101, action: .reply(content: "收到"))

        XCTAssertEqual(result.dynamicId, 101)
        XCTAssertEqual(result.replyCount, 3)
        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(sent.type, .dynamicActionRequest)
        XCTAssertEqual(object["action"] as? String, "REPLY")
        XCTAssertEqual(object["content"] as? String, "收到")
    }

    // [修改] 详情必须发送回复游标和页大小，并解码服务端下一页元数据。
    func testDetailEncodesReplyCursorAndDecodesPageMetadata() async throws {
        let payload = #"{"success":true,"data":{"post":{"id":101,"author":{"id":9,"username":"bob"},"content":"root","createdAt":100},"replies":[{"id":201,"author":{"userId":7,"userName":"alice"},"content":"reply","createdAt":101}],"nextBeforeReplyId":"200","hasMore":true}}"#
        let client = DynamicFrameClient(responses: [dynamicFrame(.dynamicDetailResponse, payload)])
        let repository = RemoteDynamicRepository(client: client)

        let detail = try await repository.detail(dynamicId: 101, beforeReplyId: 220, limit: 20)

        XCTAssertEqual(detail.post.id, 101)
        XCTAssertEqual(detail.replies.map(\.id), [201])
        XCTAssertEqual(detail.nextBeforeReplyId, 200)
        XCTAssertTrue(detail.hasMore)
        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(sent.type, .dynamicDetailRequest)
        XCTAssertEqual(object["dynamicId"] as? Int, 101)
        XCTAssertEqual(object["beforeReplyId"] as? Int, 220)
        XCTAssertEqual(object["limit"] as? Int, 20)
    }

    // [修改] 兼容旧服务端详情响应：缺少分页字段时按单页结束处理。
    func testDetailWithoutPageMetadataDefaultsToNoMoreReplies() async throws {
        let payload = #"{"success":true,"data":{"post":{"id":101,"author":{"id":9,"username":"bob"},"content":"root","createdAt":100},"replies":[{"id":201,"author":{"userId":7,"userName":"alice"},"content":"reply","createdAt":101}]}}"#
        let client = DynamicFrameClient(responses: [dynamicFrame(.dynamicDetailResponse, payload)])
        let repository = RemoteDynamicRepository(client: client)

        let detail = try await repository.detail(dynamicId: 101, beforeReplyId: nil, limit: 20)

        XCTAssertEqual(detail.post.id, 101)
        XCTAssertEqual(detail.replies.map(\.id), [201])
        XCTAssertNil(detail.nextBeforeReplyId)
        XCTAssertFalse(detail.hasMore)
    }

    // [修改] 删除使用独立帧，并兼容 success 缺失但 code=200 的 envelope。
    func testDeleteAcceptsCodeOnlySuccessEnvelope() async throws {
        let client = DynamicFrameClient(responses: [dynamicFrame(.dynamicDeleteResponse, #"{"code":200,"msg":"deleted","data":null}"#)])
        let repository = RemoteDynamicRepository(client: client)

        try await repository.delete(dynamicId: 101)

        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        XCTAssertEqual(sent.type, .dynamicDeleteRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["dynamicId"] as? Int, 101)
    }

    // [修改] message/msg/errorCode 都必须保留为业务错误，ViewModel 才能展示真实失败原因。
    func testServerFailureKeepsMessageAndErrorCode() async {
        let repository = RemoteDynamicRepository(client: DynamicFrameClient(responses: [
            dynamicFrame(.dynamicActionResponse, #"{"success":false,"code":403,"msg":"没有权限","errorCode":"FORBIDDEN"}"#),
        ]))

        do {
            _ = try await repository.action(dynamicId: 101, action: .like)
            XCTFail("Expected server failure")
        } catch let error as DynamicRepositoryError {
            XCTAssertEqual(error, .server(message: "没有权限", code: "FORBIDDEN"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor DynamicFrameClient: FrameRequesting {
    private var responses: [Frame]
    private(set) var sentFrames: [Frame] = []

    init(responses: [Frame]) { self.responses = responses }

    func connect() async throws {}

    func request(_ frame: Frame, expecting: Set<FrameType>, timeout: Duration) async throws -> Frame {
        sentFrames.append(frame)
        guard let response = responses.first else { throw RequestResponseError.closed }
        responses.removeFirst()
        XCTAssertTrue(expecting.contains(response.type))
        return response
    }
}

private func dynamicFrame(_ type: FrameType, _ json: String) -> Frame {
    Frame(type: type, payload: Data(json.utf8))
}
