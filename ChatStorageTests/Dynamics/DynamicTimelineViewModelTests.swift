import AVFoundation
import UIKit
import XCTest
@testable import ChatStorage

@MainActor
final class DynamicTimelineViewModelTests: XCTestCase {
    // [修改] 动态主页头像栏必须把当前用户置顶，并按作者去重，避免同一作者重复出现。
    func testDynamicTimelineStoryItemsPutCurrentUserFirstAndDeduplicateAuthors() {
        let currentUser = AuthenticatedUser.preview
        let posts = [
            post(1, authorID: 2, nickname: "好友一"),
            post(2, authorID: 2, nickname: "好友一"),
            post(3, authorID: 3, nickname: "好友二")
        ]

        let items = DynamicTimelineStoryBuilder.make(currentUser: currentUser, posts: posts)

        XCTAssertEqual(items.map(\.author.id), [currentUser.id, 2, 3])
        XCTAssertTrue(items.first?.isCurrentUser == true)
        XCTAssertEqual(items.dropFirst().map(\.latestPostID), [1, 3])
    }

    // [修改] 动态卡片必须能识别带 data 前缀的头像，并为图片预览生成可显示的图像数据。
    func testDynamicMediaPresentationSupportsAvatarDataURLAndImageThumbnail() async throws {
        let source = try XCTUnwrap(UIImage(systemName: "person.crop.circle")?.pngData())
        let avatar = "data:image/png;base64,\(source.base64EncodedString())"
        XCTAssertNotNil(DynamicAvatarView.image(from: avatar))

        let preview = ChatAttachmentPreview(
            attachment: ChatAttachment(
                kind: "image",
                fileId: 11,
                fileName: "照片.png",
                fileSize: Int64(source.count),
                mimeType: "image/png"
            ),
            kind: .image,
            url: try temporaryMediaURL(data: source)
        )
        let thumbnail = try await DynamicMediaThumbnailRenderer.thumbnailData(for: preview)
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(thumbnail)))
    }

    // [修改] 动态视频预览必须复用按 presentationSize 自适应的网盘播放表面，禁止重新写死16:9。
    func testDynamicVideoPreviewUsesPresentationSizeSurface() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ChatStorage/Features/Dynamics/DynamicTimelineView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("DrivePreviewVideoSurface("))
        XCTAssertFalse(source.contains(".aspectRatio(fullscreen ? nil : 16 / 9"))
    }

    // [修改] 动态列表最多展示发布请求中的全部9个媒体，不再因为旧的四宫格上限丢失媒体。
    func testDynamicMediaGridKeepsAllNineMediaItems() {
        let media = (1...9).map { index in
            DynamicMedia(
                kind: index.isMultiple(of: 2) ? .video : .image,
                fileId: Int64(index),
                fileName: "media-(index)",
                fileSize: 10,
                mimeType: index.isMultiple(of: 2) ? "video/mp4" : "image/jpeg"
            )
        }

        XCTAssertEqual(DynamicMediaGridLayout.visibleMedia(from: media).map(\.fileId), media.map(\.fileId))
        XCTAssertEqual(
            DynamicMediaGridLayout.height(for: media.count, width: 343, spacing: 4),
            343,
            accuracy: 0.001
        )
    }

    // [修改] 5～9项媒体高度必须按实际卡片宽度计算，避免不同 iPhone 宽度下第二行或第三行被裁掉。
    func testDynamicMediaGridFitsAllRowsAcrossPhoneWidths() {
        XCTAssertEqual(DynamicMediaGridLayout.rows(for: 5), 2)
        XCTAssertEqual(DynamicMediaGridLayout.rows(for: 9), 3)
        XCTAssertEqual(
            DynamicMediaGridLayout.height(for: 5, width: 343, spacing: 3),
            227.666,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DynamicMediaGridLayout.height(for: 9, width: 430, spacing: 3),
            430,
            accuracy: 0.001
        )
    }

    // [修改] 5～9项必须按完整行分配媒体，最后一行不能被懒加载网格测量吞掉。
    func testDynamicMediaGridDistributesItemsIntoCompleteRows() {
        XCTAssertEqual(DynamicMediaGridLayout.rowItemCounts(for: 5), [3, 2])
        XCTAssertEqual(DynamicMediaGridLayout.rowItemCounts(for: 7), [3, 3, 1])
        XCTAssertEqual(DynamicMediaGridLayout.rowItemCounts(for: 9), [3, 3, 3])
    }

    // [修改] 多媒体动态的高度必须由实际卡片宽度推导，2/3项保持整体方形，4项为2×2，9项为3×3。
    func testDynamicMediaGridUsesResponsiveMosaicMetrics() {
        let width: CGFloat = 343
        let spacing: CGFloat = 4

        XCTAssertEqual(
            DynamicMediaGridLayout.height(for: 2, width: width, spacing: spacing),
            169.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DynamicMediaGridLayout.height(for: 3, width: width, spacing: spacing),
            169.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DynamicMediaGridLayout.height(for: 4, width: width, spacing: spacing),
            343,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DynamicMediaGridLayout.height(for: 9, width: width, spacing: spacing),
            343,
            accuracy: 0.001
        )
    }

    // [修改] 打开动态媒体时保留原始顺序，并从点击的媒体开始连续浏览。
    func testDynamicMediaGalleryStartsAtTappedMediaAndKeepsOrder() {
        let media = (1...3).map { index in
            DynamicMedia(kind: .image, fileId: Int64(index), fileName: "image-(index)", fileSize: 10, mimeType: "image/jpeg")
        }

        let state = DynamicMediaGalleryState(media: media, selectedMediaID: 2)

        XCTAssertEqual(state.media.map(\.fileId), [1, 2, 3])
        XCTAssertEqual(state.selectedIndex, 1)
    }

    // [修改] 首屏、刷新和游标分页必须稳定替换/追加并按动态 ID 去重。
    func testInitialRefreshAndPaginationMergeWithoutDuplicates() async {
        let repository = TimelineDynamicRepository(
            timelineResults: [
                .success(DynamicTimelinePage(posts: [post(3), post(2)], nextBeforeId: 2, hasMore: true)),
                .success(DynamicTimelinePage(posts: [post(2), post(1)], nextBeforeId: nil, hasMore: false)),
                .success(DynamicTimelinePage(posts: [post(4), post(3)], nextBeforeId: 3, hasMore: true)),
            ]
        )
        let model = DynamicTimelineViewModel(repository: repository, scope: .following)

        await model.loadInitial()
        await model.loadNextPage()
        XCTAssertEqual(model.posts.map(\.id), [3, 2, 1])

        await model.refresh()
        XCTAssertEqual(model.posts.map(\.id), [4, 3])
        XCTAssertEqual(model.nextBeforeId, 3)
        XCTAssertTrue(model.hasMore)
        let calls = await repository.timelineCalls
        XCTAssertEqual(calls.map(\.beforeId), [nil, 2, nil])
    }

    // [修改] 点赞立即更新 UI；网络失败必须完整回滚并保留真实服务端错误。
    func testLikeOptimisticFailureRollsBackAndKeepsError() async {
        let repository = TimelineDynamicRepository(
            timelineResults: [.success(DynamicTimelinePage(posts: [post(1, likeCount: 2)], nextBeforeId: nil, hasMore: false))],
            actionResults: [.failure(DynamicRepositoryError.server(message: "登录已过期", code: "SESSION_EXPIRED"))]
        )
        let model = DynamicTimelineViewModel(repository: repository, scope: .following)
        await model.loadInitial()

        await model.toggleLike(postID: 1)

        XCTAssertEqual(model.posts.first?.likeCount, 2)
        XCTAssertFalse(model.posts.first?.liked == true)
        XCTAssertEqual(model.errorMessage, "登录已过期")
    }

    // [修改] 服务端成功状态覆盖乐观值，转发/取消转发走相反动作。
    func testRepostOptimisticSuccessUsesCanonicalCounts() async {
        let repository = TimelineDynamicRepository(
            timelineResults: [.success(DynamicTimelinePage(posts: [post(1, repostCount: 3)], nextBeforeId: nil, hasMore: false))],
            actionResults: [.success(DynamicActionResult(dynamicId: 1, action: .repost, likeCount: 0, replyCount: 0, repostCount: 8, liked: false, reposted: true))]
        )
        let model = DynamicTimelineViewModel(repository: repository, scope: .following)
        await model.loadInitial()

        await model.toggleRepost(postID: 1)

        XCTAssertEqual(model.posts.first?.repostCount, 8)
        XCTAssertTrue(model.posts.first?.reposted == true)
        let actions = await repository.actions
        XCTAssertEqual(actions, [.repost])
    }

    // [修改] 只能删除自己的动态；失败时保留列表，成功后移除。
    func testDeleteOnlyMineAndKeepsPostOnFailure() async {
        let repository = TimelineDynamicRepository(
            timelineResults: [.success(DynamicTimelinePage(posts: [post(1, isMine: false), post(2, isMine: true)], nextBeforeId: nil, hasMore: false))],
            deleteResults: [.failure(DynamicRepositoryError.server(message: "删除失败", code: nil)), .success(())]
        )
        let model = DynamicTimelineViewModel(repository: repository, scope: .mine)
        await model.loadInitial()

        await model.delete(postID: 1)
        let initialDeletedIDs = await repository.deletedIDs
        XCTAssertEqual(initialDeletedIDs, [])
        await model.delete(postID: 2)
        XCTAssertEqual(model.posts.map(\.id), [1, 2])
        XCTAssertEqual(model.errorMessage, "删除失败")
        await model.delete(postID: 2)
        XCTAssertEqual(model.posts.map(\.id), [1])
    }
}

