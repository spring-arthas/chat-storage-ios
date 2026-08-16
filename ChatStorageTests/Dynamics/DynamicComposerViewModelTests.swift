import XCTest
@testable import ChatStorage

@MainActor
final class DynamicComposerViewModelTests: XCTestCase {
    // [修改] 正文按 Swift 字符计数限制 500，纯空草稿不可发布。
    func testTextLimitAndEmptyDraftValidation() async {
        let repository = ComposerDynamicRepository()
        let model = DynamicComposerViewModel(repository: repository)

        model.updateText(String(repeating: "你", count: 501))
        XCTAssertEqual(model.text.count, 500)
        model.updateText("   ")
        await model.publish()

        XCTAssertEqual(model.errorMessage, "请输入内容或添加媒体")
        let emptyCreateRequests = await repository.createRequests
        XCTAssertEqual(emptyCreateRequests.count, 0)
    }

    // [修改] 发布器只允许最多 4 张照片或 1 个视频，图片和视频不能混选。
    func testMediaSelectionEnforcesPhotoLimitAndVideoExclusivity() {
        let model = DynamicComposerViewModel(repository: ComposerDynamicRepository())
        let photos = (1...5).map { URL(fileURLWithPath: "/tmp/p\($0).jpg") }

        model.selectMedia(Array(photos.prefix(4)))
        XCTAssertEqual(model.mediaItems.count, 4)
        XCTAssertNil(model.errorMessage)

        model.selectMedia([photos[4]])
        XCTAssertEqual(model.mediaItems.count, 4)
        XCTAssertEqual(model.errorMessage, "照片最多选择4张")

        model.removeAllMedia()
        model.selectMedia([URL(fileURLWithPath: "/tmp/a.mov")])
        model.selectMedia([URL(fileURLWithPath: "/tmp/p.jpg")])
        XCTAssertEqual(model.mediaItems.count, 1)
        XCTAssertEqual(model.errorMessage, "图片和视频不能同时选择")
    }

    // [修改] 发布器允许删除单个媒体，且删除后清除上一次选择产生的错误提示。
    func testRemoveMediaDeletesOnlySelectedItemAndClearsError() throws {
        let model = DynamicComposerViewModel(repository: ComposerDynamicRepository())
        let photos = (1...5).map { URL(fileURLWithPath: "/tmp/p\($0).jpg") }
        model.selectMedia(Array(photos.prefix(4)))
        let removedID = try XCTUnwrap(model.mediaItems.dropFirst().first?.id)

        model.selectMedia([photos[4]])
        XCTAssertEqual(model.errorMessage, "照片最多选择4张")

        model.removeMedia(itemID: removedID)

        XCTAssertEqual(model.mediaItems.map(\.localURL.lastPathComponent), ["p1.jpg", "p3.jpg", "p4.jpg"])
        XCTAssertNil(model.errorMessage)
    }

    // [修改] 每个媒体独立经历 preparing/uploading/succeeded，成功后按一条动态发布。
    func testUploadsEachMediaAndPublishesWithSucceededStates() async throws {
        let uploader = ComposerAttachmentUploader()
        let repository = ComposerDynamicRepository(createResults: [.success(DynamicCreateResult(dynamicId: 9, post: nil))])
        let model = DynamicComposerViewModel(repository: repository, attachmentUploader: uploader)
        model.updateText("周末")
        model.selectMedia([
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
        ])

        await model.publish()

        XCTAssertEqual(model.mediaItems.map(\.state), [.succeeded, .succeeded])
        let uploadedNames = await uploader.uploadedNames
        XCTAssertEqual(uploadedNames, ["a.jpg", "b.jpg"])
        let createRequests = await repository.createRequests
        let request = try XCTUnwrap(createRequests.first)
        XCTAssertEqual(request.media.map(\.fileName), ["a.jpg", "b.jpg"])
        XCTAssertEqual(model.publishedDynamicID, 9)
    }

