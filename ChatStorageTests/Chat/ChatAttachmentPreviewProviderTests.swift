import XCTest
@testable import ChatStorage

final class ChatAttachmentPreviewProviderTests: XCTestCase {
    // [修改] 聊天视频预览必须保留完整播放凭据和续签入口，不能只保存一条会过期的 URL。
    @MainActor
    func testVideoPreviewRetainsPlaybackMetadataAndRefreshProvider() async throws {
        let downloadManager = AttachmentDownloadManager()
        let mediaRepository = AttachmentMediaRepository(url: URL(string: "https://server/media/stream/88?token=first")!)
        let provider = DefaultChatAttachmentPreviewProvider(
            downloadManager: downloadManager,
            mediaRepository: mediaRepository,
            username: "alice",
            serverScopeID: "server-a",
            userId: 1,
            cacheRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        let preview = try await provider.preview(
            for: .fixture(fileId: 88, fileName: "clip.mp4", fileSize: 30, mimeType: "video/mp4")
        )
        let playback = try XCTUnwrap(preview.playback)
        let refreshPlayback = try XCTUnwrap(preview.refreshPlayback)
        let refreshed = try await refreshPlayback()
        let requestCount = await mediaRepository.requestCount

        XCTAssertEqual(playback.playURL.absoluteString, "https://server/media/stream/88?token=first")
        XCTAssertEqual(refreshed.fileId, 88)
        XCTAssertEqual(requestCount, 2)
    }

    func testVideoUsesStreamingURLWithoutDownloading() async throws {
        let downloadManager = AttachmentDownloadManager()
        let mediaRepository = AttachmentMediaRepository(url: URL(string: "http://server/media/stream/88")!)
        let provider = DefaultChatAttachmentPreviewProvider(
            downloadManager: downloadManager,
            mediaRepository: mediaRepository,
            username: "alice",
            serverScopeID: "server-a",
            userId: 1,
            cacheRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        let preview = try await provider.preview(for: .fixture(fileId: 88, fileName: "clip.mp4", fileSize: 30, mimeType: "video/mp4"))

        XCTAssertEqual(preview.kind, .video)
        XCTAssertEqual(preview.url.absoluteString, "http://server/media/stream/88")
        let downloadCount = await downloadManager.downloadCount
        XCTAssertEqual(downloadCount, 0)
    }

    func testImageDownloadsToCacheAndReturnsImagePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloadManager = AttachmentDownloadManager()
        let provider = DefaultChatAttachmentPreviewProvider(
            downloadManager: downloadManager,
            mediaRepository: AttachmentMediaRepository(url: URL(string: "http://server/unused")!),
            username: "alice",
            serverScopeID: "server-a",
            userId: 1,
            cacheRootURL: root
        )

        let preview = try await provider.preview(for: .fixture(fileId: 91, fileName: "photo.jpg", fileSize: 12, mimeType: "image/jpeg"))

        XCTAssertEqual(preview.kind, .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.url.path))
        XCTAssertEqual(try Data(contentsOf: preview.url).count, 12)
    }