private actor TimelineDynamicRepository: DynamicRepository {
    struct TimelineCall: Equatable { let scope: DynamicTimelineScope; let beforeId: Int64?; let limit: Int }
    private var timelineResults: [Result<DynamicTimelinePage, Error>]
    private var actionResults: [Result<DynamicActionResult, Error>]
    private var deleteResults: [Result<Void, Error>]
    private(set) var timelineCalls: [TimelineCall] = []
    private(set) var actions: [DynamicAction] = []
    private(set) var deletedIDs: [Int64] = []

    init(
        timelineResults: [Result<DynamicTimelinePage, Error>],
        actionResults: [Result<DynamicActionResult, Error>] = [],
        deleteResults: [Result<Void, Error>] = []
    ) {
        self.timelineResults = timelineResults
        self.actionResults = actionResults
        self.deleteResults = deleteResults
    }

    func create(_ request: DynamicCreateRequest) async throws -> DynamicCreateResult { fatalError() }

    func timeline(scope: DynamicTimelineScope, beforeId: Int64?, limit: Int) async throws -> DynamicTimelinePage {
        timelineCalls.append(.init(scope: scope, beforeId: beforeId, limit: limit))
        return try timelineResults.removeFirst().get()
    }

    func action(dynamicId: Int64, action: DynamicAction) async throws -> DynamicActionResult {
        actions.append(action)
        return try actionResults.removeFirst().get()
    }

    func detail(dynamicId: Int64, beforeReplyId: Int64?, limit: Int) async throws -> DynamicPostDetail { fatalError() }

    func delete(dynamicId: Int64) async throws {
        deletedIDs.append(dynamicId)
        return try deleteResults.removeFirst().get()
    }
}