    // [修改] 单项上传失败保留失败状态和本地 URL，点击重试只重传失败项。
    func testFailedUploadCanRetryIndependently() async {
        let uploader = RecoveringComposerAttachmentUploader(failingFirstAttemptNames: ["b.jpg"])
        let repository = ComposerDynamicRepository(createResults: [.success(DynamicCreateResult(dynamicId: 9, post: nil))])
        let model = DynamicComposerViewModel(repository: repository, attachmentUploader: uploader)
        model.updateText("附件")
        model.selectMedia([
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
        ])

        await model.publish()
        XCTAssertEqual(model.mediaItems.map(\.state), [.succeeded, .failed])
        XCTAssertEqual(model.errorMessage, "b.jpg 上传失败")

        let failedID = try! XCTUnwrap(model.mediaItems.last?.id)
        await model.retryUpload(itemID: failedID)
        await model.publish()

        XCTAssertEqual(model.mediaItems.map(\.state), [.succeeded, .succeeded])
        XCTAssertEqual(model.publishedDynamicID, 9)
    }

    // [修改] 发布失败不重复上传，retryPublish 复用已上传结果并保留服务端真实错误。
    func testPublishFailureCanRetryWithoutUploadingAgain() async {
        let uploader = ComposerAttachmentUploader()
        let repository = ComposerDynamicRepository(createResults: [
            .failure(DynamicRepositoryError.server(message: "网络拥堵", code: "BUSY")),
            .success(DynamicCreateResult(dynamicId: 10, post: nil)),
        ])
        let model = DynamicComposerViewModel(repository: repository, attachmentUploader: uploader)
        model.selectMedia([URL(fileURLWithPath: "/tmp/a.jpg")])

        await model.publish()
        XCTAssertEqual(model.errorMessage, "网络拥堵")
        await model.retryPublish()

        let uploadedNames = await uploader.uploadedNames
        let createRequests = await repository.createRequests
        XCTAssertEqual(uploadedNames, ["a.jpg"])
        XCTAssertEqual(createRequests.count, 2)
        XCTAssertEqual(model.publishedDynamicID, 10)
    }

    // [修改] 聊天/网盘引用草稿只消费一次，Composer 消费后路由立即清空。
    func testRouteDraftIsConsumedOnce() {
        let reference = DynamicReference(sourceType: .chatMessage, sourceId: "88", title: "Alice", subtitle: "晚点见", media: [])
        let store = DynamicComposerRouteStore()
        store.present(DynamicComposerDraft(text: "补充", reference: reference))

        let model = DynamicComposerViewModel(repository: ComposerDynamicRepository())
        model.consumeDraft(from: store)

        XCTAssertEqual(model.text, "补充")
        XCTAssertEqual(model.reference, reference)
        XCTAssertNil(store.consume())
    }
}

private actor ComposerDynamicRepository: DynamicRepository {
    private var createResults: [Result<DynamicCreateResult, Error>]
    private(set) var createRequests: [DynamicCreateRequest] = []

    init(createResults: [Result<DynamicCreateResult, Error>] = []) { self.createResults = createResults }

    func create(_ request: DynamicCreateRequest) async throws -> DynamicCreateResult {
        createRequests.append(request)
        return try createResults.removeFirst().get()
    }

    func timeline(scope: DynamicTimelineScope, beforeId: Int64?, limit: Int) async throws -> DynamicTimelinePage { fatalError() }
    func action(dynamicId: Int64, action: DynamicAction) async throws -> DynamicActionResult { fatalError() }
    func detail(dynamicId: Int64, beforeReplyId: Int64?, limit: Int) async throws -> DynamicPostDetail { fatalError() }
    func delete(dynamicId: Int64) async throws { fatalError() }
}

private actor ComposerAttachmentUploader: ChatAttachmentUploading {
    private(set) var uploadedNames: [String] = []

    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        uploadedNames.append(sourceURL.lastPathComponent)
        return ChatAttachment(kind: "image", fileId: Int64(uploadedNames.count), fileName: sourceURL.lastPathComponent, fileSize: 10, mimeType: "image/jpeg")
    }
}

private actor RecoveringComposerAttachmentUploader: ChatAttachmentUploading {
    private let failingFirstAttemptNames: Set<String>
    private var attempts: [String: Int] = [:]

    init(failingFirstAttemptNames: Set<String>) { self.failingFirstAttemptNames = failingFirstAttemptNames }

    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        let name = sourceURL.lastPathComponent
        attempts[name, default: 0] += 1
        if failingFirstAttemptNames.contains(name), attempts[name] == 1 {
            throw DynamicRepositoryError.server(message: "\(name) 上传失败", code: nil)
        }
        return ChatAttachment(kind: "image", fileId: Int64(attempts.values.reduce(0, +)), fileName: name, fileSize: 10, mimeType: "image/jpeg")
    }
}