    func testCompletedCacheIsReusedWithoutSecondDownload() async throws {
        let downloadManager = AttachmentDownloadManager()
        let provider = DefaultChatAttachmentPreviewProvider(
            downloadManager: downloadManager,
            mediaRepository: AttachmentMediaRepository(url: URL(string: "http://server/unused")!),
            username: "alice",
            serverScopeID: "server-a",
            userId: 1,
            cacheRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let attachment = ChatAttachment.fixture(fileId: 92, fileName: "manual.pdf", fileSize: 18, mimeType: "application/pdf")

        _ = try await provider.preview(for: attachment)
        let preview = try await provider.preview(for: attachment)

        XCTAssertEqual(preview.kind, .file)
        let downloadCount = await downloadManager.downloadCount
        XCTAssertEqual(downloadCount, 1)
    }

    // [修改] 相同 fileId 和文件名在换号、切服后都必须使用不同缓存，不能串附件内容。
    func testAttachmentCacheIsIsolatedAcrossAccountsAndServers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloadManager = AttachmentDownloadManager()
        let firstProvider = DefaultChatAttachmentPreviewProvider(
            downloadManager: downloadManager,
            mediaRepository: AttachmentMediaRepository(url: URL(string: "http://server/unused")!),
            username: "alice",
            serverScopeID: "server-a",
            userId: 1,
            cacheRootURL: root
        )
        let secondProvider = DefaultChatAttachmentPreviewProvider(
            downloadManager: downloadManager,
            mediaRepository: AttachmentMediaRepository(url: URL(string: "http://server/unused")!),
            username: "bob",
            serverScopeID: "server-a",
            userId: 2,
            cacheRootURL: root
        )
        let thirdProvider = DefaultChatAttachmentPreviewProvider(
            downloadManager: downloadManager,
            mediaRepository: AttachmentMediaRepository(url: URL(string: "http://server/unused")!),
            username: "alice",
            serverScopeID: "server-b",
            userId: 1,
            cacheRootURL: root
        )
        let attachment = ChatAttachment.fixture(fileId: 92, fileName: "manual.pdf", fileSize: 18, mimeType: "application/pdf")

        let first = try await firstProvider.preview(for: attachment)
        let second = try await secondProvider.preview(for: attachment)
        let third = try await thirdProvider.preview(for: attachment)

        XCTAssertNotEqual(first.url, second.url)
        XCTAssertNotEqual(first.url, third.url)
        let downloadCount = await downloadManager.downloadCount
        XCTAssertEqual(downloadCount, 3)
    }

    // [修改] 同一附件同时被两个界面请求时只下载一次，避免争用同一个目标和 part 文件。
    func testConcurrentAttachmentPreviewsShareOneDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloadManager = CoordinatedAttachmentDownloadManager()
        let provider = DefaultChatAttachmentPreviewProvider(
            downloadManager: downloadManager,
            mediaRepository: AttachmentMediaRepository(url: URL(string: "http://server/unused")!),
            username: "alice",
            serverScopeID: "server-a",
            userId: 1,
            cacheRootURL: root
        )
        let attachment = ChatAttachment.fixture(fileId: 93, fileName: "manual.pdf", fileSize: 18, mimeType: "application/pdf")
        let first = Task { try await provider.preview(for: attachment) }
        await downloadManager.waitUntilStarted()
        let second = Task { try await provider.preview(for: attachment) }

        try await Task.sleep(for: .milliseconds(100))
        let downloadCount = await downloadManager.downloadCount
        XCTAssertEqual(downloadCount, 1)

        await downloadManager.finishAll()
        let previews = try await [first.value, second.value]
        XCTAssertEqual(previews[0].url, previews[1].url)
    }
}

private actor AttachmentDownloadManager: FileDownloadManaging {
    private(set) var downloadCount = 0

    func download(remoteFileId: Int64, fileName: String, fileSize: Int64, destinationURL: URL) async throws -> DownloadResult {
        downloadCount += 1
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: Int(fileSize)).write(to: destinationURL)
        return DownloadResult(downloadedBytes: fileSize, destinationURL: destinationURL)
    }
}

private actor CoordinatedAttachmentDownloadManager: FileDownloadManaging {
    private(set) var downloadCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false

    func download(remoteFileId: Int64, fileName: String, fileSize: Int64, destinationURL: URL) async throws -> DownloadResult {
        downloadCount += 1
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !isFinished {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: Int(fileSize)).write(to: destinationURL)
        return DownloadResult(downloadedBytes: fileSize, destinationURL: destinationURL)
    }

    func waitUntilStarted() async {
        guard downloadCount == 0 else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func finishAll() {
        isFinished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AttachmentMediaRepository: MediaPlaybackProviding {
    let url: URL
    private(set) var requestCount = 0
    init(url: URL) { self.url = url }

    func playback(fileId: Int64, username: String) async throws -> MediaPlayback {
        requestCount += 1
        return MediaPlayback(fileId: fileId, playURL: url, fileSize: 30, mimeType: "video/mp4", expiresInSeconds: 60)
    }
}

private extension ChatAttachment {
    static func fixture(fileId: Int64, fileName: String, fileSize: Int64, mimeType: String) -> ChatAttachment {
        ChatAttachment(
            kind: mimeType.hasPrefix("image/") ? "image" : "file",
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType
        )
    }
}