private func post(
    _ id: Int64,
    likeCount: Int = 0,
    repostCount: Int = 0,
    isMine: Bool = true,
    authorID: Int64 = 7,
    nickname: String = "Alice"
) -> DynamicPost {
    DynamicPost(
        id: id,
        author: DynamicAuthor(id: authorID, username: "user-\(authorID)", nickname: nickname, avatar: nil),
        content: "post-\(id)",
        media: [],
        reference: nil,
        likeCount: likeCount,
        replyCount: 0,
        repostCount: repostCount,
        liked: false,
        reposted: false,
        originalPost: nil,
        createdAt: id,
        isMine: isMine
    )
}

private func temporaryMediaURL(data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dynamic-media-\(UUID().uuidString).png")
    try data.write(to: url)
    return url
}

@MainActor
final class DynamicDetailViewModelTests: XCTestCase {
    // [修改] 首次加载和刷新都替换回复，并分别从空游标开始请求。
    func testInitialLoadAndRefreshReplaceRepliesAndTrackCursor() async {
        let repository = DetailDynamicRepository(detailResults: [
            .success(DynamicPostDetail(post: post(99), replies: [post(3), post(2)], nextBeforeReplyId: 2, hasMore: true)),
            .success(DynamicPostDetail(post: post(99), replies: [post(4)], nextBeforeReplyId: nil, hasMore: false)),
        ])
        let model = DynamicDetailViewModel(repository: repository, post: post(99))

        await model.loadInitial()
        XCTAssertEqual(model.replies.map(\.id), [3, 2])
        XCTAssertEqual(model.nextBeforeReplyId, 2)
        XCTAssertTrue(model.hasMore)

        await model.refresh()
        XCTAssertEqual(model.replies.map(\.id), [4])
        XCTAssertNil(model.nextBeforeReplyId)
        XCTAssertFalse(model.hasMore)
        let calls = await repository.detailCalls
        XCTAssertEqual(calls.map(\.beforeReplyId), [nil, nil])
    }

