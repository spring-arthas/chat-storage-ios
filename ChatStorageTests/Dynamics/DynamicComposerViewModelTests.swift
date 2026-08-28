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

    // [修改] 动态支持图片和视频混选，照片+视频总数最多 9 个。
    func testMediaSelectionAllowsMixedMediaUpToNineItems() {
        let model = DynamicComposerViewModel(repository: ComposerDynamicRepository())
        let media = (1...10).map { index in
            URL(fileURLWithPath: index.isMultiple(of: 2) ? "/tmp/p\(index).jpg" : "/tmp/v\(index).mov")
        }

        model.selectMedia(Array(media.prefix(9)))
        XCTAssertEqual(model.mediaItems.count, 9)
        XCTAssertNil(model.errorMessage)

        model.selectMedia([media[9]])
        XCTAssertEqual(model.mediaItems.count, 9)
        XCTAssertEqual(model.errorMessage, "照片和视频最多选择9个")
    }

    // [修改] 上传未完成时只允许展示缩略图，不允许打开预览；进度和状态文案由媒体项统一计算。
    func testComposerMediaPresentationStateFollowsUploadState() {
        let media = DynamicMedia(
            kind: .image,
            fileId: 1,
            fileName: "照片.jpg",
            fileSize: 10,
            mimeType: "image/jpeg"
        )
        let preparing = DynamicComposerMediaItem(
            localURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            kind: .image,
            state: .preparing,
            progress: 1.4
        )
        let uploading = DynamicComposerMediaItem(
            localURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            kind: .image,
            state: .uploading,
            progress: 0.35
        )
        let succeeded = DynamicComposerMediaItem(
            localURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            kind: .image,
            state: .succeeded,
            progress: 1,
            uploadedMedia: media
        )
        let failed = DynamicComposerMediaItem(
            localURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            kind: .image,
            state: .failed,
            progress: -0.2
        )

        XCTAssertFalse(preparing.canPreview)
        XCTAssertTrue(preparing.shouldDimPreview)
        XCTAssertEqual(preparing.normalizedProgress, 1)
        XCTAssertEqual(preparing.uploadStatusTitle, "准备发送")

        XCTAssertFalse(uploading.canPreview)
        XCTAssertTrue(uploading.shouldDimPreview)
        XCTAssertEqual(uploading.normalizedProgress, 0.35, accuracy: 0.001)
        XCTAssertEqual(uploading.uploadStatusTitle, "正在上传")

        XCTAssertTrue(succeeded.canPreview)
        XCTAssertFalse(succeeded.shouldDimPreview)
        XCTAssertEqual(succeeded.uploadStatusTitle, "上传完成")

        XCTAssertFalse(failed.canPreview)
        XCTAssertTrue(failed.shouldDimPreview)
        XCTAssertEqual(failed.normalizedProgress, 0)
        XCTAssertEqual(failed.uploadStatusTitle, "上传失败")
    }

    // [修改] 发布页准备中不能额外出现系统转圈；上传进度只能绘制在底部状态栏内部。
    func testComposerStatusPresentationKeepsProgressInsideBottomBar() {
        let preparing = DynamicComposerMediaItem(
            localURL: URL(fileURLWithPath: "/tmp/preparing.mov"),
            kind: .video,
            state: .preparing
        )
        let uploading = DynamicComposerMediaItem(
            localURL: URL(fileURLWithPath: "/tmp/uploading.mov"),
            kind: .video,
            state: .uploading,
            progress: 0.35
        )
        let succeeded = DynamicComposerMediaItem(
            localURL: URL(fileURLWithPath: "/tmp/succeeded.mov"),
            kind: .video,
            state: .succeeded
        )

        let preparingPresentation = DynamicComposerMediaStatusPresentation(item: preparing)
        XCTAssertFalse(preparingPresentation.showsProgressTrack)
        XCTAssertFalse(preparingPresentation.showsActivityIndicator)

        let uploadingPresentation = DynamicComposerMediaStatusPresentation(item: uploading)
        XCTAssertTrue(uploadingPresentation.showsProgressTrack)
        XCTAssertEqual(uploadingPresentation.progress, 0.35, accuracy: 0.001)
        XCTAssertFalse(uploadingPresentation.showsActivityIndicator)

        let succeededPresentation = DynamicComposerMediaStatusPresentation(item: succeeded)
        XCTAssertFalse(succeededPresentation.showsProgressTrack)
        XCTAssertFalse(succeededPresentation.showsActivityIndicator)
    }

    // [修改] 图片还在导出时必须保留 Photos 标识，发布页才能立刻取原图缩略图。
    func testComposerImageRetainsPhotoLibraryIdentifierForImmediateThumbnail() {
        let item = DynamicComposerMediaItem(
            localURL: URL(string: "photos-library://asset-local-identifier")!,
            kind: .image,
            photoLibraryAssetIdentifier: "asset-local-identifier"
        )

        XCTAssertEqual(item.photoLibraryAssetIdentifier, "asset-local-identifier")
        XCTAssertFalse(item.localURL.isFileURL)
    }

    // [修改] PhotosPicker 没有 asset 标识时，视频必须回退到文件传输，不能直接被统计为任务创建失败。
    func testVideoWithoutPhotoAssetIdentifierUsesTransferredFileFallback() {
        XCTAssertEqual(
            DynamicComposerVideoSelectionRoute.route(for: nil),
            .transferredFile
        )
        XCTAssertEqual(
            DynamicComposerVideoSelectionRoute.failureMessage(failedCount: 2),
            "2 个视频读取失败，其他视频已保留"
        )
    }

    // [修改] 发布器允许删除单个媒体，且删除后清除上一次选择产生的错误提示。
    func testRemoveMediaDeletesOnlySelectedItemAndClearsError() throws {
        let model = DynamicComposerViewModel(repository: ComposerDynamicRepository())
        let photos = (1...10).map { URL(fileURLWithPath: "/tmp/p\($0).jpg") }
        model.selectMedia(Array(photos.prefix(9)))
        let removedID = try XCTUnwrap(model.mediaItems.dropFirst().first?.id)

        model.selectMedia([photos[9]])
        XCTAssertEqual(model.errorMessage, "照片和视频最多选择9个")

        model.removeMedia(itemID: removedID)

        XCTAssertEqual(model.mediaItems.count, 8)
        XCTAssertEqual(model.mediaItems.first?.localURL.lastPathComponent, "p1.jpg")
        XCTAssertNil(model.errorMessage)
    }

    // [修改] 草稿必须把正文、媒体顺序和上传状态落盘，重新打开发布页可以恢复未完成动态。
    func testDraftStoreRoundTripRestoresUnfinishedDynamic() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-draft-\(UUID().uuidString).json")
        let store = DynamicComposerDraftStore(fileURL: fileURL)
        let item = DynamicComposerMediaItem(
            localURL: URL(fileURLWithPath: "/tmp/restored.jpg"),
            kind: .image,
            state: .failed
        )
        let draft = DynamicComposerPersistedDraft(
            id: UUID(),
            text: "未完成动态",
            reference: nil,
            mediaItems: [item]
        )

        await store.save(draft)
        let restored = await store.load()

        XCTAssertEqual(restored, draft)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // [修改] 重新打开发布页会恢复草稿，并自动接续失败媒体的上传。
    func testRestoredDraftAutomaticallyResumesUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("resume.jpg")
        try Data("media".utf8).write(to: sourceURL)
        let fileURL = root.appendingPathComponent("draft.json")
        let store = DynamicComposerDraftStore(fileURL: fileURL)
        let draft = DynamicComposerPersistedDraft(
            id: UUID(),
            text: "恢复上传",
            reference: nil,
            mediaItems: [DynamicComposerMediaItem(localURL: sourceURL, kind: .image, state: .failed)]
        )
        await store.save(draft)

        let model = DynamicComposerViewModel(
            repository: ComposerDynamicRepository(),
            attachmentUploader: RecoveringComposerAttachmentUploader(failingFirstAttemptNames: []),
            draftStore: store
        )
        await model.restorePersistedDraft()
        await model.waitForPendingUploads()

        XCTAssertEqual(model.text, "恢复上传")
        XCTAssertEqual(model.mediaItems.map(\.state), [.succeeded])
        XCTAssertEqual(model.mediaItems.first?.localURL, sourceURL)
        try? FileManager.default.removeItem(at: root)
    }

    // [修改] 相册视频创建持久任务后，动态卡片跟随传输中心快照显示实时百分比。
    func testPhotoLibraryVideoShowsTransferProgress() async throws {
        let uploader = DynamicVideoComposerUploader()
        let model = DynamicComposerViewModel(
            repository: ComposerDynamicRepository(),
            attachmentUploader: uploader
        )

        let accepted = await model.selectPhotoLibraryVideo(
            fileName: "视频.mov",
            assetIdentifier: "asset-1"
        )
        XCTAssertTrue(accepted)
        let began = await uploader.waitForBegin()
        XCTAssertEqual(began?.taskId, "task-1")
        XCTAssertEqual(model.mediaItems.count, 1)
        XCTAssertEqual(model.mediaItems.first?.state, .preparing)
        XCTAssertEqual(model.mediaItems.first?.transferTaskID, "task-1")

        await uploader.yield(makeTransferRecord(status: .running, transferredBytes: 35, fileSize: 100))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.mediaItems.first?.state, .uploading)
        XCTAssertEqual(try XCTUnwrap(model.mediaItems.first?.progress), 0.35, accuracy: 0.001)
    }

    // [修改] 本地附件尚未读取完成时，动态项必须先绑定传输中心的 preparing 任务。
    func testLocalMediaCreatesTransferTaskBeforeSourceFileIsRead() async throws {
        let uploader = DynamicPreparedAttachmentUploader()
        let model = DynamicComposerViewModel(
            repository: ComposerDynamicRepository(),
            attachmentUploader: uploader
        )

        let preparedItemID = await model.prepareLocalMedia(fileName: "照片.jpg", kind: .image)
        let itemID = try XCTUnwrap(preparedItemID)
        let preparation = await uploader.waitForBegin()

        XCTAssertEqual(preparation?.taskId, "task-local-1")
        XCTAssertEqual(model.mediaItems.first?.id, itemID)
        XCTAssertEqual(model.mediaItems.first?.state, .preparing)
        XCTAssertEqual(model.mediaItems.first?.transferTaskID, "task-local-1")
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

    // [修改] 9个附件全部上传成功后，发布请求必须完整携带9个媒体，不能回退到旧的4个附件限制。
    func testPublishesAllNineUploadedMediaItems() async throws {
        let uploader = ComposerAttachmentUploader()
        let repository = ComposerDynamicRepository(createResults: [.success(DynamicCreateResult(dynamicId: 10, post: nil))])
        let model = DynamicComposerViewModel(repository: repository, attachmentUploader: uploader)
        let urls = (1...9).map { URL(fileURLWithPath: "/tmp/media\($0).jpg") }
        model.selectMedia(urls)

        await model.publish()

        let createRequests = await repository.createRequests
        let request = try XCTUnwrap(createRequests.first)
        XCTAssertEqual(request.media.count, 9)
        XCTAssertEqual(request.imagePaths?.split(separator: ",").count, 9)
        XCTAssertEqual(model.publishedDynamicID, 10)
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

private final class DynamicPreparedAttachmentUploader: ChatAttachmentUploading, DynamicPhotoLibraryUploading, @unchecked Sendable {
    private let stream: AsyncStream<[TransferTaskRecord]>
    private let continuation: AsyncStream<[TransferTaskRecord]>.Continuation
    private var beganPreparation: PhotoLibraryUploadPreparation?
    private var beginContinuation: CheckedContinuation<PhotoLibraryUploadPreparation?, Never>?

    var transferTaskStream: AsyncStream<[TransferTaskRecord]> { stream }

    init() {
        var continuation: AsyncStream<[TransferTaskRecord]>.Continuation?
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation!
    }

    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        ChatAttachment(kind: "image", fileId: 1, fileName: sourceURL.lastPathComponent, fileSize: 10, mimeType: "image/jpeg")
    }

    func transferTask(id: String) async -> TransferTaskRecord? { nil }

    func beginDynamicFileUpload(
        fileName: String,
        batchId: String
    ) async throws -> PhotoLibraryUploadPreparation {
        let preparation = PhotoLibraryUploadPreparation(taskId: "task-local-1")
        beganPreparation = preparation
        beginContinuation?.resume(returning: preparation)
        beginContinuation = nil
        return preparation
    }

    func finishDynamicFileUpload(
        _ preparation: PhotoLibraryUploadPreparation,
        sourceURL: URL
    ) async throws {}

    func failDynamicFileUpload(
        _ preparation: PhotoLibraryUploadPreparation,
        message: String
    ) async {}

    func beginDynamicVideoUpload(
        fileName: String,
        photoLibraryAssetIdentifier: String,
        batchId: String
    ) async throws -> PhotoLibraryUploadPreparation {
        PhotoLibraryUploadPreparation(taskId: "task-video-1")
    }

    func startDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation) async throws {}
    func retryDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation) async {}
    func failDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation, message: String) async {}

    func waitForBegin() async -> PhotoLibraryUploadPreparation? {
        if let beganPreparation { return beganPreparation }
        return await withCheckedContinuation { continuation in
            beginContinuation = continuation
        }
    }

    func yield(_ record: TransferTaskRecord) {
        continuation.yield([record])
    }
}