    // [修改] 下一页按回复 ID 去重后追加，不能因为服务端重叠边界重复显示。
    func testNextPageAppendsRepliesWithoutDuplicateIDs() async {
        let repository = DetailDynamicRepository(detailResults: [
            .success(DynamicPostDetail(post: post(99), replies: [post(3), post(2)], nextBeforeReplyId: 2, hasMore: true)),
            .success(DynamicPostDetail(post: post(99), replies: [post(2), post(1)], nextBeforeReplyId: nil, hasMore: false)),
        ])
        let model = DynamicDetailViewModel(repository: repository, post: post(99))

        await model.loadInitial()
        await model.loadNextPage()

        XCTAssertEqual(model.replies.map(\.id), [3, 2, 1])
        XCTAssertFalse(model.hasMore)
        let calls = await repository.detailCalls
        XCTAssertEqual(calls.map(\.beforeReplyId), [nil, 2])
    }

    // [修改] 下一页失败时保留旧回复和游标，retry 只重试失败的那一页。
    func testNextPageFailurePreservesRepliesAndRetrySucceeds() async {
        let repository = DetailDynamicRepository(detailResults: [
            .success(DynamicPostDetail(post: post(99), replies: [post(3), post(2)], nextBeforeReplyId: 2, hasMore: true)),
            .failure(DynamicRepositoryError.server(message: "回复加载失败", code: "TIMEOUT")),
            .success(DynamicPostDetail(post: post(99), replies: [post(2), post(1)], nextBeforeReplyId: nil, hasMore: false)),
        ])
        let model = DynamicDetailViewModel(repository: repository, post: post(99))

        await model.loadInitial()
        await model.loadNextPage()
        XCTAssertEqual(model.replies.map(\.id), [3, 2])
        XCTAssertEqual(model.nextBeforeReplyId, 2)
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.errorMessage, "回复加载失败")

        await model.retry()
        XCTAssertEqual(model.replies.map(\.id), [3, 2, 1])
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.errorMessage)
    }

    // [修改] 首屏失败也必须保留可重试状态，重试成功后正常进入第一页。
    func testInitialFailureCanRetryFirstPage() async {
        let repository = DetailDynamicRepository(detailResults: [
            .failure(DynamicRepositoryError.server(message: "详情加载失败", code: "TIMEOUT")),
            .success(DynamicPostDetail(post: post(99), replies: [post(3)], nextBeforeReplyId: nil, hasMore: false)),
        ])
        let model = DynamicDetailViewModel(repository: repository, post: post(99))

        await model.loadInitial()
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.errorMessage, "详情加载失败")
        XCTAssertTrue(model.replies.isEmpty)

        await model.retry()
        XCTAssertFalse(model.canRetry)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.replies.map(\.id), [3])
    }
}

private actor DetailDynamicRepository: DynamicRepository {
    struct DetailCall: Equatable {
        let dynamicId: Int64
        let beforeReplyId: Int64?
        let limit: Int
    }

    private var detailResults: [Result<DynamicPostDetail, Error>]
    private(set) var detailCalls: [DetailCall] = []

    init(detailResults: [Result<DynamicPostDetail, Error>]) {
        self.detailResults = detailResults
    }

    func create(_ request: DynamicCreateRequest) async throws -> DynamicCreateResult { fatalError() }
    func timeline(scope: DynamicTimelineScope, beforeId: Int64?, limit: Int) async throws -> DynamicTimelinePage { fatalError() }
    func action(dynamicId: Int64, action: DynamicAction) async throws -> DynamicActionResult { fatalError() }

    func detail(dynamicId: Int64, beforeReplyId: Int64?, limit: Int) async throws -> DynamicPostDetail {
        detailCalls.append(.init(dynamicId: dynamicId, beforeReplyId: beforeReplyId, limit: limit))
        return try detailResults.removeFirst().get()
    }

    func delete(dynamicId: Int64) async throws { fatalError() }
}