private final class DynamicVideoComposerUploader: ChatAttachmentUploading, DynamicPhotoLibraryUploading, @unchecked Sendable {
    private let stream: AsyncStream<[TransferTaskRecord]>
    private let continuation: AsyncStream<[TransferTaskRecord]>.Continuation
    private var beganPreparation: PhotoLibraryUploadPreparation?
    private var beginContinuation: CheckedContinuation<PhotoLibraryUploadPreparation?, Never>?

    var transferTaskStream: AsyncStream<[TransferTaskRecord]> { stream }

    func transferTask(id: String) async -> TransferTaskRecord? { nil }

    init() {
        var continuation: AsyncStream<[TransferTaskRecord]>.Continuation?
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation!
    }

    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        ChatAttachment(kind: "video", fileId: 1, fileName: sourceURL.lastPathComponent, fileSize: 100, mimeType: "video/quicktime")
    }

    func beginDynamicVideoUpload(
        fileName: String,
        photoLibraryAssetIdentifier: String,
        batchId: String
    ) async throws -> PhotoLibraryUploadPreparation {
        let preparation = PhotoLibraryUploadPreparation(taskId: "task-1")
        beganPreparation = preparation
        beginContinuation?.resume(returning: preparation)
        beginContinuation = nil
        return preparation
    }

    func beginDynamicFileUpload(
        fileName: String,
        batchId: String
    ) async throws -> PhotoLibraryUploadPreparation {
        PhotoLibraryUploadPreparation(taskId: "task-local-1")
    }

    func finishDynamicFileUpload(
        _ preparation: PhotoLibraryUploadPreparation,
        sourceURL: URL
    ) async throws {}

    func failDynamicFileUpload(
        _ preparation: PhotoLibraryUploadPreparation,
        message: String
    ) async {}

    func startDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation) async throws {}
    func retryDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation) async {}
    func failDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation, message: String) async {}

    func waitForBegin() async -> PhotoLibraryUploadPreparation? {
        if let beganPreparation { return beganPreparation }
        return await withCheckedContinuation { continuation in
            beginContinuation = continuation
        }
    }

    func yield(_ record: TransferTaskRecord) {
        continuation.yield([record])
    }
}

private func makeTransferRecord(
    status: TransferStatus,
    transferredBytes: Int64,
    fileSize: Int64
) -> TransferTaskRecord {
    TransferTaskRecord(
        id: "task-1",
        direction: .upload,
        status: status,
        sourcePath: nil,
        photoLibraryAssetIdentifier: "asset-1",
        destinationPath: nil,
        fileName: "视频.mov",
        fileType: "mov",
        fileSize: fileSize,
        remoteFileId: status == .completed ? 99 : nil,
        targetDirectoryId: 1,
        uploadPurpose: "CHAT_ATTACHMENT",
        batchId: "dynamic-media-test",
        userId: 1,
        username: "tester",
        md5: nil,
        transferredBytes: transferredBytes,
        errorMessage: nil,
        createdAt: 1,
        updatedAt: 2
    )
}
