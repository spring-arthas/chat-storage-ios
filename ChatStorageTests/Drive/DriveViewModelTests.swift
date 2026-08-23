import XCTest
import AVFoundation
import UIKit
@testable import ChatStorage

@MainActor
final class DriveViewModelTests: XCTestCase {
    // [修改] 网盘分享到动态只引用现有远端文件，必须保留 fileId，不能重新上传。
    func testDynamicDraftForDriveFilePreservesRemoteFileIdentityAndMediaKind() throws {
        let image = DriveFileEntry.file(id: 101, parentId: 1, name: "照片.jpg", size: 2_048)
        let video = DriveFileEntry.file(id: 102, parentId: 1, name: "演示.mov", size: 20_000_000)
        let document = DriveFileEntry.file(id: 103, parentId: 1, name: "说明.pdf", size: 4_096)

        let imageDraft = try XCTUnwrap(DriveDynamicDraftBuilder.draft(for: image))
        let videoDraft = try XCTUnwrap(DriveDynamicDraftBuilder.draft(for: video))
        let documentDraft = try XCTUnwrap(DriveDynamicDraftBuilder.draft(for: document))

        XCTAssertEqual(imageDraft.reference?.sourceType, .driveFile)
        XCTAssertEqual(imageDraft.reference?.sourceId, "101")
        XCTAssertEqual(imageDraft.reference?.media.first?.fileId, 101)
        XCTAssertEqual(imageDraft.reference?.media.first?.kind, .image)
        XCTAssertEqual(videoDraft.reference?.media.first?.kind, .video)
        XCTAssertEqual(documentDraft.reference?.media.first?.kind, .file)
        XCTAssertEqual(documentDraft.reference?.subtitle, "4 KB")
    }

    // [修改] 目录没有可发布的远端文件实体，菜单不能生成动态草稿。
    func testDynamicDraftForDirectoryIsUnavailable() {
        let directory = DriveFileEntry.directory(id: 2, parentId: 1, name: "资料")

        XCTAssertNil(DriveDynamicDraftBuilder.draft(for: directory))
    }

    // [修改] 智能集合只筛选当前已加载目录，切换集合不能额外请求服务端。
    func testSmartCollectionsFilterLoadedEntriesWithoutReloading() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recentTimestamp = Int64(now.addingTimeInterval(-2 * 24 * 60 * 60).timeIntervalSince1970 * 1_000)
        let oldTimestamp = Int64(now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970 * 1_000)
        let directory = DriveFileEntry.directory(id: 2, parentId: 1, name: "资料")
        let image = DriveFileEntry.file(id: 101, parentId: 1, name: "照片.jpg", size: 2_048, modifiedAt: recentTimestamp)
        let video = DriveFileEntry.file(id: 102, parentId: 1, name: "演示.mov", size: 20_000_000, modifiedAt: oldTimestamp)
        let large = DriveFileEntry.file(id: 103, parentId: 1, name: "归档.zip", size: 150 * 1_024 * 1_024, modifiedAt: oldTimestamp)
        let repository = DriveRepositorySpy(
            roots: [.root(children: [directory])],
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [image, video, large], currentPage: 1, pageSize: 20, totalCount: 3)]
        )
        let model = DriveViewModel(repository: repository, now: { now })
        await model.load()
        let initialRequests = await repository.listCalls

        model.smartCollection = .recent
        XCTAssertEqual(model.visibleEntries.map(\.id), [101])
        model.smartCollection = .images
        XCTAssertEqual(model.visibleEntries.map(\.id), [101])
        model.smartCollection = .videos
        XCTAssertEqual(model.visibleEntries.map(\.id), [102])
        model.smartCollection = .largeFiles
        XCTAssertEqual(model.visibleEntries.map(\.id), [103])
        model.smartCollection = .all
        XCTAssertEqual(model.visibleEntries.map(\.id), [2, 101, 102, 103])
        // [修改] XCTest 自动闭包不能跨 actor await，先读取隔离值再断言。
        let finalRequests = await repository.listCalls
        XCTAssertEqual(finalRequests, initialRequests)
    }

    // [修改] 停止不是暂停：必须同时清除播放态并回到视频起点。
    func testVideoPlaybackStateStopPausesAndReturnsToBeginning() {
        var state = DriveVideoPlaybackState(currentTime: 28, duration: 90, isPlaying: true)

        state.stop()

        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.currentTime, 0)
    }

    // [修改] 用户拖动进度时必须限制在合法时长内，避免把 AVPlayer seek 到负数或越界时间。
    func testVideoPlaybackStateSeekClampsToDuration() {
        var state = DriveVideoPlaybackState(currentTime: 10, duration: 90, isPlaying: false)

        state.seek(to: -5)
        XCTAssertEqual(state.currentTime, 0)

        state.seek(to: 120)
        XCTAssertEqual(state.currentTime, 90)
    }

    // [修改] AVPlayer 尚未拿到时长时会返回 NaN/无穷值，状态层必须收敛为可安全绑定 Slider 的数值。
    func testVideoPlaybackStateSynchronizeNormalizesInvalidPlayerTimes() {
        var state = DriveVideoPlaybackState()

        state.synchronize(currentTime: .nan, duration: .infinity, isPlaying: true)

        XCTAssertEqual(state.currentTime, 0)
        XCTAssertEqual(state.duration, 0)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.sliderUpperBound, 1)
    }

    // [修改] 拖动过程中只更新界面，松手后才向播放器发送一次 seek，避免连续 Range 请求和状态回跳。
    func testVideoPlaybackControllerSeeksOnceWhenScrubbingEnds() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        let controller = DriveVideoPlaybackController(
            url: URL(string: "https://127.0.0.1:10188/media/video.mp4")!,
            engineFactory: factory
        )
        await controller.start(autoplay: true)
        let engine = try XCTUnwrap(factory.engines.first)
        engine.emit(.ready(duration: 120))

        controller.beginScrubbing()
        controller.updateScrubbing(to: 15)
        controller.updateScrubbing(to: 45)
        controller.updateScrubbing(to: 75)
        await controller.endScrubbing()

        XCTAssertEqual(engine.seekCalls, [.init(seconds: 75, tolerance: 0.1)])
        XCTAssertFalse(controller.isScrubbing)
        XCTAssertTrue(controller.playbackState.isPlaying)
    }

    // [修改] 播放地址到期前必须续签，并在新播放器上恢复原进度和播放意图。
    func testVideoPlaybackControllerRefreshesExpiredURLBeforePlaying() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        var now = Date(timeIntervalSince1970: 100)
        var refreshCount = 0
        let initial = MediaPlayback(
            fileId: 101,
            playURL: URL(string: "https://127.0.0.1:10188/media/old.mp4?token=old")!,
            fileSize: 10,
            mimeType: "video/mp4",
            expiresInSeconds: 10
        )
        let refreshed = MediaPlayback(
            fileId: 101,
            playURL: URL(string: "https://127.0.0.1:10188/media/new.mp4?token=new")!,
            fileSize: 10,
            mimeType: "video/mp4",
            expiresInSeconds: 300
        )
        let controller = DriveVideoPlaybackController(
            playback: initial,
            engineFactory: factory,
            refreshPlayback: {
                refreshCount += 1
                return refreshed
            },
            now: { now }
        )
        await controller.start(autoplay: false)
        let firstEngine = try XCTUnwrap(factory.engines.first)
        firstEngine.emit(.time(currentTime: 42, duration: 100, isPlaying: false))
        now = Date(timeIntervalSince1970: 111)

        await controller.togglePlayback()

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(factory.requestedURLs, [initial.playURL, refreshed.playURL])
        let secondEngine = try XCTUnwrap(factory.engines.last)
        XCTAssertEqual(secondEngine.seekCalls, [.init(seconds: 42, tolerance: 0.1)])
        XCTAssertEqual(secondEngine.playCallCount, 1)
    }

    // [修改] 预览关闭时，已经挂起的地址续签返回后不能重新创建播放器。
    func testVideoPlaybackControllerInvalidationCancelsPendingRefreshBeforeInstallingEngine() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        let refreshGate = DriveVideoRefreshGate()
        let initial = MediaPlayback(
            fileId: 101,
            playURL: URL(string: "https://127.0.0.1:10188/media/old.mp4?token=old")!,
            fileSize: 10,
            mimeType: "video/mp4",
            expiresInSeconds: 1
        )
        let refreshed = MediaPlayback(
            fileId: 101,
            playURL: URL(string: "https://127.0.0.1:10188/media/new.mp4?token=new")!,
            fileSize: 10,
            mimeType: "video/mp4",
            expiresInSeconds: 300
        )
        let controller = DriveVideoPlaybackController(
            playback: initial,
            engineFactory: factory,
            refreshPlayback: {
                await refreshGate.waitUntilReleased()
                return refreshed
            },
            now: { Date(timeIntervalSince1970: 100) }
        )

        let startTask = Task { await controller.start(autoplay: true) }
        await refreshGate.waitUntilEntered()

        controller.invalidate()
        await refreshGate.release()
        await startTask.value

        XCTAssertTrue(factory.engines.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.playbackState.isPlaying)
    }

    // [修改] 续签等待期间用户点了暂停，旧续签结果不能按请求前意图重新播放。
    func testVideoPlaybackControllerPendingRefreshDoesNotOverridePause() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        let refreshGate = DriveVideoRefreshGate()
        let controller = makeRefreshableVideoController(factory: factory, refreshGate: refreshGate)
        await controller.start(autoplay: true)
        let initialEngine = try XCTUnwrap(factory.engines.first)
        initialEngine.emit(.time(currentTime: 24, duration: 120, isPlaying: true))

        let retryTask = Task { await controller.retry() }
        await refreshGate.waitUntilEntered()
        await controller.togglePlayback()
        await refreshGate.release()
        await retryTask.value

        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertFalse(controller.playbackState.isPlaying)
        XCTAssertEqual(controller.phase, .ready)
    }

    // [修改] 续签等待期间用户点了停止，旧续签结果不能恢复旧进度或重新播放。
    func testVideoPlaybackControllerPendingRefreshDoesNotOverrideStop() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        let refreshGate = DriveVideoRefreshGate()
        let controller = makeRefreshableVideoController(factory: factory, refreshGate: refreshGate)
        await controller.start(autoplay: true)
        let initialEngine = try XCTUnwrap(factory.engines.first)
        initialEngine.emit(.time(currentTime: 24, duration: 120, isPlaying: true))

        let retryTask = Task { await controller.retry() }
        await refreshGate.waitUntilEntered()
        await controller.stop()
        await refreshGate.release()
        await retryTask.value

        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertEqual(controller.playbackState.currentTime, 0)
        XCTAssertFalse(controller.playbackState.isPlaying)
        XCTAssertEqual(controller.phase, .ready)
    }

    // [修改] 续签请求期间旧播放器仍在前进，换源必须恢复返回时的最新进度，不能倒退到请求前。
    func testVideoPlaybackControllerPendingRefreshRestoresLatestProgress() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        let refreshGate = DriveVideoRefreshGate()
        let controller = makeRefreshableVideoController(factory: factory, refreshGate: refreshGate)
        await controller.start(autoplay: true)
        let initialEngine = try XCTUnwrap(factory.engines.first)
        initialEngine.emit(.time(currentTime: 24, duration: 120, isPlaying: true))

        let retryTask = Task { await controller.retry() }
        await refreshGate.waitUntilEntered()
        initialEngine.emit(.time(currentTime: 48, duration: 120, isPlaying: true))
        await refreshGate.release()
        await retryTask.value

        XCTAssertEqual(factory.engines.count, 2)
        let refreshedEngine = try XCTUnwrap(factory.engines.last)
        XCTAssertEqual(refreshedEngine.seekCalls, [.init(seconds: 48, tolerance: 0.1)])
        XCTAssertEqual(refreshedEngine.playCallCount, 1)
    }

    // [修改] 自然播放结束必须作废等待中的续签，旧结果不能换源并按结束前意图恢复播放。
    func testVideoPlaybackControllerPendingRefreshDoesNotOverrideEndedState() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        let refreshGate = DriveVideoRefreshGate()
        let controller = makeRefreshableVideoController(factory: factory, refreshGate: refreshGate)
        await controller.start(autoplay: true)
        let initialEngine = try XCTUnwrap(factory.engines.first)
        initialEngine.emit(.time(currentTime: 119, duration: 120, isPlaying: true))

        let retryTask = Task { await controller.retry() }
        await refreshGate.waitUntilEntered()
        initialEngine.emit(.ended)
        refreshGate.release()
        await retryTask.value

        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertFalse(controller.playbackState.isPlaying)
        XCTAssertEqual(controller.phase, .ended)
    }

    // [修改] 播放失败先续签恢复一次；新地址仍失败时必须显示错误，不能无限刷新或停在黑屏。
    func testVideoPlaybackControllerRetriesFailedSignedURLOnlyOnceUntilReady() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        var refreshCount = 0
        let initial = MediaPlayback(
            fileId: 101,
            playURL: URL(string: "https://127.0.0.1:10188/media/old.mp4?token=old")!,
            fileSize: nil,
            mimeType: "video/mp4",
            expiresInSeconds: 300
        )
        let refreshed = MediaPlayback(
            fileId: 101,
            playURL: URL(string: "https://127.0.0.1:10188/media/new.mp4?token=new")!,
            fileSize: nil,
            mimeType: "video/mp4",
            expiresInSeconds: 300
        )
        let controller = DriveVideoPlaybackController(
            playback: initial,
            engineFactory: factory,
            refreshPlayback: {
                refreshCount += 1
                return refreshed
            }
        )
        await controller.start(autoplay: true)
        let firstEngine = try XCTUnwrap(factory.engines.first)
        firstEngine.emit(.time(currentTime: 33, duration: 100, isPlaying: true))
        firstEngine.emit(.failed("媒体服务返回 HTTP 403"))
        try await waitForVideoEngineCount(factory, count: 2)

        let secondEngine = try XCTUnwrap(factory.engines.last)
        secondEngine.emit(.failed("视频格式不支持"))

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(controller.phase, .failed("视频格式不支持"))
    }

    // [修改] 播放自然结束后控制器进入结束态，播放按钮可明确执行从头重播。
    func testVideoPlaybackControllerPublishesEndedState() async throws {
        let factory = TestDriveVideoPlayerEngineFactory()
        let controller = DriveVideoPlaybackController(
            url: URL(string: "https://127.0.0.1:10188/media/video.mp4")!,
            engineFactory: factory
        )
        await controller.start(autoplay: true)
        let engine = try XCTUnwrap(factory.engines.first)
        engine.emit(.time(currentTime: 90, duration: 90, isPlaying: true))

        engine.emit(.ended)

        XCTAssertEqual(controller.phase, .ended)
        XCTAssertFalse(controller.playbackState.isPlaying)
    }

    // [修改] 横屏只在视频全屏期间开放，普通页面始终保持竖屏。
    func testAppOrientationPolicyOnlyAllowsLandscapeForFullscreenVideo() {
        XCTAssertEqual(AppOrientationController.supportedOrientations(videoFullscreen: false), .portrait)
        XCTAssertEqual(
            AppOrientationController.supportedOrientations(videoFullscreen: true),
            [.portrait, .landscapeLeft, .landscapeRight]
        )
    }

    // [修改] 带 token 的远程播放地址不能直接交给系统分享，本地下载文件才允许分享。
    func testVideoPreviewSharePolicyNeverExposesSignedPlaybackURL() {
        let signedURL = URL(string: "https://127.0.0.1:10188/media/video.mp4?token=secret")!
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("video.mp4")

        XCTAssertFalse(DrivePreviewSharePolicy.canShareDirectly(url: signedURL, isVideo: true))
        XCTAssertTrue(DrivePreviewSharePolicy.canShareDirectly(url: localURL, isVideo: true))
        XCTAssertTrue(DrivePreviewSharePolicy.canShareDirectly(url: signedURL, isVideo: false))
    }

    // [修改] 下拉达到阈值并松手时只触发一次刷新，未达到阈值不能误触发。
    func testPullRefreshStateTriggersOnceAfterThresholdOnRelease() {
        var state = DrivePullRefreshState(triggerDistance: 72)

        state.update(pullDistance: 71, isRefreshing: false)
        XCTAssertFalse(state.shouldTriggerRefresh(from: .interacting, to: .idle))

        state.update(pullDistance: 72, isRefreshing: false)
        XCTAssertTrue(state.shouldTriggerRefresh(from: .interacting, to: .idle))
        XCTAssertFalse(state.shouldTriggerRefresh(from: .interacting, to: .idle))
    }

    // [修改] 内容不足一屏时系统可能从 tracking 直接回 idle，达到阈值后仍必须触发刷新。
    func testPullRefreshStateTriggersWhenTrackingEndsWithoutInteractingPhase() {
        var state = DrivePullRefreshState(triggerDistance: 72)

        state.update(pullDistance: 96, isRefreshing: false)

        XCTAssertTrue(state.shouldTriggerRefresh(from: .tracking, to: .idle))
    }

    // [修改] 弹性回弹可能在松手后才越过阈值，decelerating 回 idle 时仍必须执行已挂起的刷新。
    func testPullRefreshStateTriggersWhenBounceDecelerationEnds() {
        var state = DrivePullRefreshState(triggerDistance: 72)

        state.update(pullDistance: 168, isRefreshing: false)

        XCTAssertTrue(state.shouldTriggerRefresh(from: .decelerating, to: .idle))
    }

    // [修改] 刷新很快结束时，同一次弹性回弹不能重新挂起并触发第二次请求。
    func testPullRefreshStateDoesNotRearmDuringSameBounceAfterTrigger() {
        var state = DrivePullRefreshState(triggerDistance: 72)

        state.update(pullDistance: 168, isRefreshing: false)
        XCTAssertTrue(state.shouldTriggerRefresh(from: .interacting, to: .decelerating))
        state.update(pullDistance: 120, isRefreshing: false)

        XCTAssertFalse(state.shouldTriggerRefresh(from: .decelerating, to: .idle))
    }

    // [修改] 已在刷新时继续下拉不能再次挂起新的刷新任务。
    func testPullRefreshStateDoesNotArmWhileRefreshing() {
        var state = DrivePullRefreshState(triggerDistance: 72)

        state.update(pullDistance: 100, isRefreshing: true)

        XCTAssertFalse(state.shouldTriggerRefresh(from: .interacting, to: .idle))
    }

    // [修改] 相同文件 ID 的缩略图缓存必须按服务器和账号隔离，切服或换号不能串图。
    func testThumbnailCacheKeyIsIsolatedByServerAndUser() throws {
        let firstServer = try ServerConfiguration(host: "server-a.example").storageScopeID
        let secondServer = try ServerConfiguration(host: "server-b.example").storageScopeID

        let first = DriveThumbnailCacheKey(serverScopeID: firstServer, userId: 7, fileId: 101)
        let otherServer = DriveThumbnailCacheKey(serverScopeID: secondServer, userId: 7, fileId: 101)
        let otherUser = DriveThumbnailCacheKey(serverScopeID: firstServer, userId: 8, fileId: 101)

        XCTAssertNotEqual(first, otherServer)
        XCTAssertNotEqual(first, otherUser)
    }

    // [修改] 与 macOS 一致，缩略图网络拉取和解码的全局并发峰值最多为 3。
    func testThumbnailLoadLimiterCapsConcurrentWorkAtThree() async throws {
        let limiter = DriveThumbnailLoadLimiter(maxConcurrent: 3)
        let probe = ThumbnailConcurrencyProbe()
        let tasks = (0..<9).map { _ in
            Task {
                try await limiter.withPermit {
                    await probe.begin()
                    try await Task.sleep(for: .milliseconds(80))
                    await probe.end()
                }
            }
        }

        for task in tasks { try await task.value }

        let maximumConcurrent = await probe.maximumConcurrent
        XCTAssertEqual(maximumConcurrent, 3)
    }

    // [修改] 图片缩略图直接按目标像素下采样，不能把原始大图尺寸带进列表缓存。
    func testThumbnailRendererDownsamplesLongestSideToThreeHundredSixtyPixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("large.png")
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        try XCTUnwrap(source.pngData()).write(to: sourceURL)

        let renderedData = await DriveThumbnailRenderer.jpegData(at: sourceURL, maxPixelSize: 360)
        let data = try XCTUnwrap(renderedData)
        let thumbnail = try XCTUnwrap(UIImage(data: data))

        XCTAssertEqual(Int(max(thumbnail.size.width, thumbnail.size.height).rounded()), 360)
        XCTAssertEqual(Int(min(thumbnail.size.width, thumbnail.size.height).rounded()), 180)
    }

    // [修改] 文件列表缩略图只能拉有限前缀，不能调用会完整落盘原图的 previewFile。
    func testImageThumbnailLoaderUsesBoundedThumbnailBytesWithoutPreviewDownload() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let sourceData = try XCTUnwrap(source.jpegData(compressionQuality: 0.9))
        let transferManager = ThumbnailDriveTransferManagerSpy(data: sourceData)
        let loader = DriveThumbnailLoader(
            transferManager: transferManager,
            mediaRepository: nil,
            username: "alice"
        )
        let entry = DriveFileEntry.file(id: 101, parentId: 1, name: "large.jpg", size: 50_000_000)

        let data = await loader.data(for: entry, kind: .image, cacheKey: UUID().uuidString)

        XCTAssertNotNil(data)
        let requests = await transferManager.thumbnailRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.maximumBytes, DriveThumbnailLoader.maximumRemoteImageBytes)
        XCTAssertLessThan(requests.first?.maximumBytes ?? .max, entry.size ?? 0)
        let previewCalls = await transferManager.previewCalls
        XCTAssertEqual(previewCalls, 0)
    }

    // [修改] 用户清理缩略图目录后，旧内存图必须失效，并由下一次加载重新拉取和落盘。
    func testThumbnailLoaderRefetchesAndRebuildsDiskCacheAfterDirectoryIsCleared() async throws {
        let firstImage = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        }
        let secondImage = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        }
        let firstSource = try XCTUnwrap(firstImage.jpegData(compressionQuality: 0.9))
        let secondSource = try XCTUnwrap(secondImage.jpegData(compressionQuality: 0.9))
        let firstManager = ThumbnailDriveTransferManagerSpy(data: firstSource)
        let secondManager = ThumbnailDriveTransferManagerSpy(data: secondSource)
        let cacheKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cacheRoot = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent("ChatStorage/DriveThumbnails", isDirectory: true)
        let cacheFile = cacheRoot.appendingPathComponent(cacheKey).appendingPathExtension("jpg")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let entry = DriveFileEntry.file(id: 102, parentId: 1, name: "replace.jpg", size: 50_000_000)

        let firstLoader = DriveThumbnailLoader(
            transferManager: firstManager,
            mediaRepository: nil,
            username: "alice"
        )
        let firstResult = await firstLoader.data(for: entry, kind: .image, cacheKey: cacheKey)
        XCTAssertNotNil(firstResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))

        try FileManager.default.removeItem(at: cacheRoot)
        let secondLoader = DriveThumbnailLoader(
            transferManager: secondManager,
            mediaRepository: nil,
            username: "alice"
        )
        let secondResult = await secondLoader.data(for: entry, kind: .image, cacheKey: cacheKey)

        let secondRequests = await secondManager.thumbnailRequests
        XCTAssertEqual(secondRequests.count, 1)
        XCTAssertNotEqual(secondResult, firstResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    // [修改] 列表缩略图磁盘缓存超过上限时淘汰最久未使用项，避免长期浏览后无限增长。
    func testThumbnailDiskCacheEvictsLeastRecentlyUsedFileWhenOverLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = DriveThumbnailCache(rootURL: root, maximumDiskBytes: 12)
        await cache.store(Data("first".utf8), for: "first")
        await cache.store(Data("other".utf8), for: "second")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: root.appendingPathComponent("second.jpg").path
        )
        _ = await cache.data(for: "first")

        await cache.store(Data("third".utf8), for: "third")

        let first = await cache.data(for: "first")
        let second = await cache.data(for: "second")
        let third = await cache.data(for: "third")
        XCTAssertEqual(first, Data("first".utf8))
        XCTAssertNil(second)
        XCTAssertEqual(third, Data("third".utf8))
    }

    func testVideoThumbnailRangePrefetchUsesHeadAndTailWithoutWholeFileDownload() {
        let fileSize: Int64 = 5 * 1024 * 1024 * 1024
        let chunk: Int64 = 4 * 1024 * 1024

        let ranges = DriveVideoThumbnailResourceLoader.prefetchRanges(
            fileSize: fileSize,
            maximumRangeBytes: chunk
        )

        XCTAssertEqual(ranges, [
            .init(offset: 0, length: chunk),
            .init(offset: fileSize - chunk, length: chunk),
        ])
    }

    func testLoadMergesCurrentDirectoryChildrenAndFirstFilePage() async {
        let repository = DriveRepositorySpy(
            roots: [.root(children: [.directory(id: 2, parentId: 1, name: "照片")])],
            pages: [
                .init(directoryId: 1, page: 1, search: ""): DrivePage(
                    records: [.file(id: 101, parentId: 1, name: "报告.pdf")],
                    currentPage: 1,
                    pageSize: 20,
                    totalCount: 1
                )
            ]
        )
        let model = DriveViewModel(repository: repository)

        await model.load()

        // [修改] 目录来自 0x15 递归树，文件来自 0x40 分页，两者在当前目录合并展示。
        XCTAssertEqual(model.entries.map(\.name), ["照片", "报告.pdf"])
        XCTAssertEqual(model.files.map(\.id), [101])
    }

    // [修改] 根接口只返回 hasChild 时，页面必须主动懒加载当前目录的下一层。
    func testLoadLazilyFetchesCurrentDirectoryChildren() async {
        let root = DriveFileEntry(
            id: 1,
            parentId: 0,
            name: "网盘",
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: true,
            modifiedAt: nil
        )
        let child = DriveFileEntry.directory(id: 2, parentId: 1, name: "照片")
        let repository = DriveRepositorySpy(
            roots: [root],
            childrenByDirectory: [1: [child]],
            pages: [.init(directoryId: 1, page: 1, search: ""): .empty]
        )
        let model = DriveViewModel(repository: repository)

        await model.load()

        XCTAssertEqual(model.entries.map(\.id), [2])
        let requests = await repository.childrenRequests
        XCTAssertEqual(requests, [1])
    }

    // [修改] 普通下拉刷新只更新当前目录，不能再次请求根目录树。
    func testRefreshCurrentDirectoryDoesNotRequestRootsAgain() async {
        let oldDirectory = DriveFileEntry.directory(id: 2, parentId: 1, name: "旧目录")
        let refreshedDirectory = DriveFileEntry.directory(id: 3, parentId: 1, name: "新目录")
        let repository = DriveRefreshRepositorySpy(
            roots: [.root(children: [oldDirectory])],
            childrenResponses: [1: [.children([refreshedDirectory], delay: .zero)]],
            pageResponses: [
                .init(directoryId: 1, page: 1, search: ""): [
                    .page(.empty, delay: .zero),
                    .page(.empty, delay: .zero),
                ]
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.refreshCurrentDirectory()

        let rootCalls = await repository.rootCalls
        XCTAssertEqual(rootCalls, 1)
    }

    // [修改] 深层目录下拉刷新后仍停留在原路径，只替换该目录的子目录和文件第一页。
    func testRefreshCurrentDirectoryKeepsSelectedPath() async {
        let oldAlbum = DriveFileEntry.directory(id: 3, parentId: 2, name: "旧相册")
        let newAlbum = DriveFileEntry.directory(id: 4, parentId: 2, name: "新相册")
        let photos = DriveFileEntry(
            id: 2,
            parentId: 1,
            name: "照片",
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: true,
            modifiedAt: nil,
            children: [oldAlbum]
        )
        let repository = DriveRefreshRepositorySpy(
            roots: [.root(children: [photos])],
            childrenResponses: [2: [.children([newAlbum], delay: .zero)]],
            pageResponses: [
                .init(directoryId: 1, page: 1, search: ""): [.page(.empty, delay: .zero)],
                .init(directoryId: 2, page: 1, search: ""): [
                    .page(
                        DrivePage(
                            records: [.file(id: 101, parentId: 2, name: "旧照片.jpg")],
                            currentPage: 1,
                            pageSize: 20,
                            totalCount: 1
                        ),
                        delay: .zero
                    ),
                    .page(
                        DrivePage(
                            records: [.file(id: 102, parentId: 2, name: "新照片.jpg")],
                            currentPage: 1,
                            pageSize: 20,
                            totalCount: 1
                        ),
                        delay: .zero
                    ),
                ]
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        await model.selectDirectory(id: 2)

        await model.refreshCurrentDirectory()

        XCTAssertEqual(model.currentDirectory?.id, 2)
        XCTAssertEqual(model.path.map(\.id), [1, 2])
        XCTAssertEqual(model.entries.map(\.name), ["新相册", "新照片.jpg"])
    }

    // [修改] 当前目录刷新任一请求失败时，旧目录、旧文件和分页数据必须原样保留。
    func testRefreshCurrentDirectoryFailurePreservesExistingEntries() async {
        let oldDirectory = DriveFileEntry.directory(id: 2, parentId: 1, name: "旧目录")
        let newDirectory = DriveFileEntry.directory(id: 3, parentId: 1, name: "新目录")
        let initialPage = DrivePage(
            records: [.file(id: 101, parentId: 1, name: "旧文件.pdf")],
            currentPage: 1,
            pageSize: 1,
            totalCount: 3,
            totalPages: 3
        )
        let repository = DriveRefreshRepositorySpy(
            roots: [.root(children: [oldDirectory])],
            childrenResponses: [1: [.children([newDirectory], delay: .zero)]],
            pageResponses: [
                .init(directoryId: 1, page: 1, search: ""): [
                    .page(initialPage, delay: .zero),
                    .failure(.invalidResponse, delay: .zero),
                ]
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        let originalRoots = model.directoryRoots
        let originalDirectory = model.currentDirectory
        let originalPath = model.path
        let originalFiles = model.files
        let originalCurrentPage = model.currentPage
        let originalTotalPages = model.totalPages
        let originalTotalCount = model.totalCount

        await model.refreshCurrentDirectory()

        XCTAssertEqual(model.directoryRoots, originalRoots)
        XCTAssertEqual(model.currentDirectory, originalDirectory)
        XCTAssertEqual(model.path, originalPath)
        XCTAssertEqual(model.files, originalFiles)
        XCTAssertEqual(model.currentPage, originalCurrentPage)
        XCTAssertEqual(model.totalPages, originalTotalPages)
        XCTAssertEqual(model.totalCount, originalTotalCount)
        XCTAssertEqual(model.errorMessage, "网盘刷新失败")
    }

    // [修改] 子目录请求失败也必须保持完整目录、文件和分页快照，不能只保护文件列表。
    func testRefreshCurrentDirectoryChildrenFailurePreservesCompleteSnapshot() async {
        let oldDirectory = DriveFileEntry.directory(id: 2, parentId: 1, name: "旧目录")
        let initialPage = DrivePage(
            records: [.file(id: 101, parentId: 1, name: "旧文件.pdf")],
            currentPage: 1,
            pageSize: 1,
            totalCount: 4,
            totalPages: 4
        )
        let repository = DriveRefreshRepositorySpy(
            roots: [.root(children: [oldDirectory])],
            childrenResponses: [1: [.failure(.invalidResponse, delay: .zero)]],
            pageResponses: [
                .init(directoryId: 1, page: 1, search: ""): [
                    .page(initialPage, delay: .zero),
                    .page(
                        DrivePage(
                            records: [.file(id: 102, parentId: 1, name: "不应写入.pdf")],
                            currentPage: 1,
                            pageSize: 20,
                            totalCount: 1
                        ),
                        delay: .zero
                    ),
                ]
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        let originalRoots = model.directoryRoots
        let originalDirectory = model.currentDirectory
        let originalPath = model.path
        let originalFiles = model.files
        let originalCurrentPage = model.currentPage
        let originalTotalPages = model.totalPages
        let originalTotalCount = model.totalCount

        await model.refreshCurrentDirectory()

        XCTAssertEqual(model.directoryRoots, originalRoots)
        XCTAssertEqual(model.currentDirectory, originalDirectory)
        XCTAssertEqual(model.path, originalPath)
        XCTAssertEqual(model.files, originalFiles)
        XCTAssertEqual(model.currentPage, originalCurrentPage)
        XCTAssertEqual(model.totalPages, originalTotalPages)
        XCTAssertEqual(model.totalCount, originalTotalCount)
        XCTAssertEqual(model.errorMessage, "网盘刷新失败")
    }

    // [修改] 目录名右侧动画依赖独立刷新状态，状态必须覆盖完整请求周期。
    func testRefreshCurrentDirectoryPublishesRefreshingState() async throws {
        let oldDirectory = DriveFileEntry.directory(id: 2, parentId: 1, name: "旧目录")
        let repository = DriveRefreshRepositorySpy(
            roots: [.root(children: [oldDirectory])],
            childrenResponses: [1: [.children([oldDirectory], delay: .milliseconds(150))]],
            pageResponses: [
                .init(directoryId: 1, page: 1, search: ""): [
                    .page(.empty, delay: .zero),
                    .page(.empty, delay: .milliseconds(150)),
                ]
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let refreshTask = Task { await model.refreshCurrentDirectory() }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(model.isRefreshing)
        await refreshTask.value
        XCTAssertFalse(model.isRefreshing)
    }

    // [修改] 切换目录必须立即使旧刷新失效，并允许新目录在旧请求返回前启动自己的刷新。
    func testSwitchingDirectoryInvalidatesOlderRefreshAndAllowsNewDirectoryRefresh() async throws {
        let photos = DriveFileEntry.directory(id: 2, parentId: 1, name: "照片")
        let refreshedAlbum = DriveFileEntry.directory(id: 3, parentId: 2, name: "新相册")
        let olderRefreshGate = DriveResponseGate()
        let currentRefreshGate = DriveResponseGate()
        let rootKey = DriveRefreshRepositorySpy.PageKey(directoryId: 1, page: 1, search: "")
        let childKey = DriveRefreshRepositorySpy.PageKey(directoryId: 2, page: 1, search: "")
        let repository = DriveRefreshRepositorySpy(
            roots: [.root(children: [photos])],
            childrenResponses: [
                1: [.children([photos], delay: .zero)],
                2: [.children([refreshedAlbum], delay: .zero)],
            ],
            pageResponses: [
                rootKey: [
                    .page(.empty, delay: .zero),
                    .gatedPage(.empty, gate: olderRefreshGate),
                ],
                childKey: [
                    .page(
                        DrivePage(
                            records: [.file(id: 201, parentId: 2, name: "旧照片.jpg")],
                            currentPage: 1,
                            pageSize: 20,
                            totalCount: 1
                        ),
                        delay: .zero
                    ),
                    .gatedPage(
                        DrivePage(
                            records: [.file(id: 202, parentId: 2, name: "新照片.jpg")],
                            currentPage: 1,
                            pageSize: 20,
                            totalCount: 1
                        ),
                        gate: currentRefreshGate
                    ),
                ],
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let olderRefresh = Task { await model.refreshCurrentDirectory() }
        try await waitForDriveRefreshRequest(repository, key: rootKey, count: 2)
        await model.selectDirectory(id: 2)

        XCTAssertFalse(model.isRefreshing)
        let currentRefresh = Task { await model.refreshCurrentDirectory() }
        try await waitForDriveRefreshRequest(repository, key: childKey, count: 2)
        XCTAssertTrue(model.isRefreshing)

        // [修改] 先结束旧刷新，新刷新仍被闸门阻塞；旧 defer 不能误清理新目录的动画状态。
        await olderRefreshGate.release()
        await olderRefresh.value
        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.currentDirectory?.id, 2)

        await currentRefreshGate.release()
        await currentRefresh.value
        XCTAssertEqual(model.currentDirectory?.id, 2)
        XCTAssertEqual(model.path.map(\.id), [1, 2])
        XCTAssertEqual(model.entries.map(\.name), ["新相册", "新照片.jpg"])
        XCTAssertFalse(model.isRefreshing)
    }

    // [修改] 搜索开始时旧刷新动画必须立即消失，旧刷新返回后不能覆盖搜索结果。
    func testSearchInvalidatesOlderRefreshStateAndKeepsSearchResults() async throws {
        let oldDirectory = DriveFileEntry.directory(id: 2, parentId: 1, name: "旧目录")
        let rootKey = DriveRefreshRepositorySpy.PageKey(directoryId: 1, page: 1, search: "")
        let searchKey = DriveRefreshRepositorySpy.PageKey(directoryId: 1, page: 1, search: "报告")
        let repository = DriveRefreshRepositorySpy(
            roots: [.root(children: [oldDirectory])],
            childrenResponses: [1: [.children([oldDirectory], delay: .milliseconds(300))]],
            pageResponses: [
                rootKey: [
                    .page(.empty, delay: .zero),
                    .page(
                        DrivePage(
                            records: [.file(id: 102, parentId: 1, name: "旧刷新结果.pdf")],
                            currentPage: 1,
                            pageSize: 20,
                            totalCount: 1
                        ),
                        delay: .milliseconds(300)
                    ),
                ],
                searchKey: [
                    .page(
                        DrivePage(
                            records: [.file(id: 103, parentId: 1, name: "报告.pdf")],
                            currentPage: 1,
                            pageSize: 20,
                            totalCount: 1
                        ),
                        delay: .zero
                    ),
                ],
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let olderRefresh = Task { await model.refreshCurrentDirectory() }
        try await waitForDriveRefreshRequest(repository, key: rootKey, count: 2)
        model.searchText = "报告"
        await model.performSearch()

        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.files.map(\.name), ["报告.pdf"])

        await olderRefresh.value
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.files.map(\.name), ["报告.pdf"])
        XCTAssertNil(model.errorMessage)
    }

    // [修改] 当前目录正在原子刷新时禁止启动第二页请求，避免第二页结果混入新的第一页快照。
    func testLoadNextPageDoesNotStartWhileCurrentDirectoryIsRefreshing() async throws {
        let firstPage = DrivePage(
            records: [.file(id: 101, parentId: 1, name: "第一页.pdf")],
            currentPage: 1,
            pageSize: 1,
            totalCount: 2,
            totalPages: 2
        )
        let refreshedPage = DrivePage(
            records: [.file(id: 103, parentId: 1, name: "刷新第一页.pdf")],
            currentPage: 1,
            pageSize: 1,
            totalCount: 2,
            totalPages: 2
        )
        let firstKey = DriveRefreshRepositorySpy.PageKey(directoryId: 1, page: 1, search: "")
        let secondKey = DriveRefreshRepositorySpy.PageKey(directoryId: 1, page: 2, search: "")
        let repository = DriveRefreshRepositorySpy(
            roots: [.root()],
            childrenResponses: [1: [.children([], delay: .milliseconds(150))]],
            pageResponses: [
                firstKey: [
                    .page(firstPage, delay: .zero),
                    .page(refreshedPage, delay: .milliseconds(150)),
                ],
                secondKey: [
                    .page(
                        DrivePage(
                            records: [.file(id: 102, parentId: 1, name: "第二页.pdf")],
                            currentPage: 2,
                            pageSize: 1,
                            totalCount: 2,
                            totalPages: 2
                        ),
                        delay: .zero
                    ),
                ],
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let refresh = Task { await model.refreshCurrentDirectory() }
        try await waitForDriveRefreshRequest(repository, key: firstKey, count: 2)
        await model.loadNextPage()

        let secondPageRequests = await repository.pageRequestCount(for: secondKey)
        XCTAssertEqual(secondPageRequests, 0)
        await refresh.value
        XCTAssertEqual(model.files.map(\.name), ["刷新第一页.pdf"])
    }

    // [修改] 展开尚未加载的节点后，目录树必须递归替换对应子节点。
    func testLoadDirectoryChildrenReplacesNestedTreeNode() async {
        let lazyPhotos = DriveFileEntry(
            id: 2,
            parentId: 1,
            name: "照片",
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: true,
            modifiedAt: nil
        )
        let travel = DriveFileEntry.directory(id: 3, parentId: 2, name: "旅行")
        let repository = DriveRepositorySpy(
            roots: [.root(children: [lazyPhotos])],
            childrenByDirectory: [2: [travel]]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.loadDirectoryChildren(id: 2)

        XCTAssertEqual(model.directoryRoots.first?.children.first?.children.map(\.id), [3])
    }

    // [修改] 懒加载明确返回空数组后必须变成叶子，避免目录选择器一直显示无效展开箭头。
    func testLoadDirectoryChildrenMarksEmptyResultAsLeaf() async throws {
        let lazyPhotos = DriveFileEntry(
            id: 2,
            parentId: 1,
            name: "空目录",
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: true,
            modifiedAt: nil
        )
        let repository = DriveRepositorySpy(
            roots: [.root(children: [lazyPhotos])],
            childrenByDirectory: [2: []]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.loadDirectoryChildren(id: 2)

        let resolved = try XCTUnwrap(model.directoryRoots.first?.children.first)
        XCTAssertFalse(resolved.hasChildren)
        XCTAssertTrue(resolved.children.isEmpty)
    }

    // [修改] 移动弹窗打开后即使目录继续懒加载，也必须用最新目录树排除全部新出现的子孙。
    func testInvalidMoveTargetsUseLatestLoadedDirectoryTree() async throws {
        let lazyPhotos = DriveFileEntry(
            id: 2,
            parentId: 1,
            name: "照片",
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: true,
            modifiedAt: nil
        )
        let travel = DriveFileEntry.directory(id: 3, parentId: 2, name: "旅行")
        let repository = DriveRepositorySpy(
            roots: [.root(children: [lazyPhotos])],
            childrenByDirectory: [2: [travel]]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        let staleSnapshot = try XCTUnwrap(model.directoryRoots.first?.children.first)

        await model.loadDirectoryChildren(id: 2)

        XCTAssertEqual(model.invalidMoveTargetIDs(for: staleSnapshot), [2, 3])
    }

    func testSelectNestedDirectoryBuildsFullPathAndLoadsItsFiles() async {
        let travel = DriveFileEntry.directory(id: 3, parentId: 2, name: "旅行")
        let photos = DriveFileEntry.directory(id: 2, parentId: 1, name: "照片", children: [travel])
        let repository = DriveRepositorySpy(
            roots: [.root(children: [photos])],
            pages: [
                .init(directoryId: 1, page: 1, search: ""): .empty,
                .init(directoryId: 3, page: 1, search: ""): .empty,
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.selectDirectory(id: 3)

        XCTAssertEqual(model.path.map(\.id), [1, 2, 3])
        let requests = await repository.listRequests
        XCTAssertEqual(requests.last?.directoryId, 3)
    }

    // [修改] 根接口保持浅树时，用户在深层目录下拉刷新也不能被弹回根目录。
    func testReloadPreservesDeepDirectoryWhenRootsRemainShallow() async {
        let root = DriveFileEntry(
            id: 1,
            parentId: 0,
            name: "网盘",
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: true,
            modifiedAt: nil
        )
        let photos = DriveFileEntry(
            id: 2,
            parentId: 1,
            name: "照片",
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: true,
            modifiedAt: nil
        )
        let travel = DriveFileEntry.directory(id: 3, parentId: 2, name: "旅行")
        let repository = DriveRepositorySpy(
            roots: [root],
            childrenByDirectory: [1: [photos], 2: [travel]],
            pages: [
                .init(directoryId: 1, page: 1, search: ""): .empty,
                .init(directoryId: 3, page: 1, search: ""): .empty,
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        await model.loadDirectoryChildren(id: 2)
        await model.selectDirectory(id: 3)

        await model.load()

        XCTAssertEqual(model.currentDirectory?.id, 3)
        XCTAssertEqual(model.path.map(\.id), [1, 2, 3])
        let requests = await repository.listRequests
        XCTAssertEqual(requests.last?.directoryId, 3)
    }

    // [修改] 快速连续选择目录时，先点但后返回的懒加载请求不能抢回当前目录。
    func testLatestDirectorySelectionWinsWhenEarlierLazyLoadReturnsLater() async throws {
        let lazyPhotos = DriveFileEntry(
            id: 2,
            parentId: 1,
            name: "照片",
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: true,
            modifiedAt: nil
        )
        let documents = DriveFileEntry.directory(id: 3, parentId: 1, name: "文档")
        let repository = DriveRepositorySpy(
            roots: [.root(children: [lazyPhotos, documents])],
            childrenByDirectory: [2: []],
            childrenDelays: [2: .milliseconds(150)],
            pages: [
                .init(directoryId: 1, page: 1, search: ""): .empty,
                .init(directoryId: 2, page: 1, search: ""): .empty,
                .init(directoryId: 3, page: 1, search: ""): .empty,
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let earlierSelection = Task { await model.selectDirectory(id: 2) }
        try await Task.sleep(for: .milliseconds(20))
        await model.selectDirectory(id: 3)
        await earlierSelection.value

        XCTAssertEqual(model.currentDirectory?.id, 3)
        XCTAssertEqual(model.path.map(\.id), [1, 3])
    }

    func testLoadNextPageAppendsAndDeduplicatesFiles() async {
        let repository = DriveRepositorySpy(
            pages: [
                .init(directoryId: 1, page: 1, search: ""): DrivePage(
                    records: [.file(id: 101, parentId: 1, name: "一.pdf")],
                    currentPage: 1,
                    pageSize: 1,
                    totalCount: 2,
                    totalPages: 2
                ),
                .init(directoryId: 1, page: 2, search: ""): DrivePage(
                    records: [
                        .file(id: 101, parentId: 1, name: "一.pdf"),
                        .file(id: 102, parentId: 1, name: "二.pdf"),
                    ],
                    currentPage: 2,
                    pageSize: 1,
                    totalCount: 2,
                    totalPages: 2
                ),
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.loadNextPage()

        XCTAssertEqual(model.files.map(\.id), [101, 102])
    }

    // [修改] 快速切目录时，较晚返回的旧目录首页不能覆盖当前目录。
    func testSwitchingDirectoryIgnoresOlderFirstPageResponse() async throws {
        let child = DriveFileEntry.directory(id: 2, parentId: 1, name: "照片")
        let rootKey = SequencedDriveRepository.PageKey(directoryId: 1, page: 1, search: "")
        let childKey = SequencedDriveRepository.PageKey(directoryId: 2, page: 1, search: "")
        let repository = SequencedDriveRepository(
            roots: [.root(children: [child])],
            responses: [
                rootKey: [
                    .page(DrivePage(records: [.file(id: 101, parentId: 1, name: "初始.pdf")], currentPage: 1, pageSize: 20, totalCount: 1), delay: .zero),
                    .page(DrivePage(records: [.file(id: 102, parentId: 1, name: "根目录.pdf")], currentPage: 1, pageSize: 20, totalCount: 1), delay: .milliseconds(10)),
                ],
                childKey: [
                    .page(DrivePage(records: [.file(id: 201, parentId: 2, name: "照片.jpg")], currentPage: 1, pageSize: 20, totalCount: 1), delay: .milliseconds(100)),
                ],
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let openingChild = Task { await model.selectDirectory(id: 2) }
        try await waitForDriveRequest(repository, key: childKey, count: 1)
        let returningRoot = Task { await model.selectDirectory(id: 1) }
        await returningRoot.value
        await openingChild.value

        XCTAssertEqual(model.currentDirectory?.id, 1)
        XCTAssertEqual(model.files.map(\.id), [102])
    }

    // [修改] 上一目录的分页响应不能追加到新目录列表。
    func testSwitchingDirectoryIgnoresOlderNextPageResponse() async throws {
        let child = DriveFileEntry.directory(id: 2, parentId: 1, name: "照片")
        let rootFirstKey = SequencedDriveRepository.PageKey(directoryId: 1, page: 1, search: "")
        let rootSecondKey = SequencedDriveRepository.PageKey(directoryId: 1, page: 2, search: "")
        let childKey = SequencedDriveRepository.PageKey(directoryId: 2, page: 1, search: "")
        let repository = SequencedDriveRepository(
            roots: [.root(children: [child])],
            responses: [
                rootFirstKey: [
                    .page(DrivePage(records: [.file(id: 101, parentId: 1, name: "第一页.pdf")], currentPage: 1, pageSize: 1, totalCount: 2, totalPages: 2), delay: .zero),
                ],
                rootSecondKey: [
                    .page(DrivePage(records: [.file(id: 102, parentId: 1, name: "第二页.pdf")], currentPage: 2, pageSize: 1, totalCount: 2, totalPages: 2), delay: .milliseconds(100)),
                ],
                childKey: [
                    .page(DrivePage(records: [.file(id: 201, parentId: 2, name: "照片.jpg")], currentPage: 1, pageSize: 20, totalCount: 1), delay: .milliseconds(10)),
                ],
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let loadingNextPage = Task { await model.loadNextPage() }
        try await waitForDriveRequest(repository, key: rootSecondKey, count: 1)
        await model.selectDirectory(id: 2)
        await loadingNextPage.value

        XCTAssertEqual(model.currentDirectory?.id, 2)
        XCTAssertEqual(model.files.map(\.id), [201])
    }

    // [修改] 新搜索替换旧请求时，底层 cancelled 只是控制流，不应显示业务错误。
    func testCancelledSearchDoesNotExposeDriveError() async {
        let rootKey = SequencedDriveRepository.PageKey(directoryId: 1, page: 1, search: "")
        let searchKey = SequencedDriveRepository.PageKey(directoryId: 1, page: 1, search: "报告")
        let repository = SequencedDriveRepository(
            roots: [.root()],
            responses: [
                rootKey: [.page(.empty, delay: .zero)],
                searchKey: [.failure(.cancelled, delay: .zero)],
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        model.searchText = "报告"

        await model.performSearch()

        XCTAssertNil(model.errorMessage)
    }

    func testPerformSearchUsesServerQueryAndResetsToFirstPage() async {
        let repository = DriveRepositorySpy(
            pages: [
                .init(directoryId: 1, page: 1, search: ""): .empty,
                .init(directoryId: 1, page: 1, search: "报告"): DrivePage(
                    records: [.file(id: 101, parentId: 1, name: "报告.pdf")],
                    currentPage: 1,
                    pageSize: 20,
                    totalCount: 1
                ),
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        model.searchText = " 报告 "

        await model.performSearch()

        let requests = await repository.listRequests
        XCTAssertEqual(requests.last?.search, "报告")
        XCTAssertEqual(model.files.map(\.name), ["报告.pdf"])
    }

    func testFileDetailAndDirectoryMoveUseRepositoryAndRefreshTree() async {
        let directory = DriveFileEntry.directory(id: 2, parentId: 1, name: "照片")
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "报告.pdf")
        let repository = DriveRepositorySpy(
            roots: [.root(children: [directory])],
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [file], currentPage: 1, pageSize: 20, totalCount: 1)],
            details: [101: DriveFileEntry.file(id: 101, parentId: 1, name: "报告.pdf", path: "/报告.pdf", md5: "abc")]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let detail = await model.loadDetail(for: file)
        await model.moveDirectory(directory, targetParentId: 8)

        XCTAssertEqual(detail?.md5, "abc")
        let moves = await repository.movedDirectories
        XCTAssertEqual(moves.first?.0, 2)
        XCTAssertEqual(moves.first?.1, 8)
        let rootCalls = await repository.rootCalls
        XCTAssertGreaterThanOrEqual(rootCalls, 2)
    }

    // [修改] 详情接口失败时仍展示列表已有元数据，和 macOS 详情面板的降级行为一致。
    func testFileDetailFallsBackToListEntryWhenRequestFails() async throws {
        let repository = DriveRepositorySpy()
        let model = DriveViewModel(repository: repository)
        await model.load()
        let file = try XCTUnwrap(model.files.first)

        let detail = await model.loadDetail(for: file)

        XCTAssertEqual(detail, file)
        XCTAssertEqual(model.errorMessage, "网盘操作失败")
    }

    // [修改] 即使绕过移动弹窗，状态层也不能把目录移动到自身子孙形成循环树。
    func testMoveDirectoryRejectsDescendantTarget() async {
        let child = DriveFileEntry.directory(id: 3, parentId: 2, name: "旅行")
        let photos = DriveFileEntry.directory(id: 2, parentId: 1, name: "照片", children: [child])
        let repository = DriveRepositorySpy(roots: [.root(children: [photos])])
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.moveDirectory(photos, targetParentId: child.id)

        let moves = await repository.movedDirectories
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(model.errorMessage, "不能移动到自身或子文件夹")
    }

    // [修改] 根目录是账号级入口，状态层不能发送重命名请求。
    func testRenameRejectsRootDirectory() async {
        let root = DriveFileEntry.root()
        let repository = DriveRepositorySpy(roots: [root])
        let model = DriveViewModel(repository: repository)
        await model.load()

        let renamed = await model.rename(root, name: "新根目录")

        let calls = await repository.renamedDirectories
        XCTAssertFalse(renamed)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(model.errorMessage, "根目录不能重命名")
    }

    // [修改] 根目录删除必须在客户端拦截，不能依赖服务端兜底。
    func testDeleteRejectsRootDirectory() async {
        let root = DriveFileEntry.root()
        let repository = DriveRepositorySpy(roots: [root])
        let model = DriveViewModel(repository: repository)
        await model.load()

        let deleted = await model.delete(root)

        let calls = await repository.deletedDirectories
        XCTAssertFalse(deleted)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(model.errorMessage, "根目录不能删除")
    }

    // [修改] 根目录不能移动到其他根或子树，避免破坏账号目录结构。
    func testMoveRejectsRootDirectory() async {
        let root = DriveFileEntry.root()
        let repository = DriveRepositorySpy(roots: [root])
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.moveDirectory(root, targetParentId: 9)

        let calls = await repository.movedDirectories
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(model.errorMessage, "根目录不能移动")
    }

    func testBatchDeleteContinuesAfterOneFailure() async {
        let directory = DriveFileEntry.directory(id: 2, parentId: 1, name: "空目录")
        let first = DriveFileEntry.file(id: 101, parentId: 1, name: "一.pdf")
        let second = DriveFileEntry.file(id: 102, parentId: 1, name: "二.pdf")
        let repository = DriveRepositorySpy(
            roots: [.root(children: [directory])],
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [first, second], currentPage: 1, pageSize: 20, totalCount: 2)],
            deleteFileFailures: [102]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        model.toggleSelection(directory)
        model.toggleSelection(first)
        model.toggleSelection(second)

        await model.deleteSelected()

        let deletedDirectories = await repository.deletedDirectories
        let deletedFiles = await repository.deletedFiles
        XCTAssertEqual(deletedDirectories, [2])
        XCTAssertEqual(deletedFiles, [101, 102])
        XCTAssertEqual(model.selectedEntryIDs, [102])
        XCTAssertNotNil(model.errorMessage)
    }

    // [修改] 选中目录下载时必须递归下载全部文件，并在本地保留目录层级，不能静默忽略目录。
    func testBatchDownloadRecursivelyDownloadsSelectedDirectoryTree() async throws {
        let nestedDirectory = DriveFileEntry.directory(id: 3, parentId: 2, name: "子目录")
        let selectedDirectory = DriveFileEntry.directory(
            id: 2,
            parentId: 1,
            name: "资料",
            children: [nestedDirectory]
        )
        let directFile = DriveFileEntry.file(id: 101, parentId: 2, name: "直接.pdf", size: 3)
        let nestedFile = DriveFileEntry.file(id: 102, parentId: 3, name: "嵌套.jpg", size: 4)
        let repository = DriveRepositorySpy(
            roots: [.root(children: [selectedDirectory])],
            childrenByDirectory: [2: [nestedDirectory], 3: []],
            pages: [
                .init(directoryId: 1, page: 1, search: ""): .empty,
                .init(directoryId: 2, page: 1, search: ""): DrivePage(records: [directFile], currentPage: 1, pageSize: 20, totalCount: 1),
                .init(directoryId: 3, page: 1, search: ""): DrivePage(records: [nestedFile], currentPage: 1, pageSize: 20, totalCount: 1),
            ]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        model.toggleSelection(selectedDirectory)
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let downloaded = await model.downloadSelected(to: destinationDirectory)

        XCTAssertEqual(downloaded.map(\.lastPathComponent), ["资料"])
        let downloads = await transferManager.downloads
        let relativePaths = Set(downloads.map {
            $0.destinationURL.path.replacingOccurrences(of: destinationDirectory.path + "/", with: "")
        })
        XCTAssertEqual(relativePaths, ["资料/直接.pdf", "资料/子目录/嵌套.jpg"])
    }

    // [修改] 递归目录不能只取第一页，否则超过 20 个文件时会漏下载。
    func testRecursiveDirectoryDownloadLoadsEveryFilePage() async throws {
        let selectedDirectory = DriveFileEntry.directory(id: 2, parentId: 1, name: "资料")
        let firstFile = DriveFileEntry.file(id: 101, parentId: 2, name: "第一页.pdf", size: 3)
        let secondFile = DriveFileEntry.file(id: 102, parentId: 2, name: "第二页.pdf", size: 4)
        let repository = DriveRepositorySpy(
            roots: [.root(children: [selectedDirectory])],
            childrenByDirectory: [2: []],
            pages: [
                .init(directoryId: 1, page: 1, search: ""): .empty,
                .init(directoryId: 2, page: 1, search: ""): DrivePage(
                    records: [firstFile],
                    currentPage: 1,
                    pageSize: 1,
                    totalCount: 2,
                    totalPages: 2
                ),
                .init(directoryId: 2, page: 2, search: ""): DrivePage(
                    records: [secondFile],
                    currentPage: 2,
                    pageSize: 1,
                    totalCount: 2,
                    totalPages: 2
                ),
            ]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        model.toggleSelection(selectedDirectory)
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        _ = await model.downloadSelected(to: destinationDirectory)

        let downloads = await transferManager.downloads
        XCTAssertEqual(Set(downloads.map(\.remoteFileId)), [101, 102])
        let requests = await repository.listRequests.filter { $0.directoryId == 2 }
        XCTAssertEqual(requests.map(\.page), [1, 2])
    }

    // [修改] 服务端拒绝直接删除含文件目录，客户端必须先删完整子树文件，再删除目录。
    func testDeleteDirectoryRecursivelyDeletesFilesBeforeDirectory() async {
        let nestedDirectory = DriveFileEntry.directory(id: 3, parentId: 2, name: "子目录")
        let selectedDirectory = DriveFileEntry.directory(id: 2, parentId: 1, name: "资料", children: [nestedDirectory])
        let directFile = DriveFileEntry.file(id: 101, parentId: 2, name: "直接.pdf")
        let nestedFile = DriveFileEntry.file(id: 102, parentId: 3, name: "嵌套.jpg")
        let repository = DriveRepositorySpy(
            roots: [.root(children: [selectedDirectory])],
            childrenByDirectory: [2: [nestedDirectory], 3: []],
            pages: [
                .init(directoryId: 1, page: 1, search: ""): .empty,
                .init(directoryId: 2, page: 1, search: ""): DrivePage(records: [directFile], currentPage: 1, pageSize: 20, totalCount: 1),
                .init(directoryId: 3, page: 1, search: ""): DrivePage(records: [nestedFile], currentPage: 1, pageSize: 20, totalCount: 1),
            ]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()

        let deleted = await model.delete(selectedDirectory)

        XCTAssertTrue(deleted)
        let operations = await repository.deleteOperations
        XCTAssertEqual(operations, [.file(101), .file(102), .directory(2)])
    }

    // [修改] 递归删除任一文件失败时不能继续删父目录，选中项保留供用户重试。
    func testBatchDeleteKeepsDirectorySelectedWhenRecursiveFileDeleteFails() async {
        let selectedDirectory = DriveFileEntry.directory(id: 2, parentId: 1, name: "资料")
        let firstFile = DriveFileEntry.file(id: 101, parentId: 2, name: "成功.pdf")
        let failedFile = DriveFileEntry.file(id: 102, parentId: 2, name: "失败.pdf")
        let repository = DriveRepositorySpy(
            roots: [.root(children: [selectedDirectory])],
            childrenByDirectory: [2: []],
            pages: [
                .init(directoryId: 1, page: 1, search: ""): .empty,
                .init(directoryId: 2, page: 1, search: ""): DrivePage(records: [firstFile, failedFile], currentPage: 1, pageSize: 20, totalCount: 2),
            ],
            deleteFileFailures: [102]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        model.toggleSelection(selectedDirectory)

        let deleted = await model.deleteSelected()

        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(model.selectedEntryIDs, [2])
        let deletedDirectories = await repository.deletedDirectories
        XCTAssertTrue(deletedDirectories.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testBatchDownloadGeneratesCollisionFreeDestinationName() async throws {
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "报告.pdf")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [file], currentPage: 1, pageSize: 20, totalCount: 1)]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        model.toggleSelection(file)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try Data().write(to: destinationDirectory.appendingPathComponent("报告.pdf"))

        let downloaded = await model.downloadSelected(to: destinationDirectory)

        XCTAssertEqual(downloaded.map(\.lastPathComponent), ["报告 (1).pdf"])
        let downloads = await transferManager.downloads
        XCTAssertEqual(downloads.first?.destinationURL.lastPathComponent, "报告 (1).pdf")
    }

    // [修改] 断点文件也占用目标名称，不能让新任务覆盖已有下载进度。
    func testBatchDownloadAvoidsExistingPartialFileName() async throws {
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "报告.pdf")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [file], currentPage: 1, pageSize: 20, totalCount: 1)]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        model.toggleSelection(file)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try Data().write(to: destinationDirectory.appendingPathComponent("报告.pdf.part"))

        let downloaded = await model.downloadSelected(to: destinationDirectory)

        XCTAssertEqual(downloaded.map(\.lastPathComponent), ["报告 (1).pdf"])
    }

    // [修改] iOS 文件系统默认不区分大小写，批量下载的大小写同名文件必须提前改名。
    func testBatchDownloadTreatsCaseOnlyNamesAsCollision() async throws {
        let files = [
            DriveFileEntry.file(id: 101, parentId: 1, name: "Report.pdf"),
            DriveFileEntry.file(id: 102, parentId: 1, name: "report.pdf"),
        ]
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: files, currentPage: 1, pageSize: 20, totalCount: 2)]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        files.forEach(model.toggleSelection)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        _ = await model.downloadSelected(to: destinationDirectory)

        let names = Set(await transferManager.downloads.map { $0.destinationURL.lastPathComponent })
        XCTAssertEqual(names, ["Report.pdf", "report (1).pdf"])
    }

    // [修改] 一个目标的断点路径也属于占用项，不能再把另一个文件直接命名为该 `.part` 路径。
    func testBatchDownloadTreatsReservedPartialPathAsCollision() async throws {
        let files = [
            DriveFileEntry.file(id: 101, parentId: 1, name: "archive"),
            DriveFileEntry.file(id: 102, parentId: 1, name: "archive.part"),
        ]
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: files, currentPage: 1, pageSize: 20, totalCount: 2)]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        files.forEach(model.toggleSelection)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        _ = await model.downloadSelected(to: destinationDirectory)

        let names = Set(await transferManager.downloads.map { $0.destinationURL.lastPathComponent })
        XCTAssertEqual(names, ["archive", "archive (1).part"])
    }

    // [修改] 服务端文件名不能通过路径片段把下载写出用户选择的目录。
    func testBatchDownloadSanitizesRemoteFileNameBeforeBuildingDestination() async throws {
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "../报告.pdf")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [file], currentPage: 1, pageSize: 20, totalCount: 1)]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        model.toggleSelection(file)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        _ = await model.downloadSelected(to: destinationDirectory)

        let downloads = await transferManager.downloads
        let destination = try XCTUnwrap(downloads.first?.destinationURL)
        XCTAssertEqual(destination.lastPathComponent, "报告.pdf")
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL, destinationDirectory.standardizedFileURL)
    }

    // [修改] 批量下载必须一次性提交所有任务，不能等前一个完成后才持久化下一个。
    func testBatchDownloadSubmitsEverySelectedFileConcurrently() async throws {
        let files = (1...3).map { index in
            DriveFileEntry.file(id: Int64(100 + index), parentId: 1, name: "文件\(index).bin")
        }
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: files, currentPage: 1, pageSize: 20, totalCount: 3)]
        )
        let transferManager = CoordinatedDriveTransferManager()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        files.forEach(model.toggleSelection)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloadTask = Task { await model.downloadSelected(to: destinationDirectory) }

        try await Task.sleep(for: .milliseconds(80))

        let callCount = await transferManager.callCount
        XCTAssertEqual(callCount, 3)
        await transferManager.finishAll()
        let completed = await downloadTask.value
        XCTAssertEqual(completed.count, 3)
    }

    // [修改] 批量下载执行中再次点击必须被拒绝，不能为同一文件重复创建任务。
    func testBatchDownloadRejectsReentryWhileOperationIsRunning() async throws {
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "报告.pdf")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [file], currentPage: 1, pageSize: 20, totalCount: 1)]
        )
        let transferManager = CoordinatedDriveTransferManager()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        model.toggleSelection(file)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = Task { await model.downloadSelected(to: destination) }
        try await waitForDriveTransferCalls(transferManager, count: 1)

        let second = await model.downloadSelected(to: destination)

        XCTAssertTrue(second.isEmpty)
        XCTAssertTrue(model.isBatchOperating)
        let callCount = await transferManager.callCount
        XCTAssertEqual(callCount, 1)
        await transferManager.finishAll()
        _ = await first.value
        XCTAssertFalse(model.isBatchOperating)
    }

    // [修改] 操作期间后来选择的项目不属于本次快照，完成时不能被旧结果覆盖。
    func testBatchDownloadPreservesSelectionAddedWhileOperationIsRunning() async throws {
        let firstFile = DriveFileEntry.file(id: 101, parentId: 1, name: "一.pdf")
        let secondFile = DriveFileEntry.file(id: 102, parentId: 1, name: "二.pdf")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [firstFile, secondFile], currentPage: 1, pageSize: 20, totalCount: 2)]
        )
        let transferManager = CoordinatedDriveTransferManager()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        model.toggleSelection(firstFile)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let operation = Task { await model.downloadSelected(to: destination) }
        try await waitForDriveTransferCalls(transferManager, count: 1)
        model.toggleSelection(secondFile)

        await transferManager.finishAll()
        _ = await operation.value

        XCTAssertEqual(model.selectedEntryIDs, [102])
    }

    // [修改] 用户取消的下载仍需保留选中，方便重新发起，且取消不显示失败提示。
    func testBatchDownloadKeepsCancelledTargetSelected() async {
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "报告.pdf")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [file], currentPage: 1, pageSize: 20, totalCount: 1)]
        )
        let model = DriveViewModel(repository: repository, transferManager: CancellingDriveTransferManager())
        await model.load()
        model.toggleSelection(file)

        let downloaded = await model.downloadSelected(to: FileManager.default.temporaryDirectory)

        XCTAssertTrue(downloaded.isEmpty)
        XCTAssertEqual(model.selectedEntryIDs, [101])
        XCTAssertNil(model.errorMessage)
    }

    // [修改] 递归读取尚未创建传输任务时失败，只能提示在当前页重试。
    func testBatchDownloadPreparationFailurePointsToCurrentPageRetry() async {
        let directory = DriveFileEntry.directory(id: 2, parentId: 1, name: "资料")
        let failedKey = DriveRepositorySpy.PageKey(directoryId: 2, page: 1, search: "")
        let repository = DriveRepositorySpy(
            roots: [.root(children: [directory])],
            childrenByDirectory: [2: []],
            pages: [.init(directoryId: 1, page: 1, search: ""): .empty],
            listFileFailures: [failedKey: .server("目录读取失败")]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        model.toggleSelection(directory)

        _ = await model.downloadSelected(to: FileManager.default.temporaryDirectory)

        XCTAssertEqual(model.selectedEntryIDs, [2])
        XCTAssertEqual(model.errorMessage, "1 个项目准备下载失败，请在当前页面重试")
        let downloads = await transferManager.downloads
        XCTAssertTrue(downloads.isEmpty)
    }

    // [修改] 批量删除也要拒绝重入，并保留操作过程中后来新增的选择。
    func testBatchDeleteRejectsReentryAndPreservesLaterSelection() async throws {
        let firstFile = DriveFileEntry.file(id: 101, parentId: 1, name: "一.pdf")
        let secondFile = DriveFileEntry.file(id: 102, parentId: 1, name: "二.pdf")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [firstFile, secondFile], currentPage: 1, pageSize: 20, totalCount: 2)],
            deleteFileDelays: [101: .milliseconds(120)]
        )
        let model = DriveViewModel(repository: repository)
        await model.load()
        model.toggleSelection(firstFile)
        let first = Task { await model.deleteSelected() }
        try await waitForDeletedFiles(repository, count: 1)
        model.toggleSelection(secondFile)

        let second = await model.deleteSelected()

        XCTAssertTrue(second.isEmpty)
        let deletedFiles = await repository.deletedFiles
        XCTAssertEqual(deletedFiles, [101])
        _ = await first.value
        XCTAssertEqual(model.selectedEntryIDs, [102])
    }

    func testPreviewUsesTransientTransferCache() async {
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "照片.jpg")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [file], currentPage: 1, pageSize: 20, totalCount: 1)]
        )
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()

        let previewURL = await model.preview(file)

        XCTAssertEqual(previewURL?.lastPathComponent, "preview-101.jpg")
        let previews = await transferManager.previews
        XCTAssertEqual(previews, [101])
    }

    // [修改] “打开”普通文件必须进入下载后 Quick Look，不能和“下载并分享”走同一动作。
    func testDriveOpenPresentationUsesQuickLookForNonMediaFiles() {
        let document = DriveFileEntry.file(id: 101, parentId: 1, name: "产品设计稿.pdf")
        let image = DriveFileEntry.file(id: 102, parentId: 1, name: "照片.jpg")
        let video = DriveFileEntry.file(id: 103, parentId: 1, name: "演示.mov")

        XCTAssertEqual(DriveFileOpenRules.presentation(for: document), .quickLook)
        XCTAssertEqual(DriveFileOpenRules.presentation(for: image), .inlineMedia)
        XCTAssertEqual(DriveFileOpenRules.presentation(for: video), .inlineMedia)
    }

    // [修改] 缩略图失败只能回退文件图标，不能打断主列表并弹出错误。
    func testSilentPreviewFailureDoesNotExposeDriveError() async {
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "照片.jpg")
        let repository = DriveRepositorySpy(
            pages: [.init(directoryId: 1, page: 1, search: ""): DrivePage(records: [file], currentPage: 1, pageSize: 20, totalCount: 1)]
        )
        let model = DriveViewModel(repository: repository, transferManager: FailingPreviewTransferManager())
        await model.load()

        let previewURL = await model.preview(file, reportsError: false)

        XCTAssertNil(previewURL)
        XCTAssertNil(model.errorMessage)
    }

    func testRenameFileCallsRepositoryAndReloadsCurrentDirectory() async throws {
        let repository = DriveRepositorySpy()
        let model = DriveViewModel(repository: repository, transferManager: nil)
        await model.load()
        let file = try XCTUnwrap(model.entries.first(where: \.isFile))

        await model.rename(file, name: "新名称.pdf")

        let renamed = await repository.renamedFiles
        XCTAssertEqual(renamed.first?.0, file.id)
        XCTAssertEqual(renamed.first?.1, "新名称.pdf")
        let listCalls = await repository.listCalls
        XCTAssertGreaterThanOrEqual(listCalls, 2)
    }

    // [修改] 与 macOS 一致：只输入文件主名时保留原扩展名，避免文件类型和预览能力失效。
    func testRenameFilePreservesOriginalExtensionWhenEditedNameOmitsIt() async throws {
        let repository = DriveRepositorySpy()
        let model = DriveViewModel(repository: repository)
        await model.load()
        let file = try XCTUnwrap(model.entries.first(where: \.isFile))

        await model.rename(file, name: "新名称")

        let renamed = await repository.renamedFiles
        XCTAssertEqual(renamed.first?.1, "新名称.pdf")
    }

    // [修改] 用户明确填写新扩展名时不能被原扩展名覆盖。
    func testRenameFileKeepsExplicitReplacementExtension() async throws {
        let repository = DriveRepositorySpy()
        let model = DriveViewModel(repository: repository)
        await model.load()
        let file = try XCTUnwrap(model.entries.first(where: \.isFile))

        await model.rename(file, name: "新名称.docx")

        let renamed = await repository.renamedFiles
        XCTAssertEqual(renamed.first?.1, "新名称.docx")
    }

    // [修改] 文件编辑框隐藏扩展名，文件夹中的点号仍属于原名称。
    func testEditableRenameNameUsesFileStemAndKeepsDirectoryName() {
        let file = DriveFileEntry.file(id: 101, parentId: 1, name: "报告.final.pdf")
        let directory = DriveFileEntry.directory(id: 2, parentId: 1, name: "资料.v2")

        XCTAssertEqual(DriveFileNameRules.editableName(for: file), "报告.final")
        XCTAssertEqual(DriveFileNameRules.editableName(for: directory), "资料.v2")
    }

    // [修改] 用户主动取消系统文件选择器属于正常流程，不能弹出失败提示。
    func testDrivePickerErrorRulesIgnoreUserCancellation() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)

        let message = DrivePickerErrorRules.message(for: error, fallback: "文件选择失败，请重试")

        XCTAssertNil(message)
    }

    // [修改] 文件提供器权限或读取错误必须明确反馈，不能和用户取消一样静默丢弃。
    func testDrivePickerErrorRulesReportRealFailures() {
        let error = NSError(domain: "DrivePickerTests", code: 7)

        let message = DrivePickerErrorRules.message(for: error, fallback: "文件选择失败，请重试")

        XCTAssertEqual(message, "文件选择失败，请重试")
    }

    // [修改] 与 macOS 一致，新建文件夹名称最多 10 个字，超长输入不能发到服务端。
    func testCreateDirectoryRejectsNameLongerThanTenCharacters() async {
        let repository = DriveRepositorySpy()
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.createDirectory(name: "12345678901")

        let created = await repository.createdDirectories
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(model.errorMessage, "文件夹名称最多 10 个字")
    }

    // [修改] 空白文件夹名称必须明确提示，不能关闭弹窗后静默无事发生。
    func testCreateDirectoryReportsBlankName() async {
        let repository = DriveRepositorySpy()
        let model = DriveViewModel(repository: repository)
        await model.load()

        await model.createDirectory(name: "   ")

        let created = await repository.createdDirectories
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(model.errorMessage, "文件夹名称不能为空")
    }

    // [修改] 文件或目录重命名为空时同样要给出明确反馈。
    func testRenameReportsBlankName() async throws {
        let repository = DriveRepositorySpy()
        let model = DriveViewModel(repository: repository)
        await model.load()
        let file = try XCTUnwrap(model.files.first)

        let renamed = await model.rename(file, name: "\n")

        let renameCalls = await repository.renamedFiles
        XCTAssertTrue(renameCalls.isEmpty)
        XCTAssertFalse(renamed)
        XCTAssertEqual(model.errorMessage, "名称不能为空")
    }

    func testUploadUsesCurrentNonRootDirectoryAndRefreshes() async throws {
        let child = DriveFileEntry.directory(id: 2, parentId: 1, name: "上传目录")
        let repository = DriveRepositorySpy(roots: [.root(children: [child])])
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        await model.selectDirectory(id: 2)
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-new.txt")
        try Data("new".utf8).write(to: sourceURL)

        await model.upload(sourceURL: sourceURL)

        let uploads = await transferManager.uploads
        XCTAssertEqual(uploads.first?.targetDirectoryId, 2)
    }

    // [修改] 根目录是虚拟入口，必须在打开文件选择器和任务落盘前阻止上传。
    func testUploadRejectsRootDirectory() async throws {
        let repository = DriveRepositorySpy()
        let transferManager = DriveTransferManagerSpy()
        let model = DriveViewModel(repository: repository, transferManager: transferManager)
        await model.load()
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-new.txt")
        try Data("new".utf8).write(to: sourceURL)

        await model.upload(sourceURL: sourceURL)

        let uploads = await transferManager.uploads
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(model.errorMessage, "根目录不能直接上传，请先进入子文件夹")
    }
}

private actor ThumbnailConcurrencyProbe {
    private var currentConcurrent = 0
    private(set) var maximumConcurrent = 0

    func begin() {
        currentConcurrent += 1
        maximumConcurrent = max(maximumConcurrent, currentConcurrent)
    }

    func end() {
        currentConcurrent -= 1
    }
}

private actor DriveRepositorySpy: DriveRepository {
    enum DeleteOperation: Equatable, Sendable {
        case file(Int64)
        case directory(Int64)
    }

    struct PageKey: Hashable, Sendable {
        let directoryId: Int64
        let page: Int
        let search: String
    }

    struct ListRequest: Equatable, Sendable {
        let directoryId: Int64
        let page: Int
        let pageSize: Int
        let search: String
    }

    private let rootValues: [DriveFileEntry]
    private let childrenByDirectory: [Int64: [DriveFileEntry]]
    private let childrenDelays: [Int64: Duration]
    private let pages: [PageKey: DrivePage]
    private let details: [Int64: DriveFileEntry]
    private let deleteFileFailures: Set<Int64>
    private let listFileFailures: [PageKey: DriveRepositoryError]
    private let deleteFileDelays: [Int64: Duration]
    private(set) var createdDirectories: [(Int64, String)] = []
    private(set) var renamedDirectories: [(Int64, String)] = []
    private(set) var renamedFiles: [(Int64, String)] = []
    private(set) var movedDirectories: [(Int64, Int64)] = []
    private(set) var deletedDirectories: [Int64] = []
    private(set) var deletedFiles: [Int64] = []
    private(set) var deleteOperations: [DeleteOperation] = []
    private(set) var listRequests: [ListRequest] = []
    private(set) var rootCalls = 0
    private(set) var childrenRequests: [Int64] = []

    var listCalls: Int { listRequests.count }

    init(
        roots: [DriveFileEntry] = [.root()],
        childrenByDirectory: [Int64: [DriveFileEntry]] = [:],
        childrenDelays: [Int64: Duration] = [:],
        pages: [PageKey: DrivePage] = [
            .init(directoryId: 1, page: 1, search: ""): DrivePage(
                records: [.file(id: 2, parentId: 1, name: "旧名称.pdf", size: 3)],
                currentPage: 1,
                pageSize: 20,
                totalCount: 1
            )
        ],
        details: [Int64: DriveFileEntry] = [:],
        deleteFileFailures: Set<Int64> = [],
        listFileFailures: [PageKey: DriveRepositoryError] = [:],
        deleteFileDelays: [Int64: Duration] = [:]
    ) {
        self.rootValues = roots
        self.childrenByDirectory = childrenByDirectory
        self.childrenDelays = childrenDelays
        self.pages = pages
        self.details = details
        self.deleteFileFailures = deleteFileFailures
        self.listFileFailures = listFileFailures
        self.deleteFileDelays = deleteFileDelays
    }

    func roots() async throws -> [DriveFileEntry] { rootCalls += 1; return rootValues }
    func directoryChildren(id: Int64) async throws -> [DriveFileEntry] {
        childrenRequests.append(id)
        if let delay = childrenDelays[id] { try await Task.sleep(for: delay) }
        return childrenByDirectory[id] ?? []
    }
    func listFiles(directoryId: Int64, page: Int, pageSize: Int, search: String) async throws -> DrivePage {
        let request = ListRequest(directoryId: directoryId, page: page, pageSize: pageSize, search: search)
        let key = PageKey(directoryId: directoryId, page: page, search: search)
        listRequests.append(request)
        if let failure = listFileFailures[key] { throw failure }
        return pages[key]
            ?? DrivePage(records: [], currentPage: page, pageSize: pageSize, totalCount: 0)
    }
    func createDirectory(parentId: Int64, name: String) async throws { createdDirectories.append((parentId, name)) }
    func renameDirectory(id: Int64, name: String) async throws { renamedDirectories.append((id, name)) }
    func deleteDirectory(id: Int64) async throws {
        deletedDirectories.append(id)
        deleteOperations.append(.directory(id))
    }
    func moveDirectory(id: Int64, targetParentId: Int64) async throws { movedDirectories.append((id, targetParentId)) }
    func fileDetail(id: Int64) async throws -> DriveFileEntry {
        if let detail = details[id] { return detail }
        throw DriveRepositoryError.invalidResponse
    }
    func renameFile(id: Int64, name: String) async throws { renamedFiles.append((id, name)) }
    func deleteFile(id: Int64) async throws {
        deletedFiles.append(id)
        deleteOperations.append(.file(id))
        if let delay = deleteFileDelays[id] { try await Task.sleep(for: delay) }
        if deleteFileFailures.contains(id) { throw DriveRepositoryError.server("删除失败") }
    }
}

// [修改] 下拉刷新测试桩按调用顺序返回目录和分页结果，用于验证原子刷新、失败保留和进行中状态。
private actor DriveRefreshRepositorySpy: DriveRepository {
    struct PageKey: Hashable, Sendable {
        let directoryId: Int64
        let page: Int
        let search: String
    }

    enum ChildrenResponse: Sendable {
        case children([DriveFileEntry], delay: Duration)
        case failure(DriveRepositoryError, delay: Duration)
    }

    enum PageResponse: Sendable {
        case page(DrivePage, delay: Duration)
        case gatedPage(DrivePage, gate: DriveResponseGate)
        case failure(DriveRepositoryError, delay: Duration)
    }

    private let rootValues: [DriveFileEntry]
    private var childrenResponses: [Int64: [ChildrenResponse]]
    private var pageResponses: [PageKey: [PageResponse]]
    private(set) var rootCalls = 0
    private var pageRequestCounts: [PageKey: Int] = [:]

    init(
        roots: [DriveFileEntry],
        childrenResponses: [Int64: [ChildrenResponse]],
        pageResponses: [PageKey: [PageResponse]]
    ) {
        rootValues = roots
        self.childrenResponses = childrenResponses
        self.pageResponses = pageResponses
    }

    func roots() async throws -> [DriveFileEntry] {
        rootCalls += 1
        return rootValues
    }

    func directoryChildren(id: Int64) async throws -> [DriveFileEntry] {
        var queue = childrenResponses[id] ?? []
        let response = queue.isEmpty ? ChildrenResponse.children([], delay: .zero) : queue.removeFirst()
        childrenResponses[id] = queue
        switch response {
        case .children(let children, let delay):
            if delay > .zero { try await Task.sleep(for: delay) }
            return children
        case .failure(let error, let delay):
            if delay > .zero { try await Task.sleep(for: delay) }
            throw error
        }
    }

    func listFiles(directoryId: Int64, page: Int, pageSize: Int, search: String) async throws -> DrivePage {
        let key = PageKey(directoryId: directoryId, page: page, search: search)
        // [修改] 记录分页请求次数，锁定刷新与翻页互斥、切目录后可重新刷新的行为。
        pageRequestCounts[key, default: 0] += 1
        var queue = pageResponses[key] ?? []
        let response = queue.isEmpty
            ? PageResponse.page(DrivePage(records: [], currentPage: page, pageSize: pageSize, totalCount: 0), delay: .zero)
            : queue.removeFirst()
        pageResponses[key] = queue
        switch response {
        case .page(let page, let delay):
            if delay > .zero { try await Task.sleep(for: delay) }
            return page
        case .gatedPage(let page, let gate):
            await gate.wait()
            return page
        case .failure(let error, let delay):
            if delay > .zero { try await Task.sleep(for: delay) }
            throw error
        }
    }

    func pageRequestCount(for key: PageKey) -> Int { pageRequestCounts[key, default: 0] }

    func createDirectory(parentId: Int64, name: String) async throws {}
    func renameDirectory(id: Int64, name: String) async throws {}
    func deleteDirectory(id: Int64) async throws {}
    func moveDirectory(id: Int64, targetParentId: Int64) async throws {}
    func fileDetail(id: Int64) async throws -> DriveFileEntry { throw DriveRepositoryError.invalidResponse }
    func renameFile(id: Int64, name: String) async throws {}
    func deleteFile(id: Int64) async throws {}
}

// [修改] 用显式闸门控制并发请求完成顺序，避免依赖毫秒延迟形成测试假阳性。
private actor DriveResponseGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters { waiter.resume() }
    }
}

@MainActor
private func waitForDriveRefreshRequest(
    _ repository: DriveRefreshRepositorySpy,
    key: DriveRefreshRepositorySpy.PageKey,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await repository.pageRequestCount(for: key) >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DriveRequestTimeout()
}

private actor SequencedDriveRepository: DriveRepository {
    struct PageKey: Hashable, Sendable {
        let directoryId: Int64
        let page: Int
        let search: String
    }

    enum Response: Sendable {
        case page(DrivePage, delay: Duration)
        case failure(RequestResponseError, delay: Duration)
    }

    private let rootValues: [DriveFileEntry]
    private var responses: [PageKey: [Response]]
    private var requestCounts: [PageKey: Int] = [:]

    init(roots: [DriveFileEntry], responses: [PageKey: [Response]]) {
        rootValues = roots
        self.responses = responses
    }

    func roots() async throws -> [DriveFileEntry] { rootValues }

    func listFiles(directoryId: Int64, page: Int, pageSize: Int, search: String) async throws -> DrivePage {
        let key = PageKey(directoryId: directoryId, page: page, search: search)
        requestCounts[key, default: 0] += 1
        var queue = responses[key] ?? []
        let response = queue.isEmpty
            ? Response.page(DrivePage(records: [], currentPage: page, pageSize: pageSize, totalCount: 0), delay: .zero)
            : queue.removeFirst()
        responses[key] = queue
        switch response {
        case .page(let value, let delay):
            if delay > .zero { try await Task.sleep(for: delay) }
            return value
        case .failure(let error, let delay):
            if delay > .zero { try await Task.sleep(for: delay) }
            throw error
        }
    }

    func requestCount(for key: PageKey) -> Int { requestCounts[key, default: 0] }
    func createDirectory(parentId: Int64, name: String) async throws {}
    func renameDirectory(id: Int64, name: String) async throws {}
    func deleteDirectory(id: Int64) async throws {}
    func moveDirectory(id: Int64, targetParentId: Int64) async throws {}
    func fileDetail(id: Int64) async throws -> DriveFileEntry { throw DriveRepositoryError.invalidResponse }
    func renameFile(id: Int64, name: String) async throws {}
    func deleteFile(id: Int64) async throws {}
}

@MainActor
private func waitForDriveRequest(
    _ repository: SequencedDriveRepository,
    key: SequencedDriveRepository.PageKey,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await repository.requestCount(for: key) >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DriveRequestTimeout()
}

private struct DriveRequestTimeout: Error {}

private actor DriveTransferManagerSpy: DriveTransferManaging {
    struct Upload: Equatable { let targetDirectoryId: Int64 }
    struct Download: Equatable { let remoteFileId: Int64; let destinationURL: URL }
    private(set) var uploads: [Upload] = []
    private(set) var downloads: [Download] = []
    private(set) var previews: [Int64] = []

    func upload(sourceURL: URL, targetDirectoryId: Int64, uploadPurpose: String, batchId: String?) async throws -> UploadResult {
        uploads.append(Upload(targetDirectoryId: targetDirectoryId))
        return UploadResult(fileId: 10, uploadedBytes: 3)
    }
    func download(remoteFileId: Int64, fileName: String, fileSize: Int64, destinationURL: URL) async throws -> DownloadResult {
        downloads.append(.init(remoteFileId: remoteFileId, destinationURL: destinationURL))
        return DownloadResult(downloadedBytes: fileSize, destinationURL: destinationURL)
    }

    func previewFile(remoteFileId: Int64, fileName: String, fileSize: Int64) async throws -> URL {
        previews.append(remoteFileId)
        return FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(remoteFileId).jpg")
    }
}

private actor CoordinatedDriveTransferManager: DriveTransferManaging {
    private(set) var callCount = 0
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func upload(sourceURL: URL, targetDirectoryId: Int64, uploadPurpose: String, batchId: String?) async throws -> UploadResult {
        throw DriveRepositoryError.server("unused")
    }

    func download(remoteFileId: Int64, fileName: String, fileSize: Int64, destinationURL: URL) async throws -> DownloadResult {
        callCount += 1
        if !isFinished { await withCheckedContinuation { waiters.append($0) } }
        return DownloadResult(downloadedBytes: fileSize, destinationURL: destinationURL)
    }

    func previewFile(remoteFileId: Int64, fileName: String, fileSize: Int64) async throws -> URL {
        throw DriveRepositoryError.server("unused")
    }

    func finishAll() {
        isFinished = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor CancellingDriveTransferManager: DriveTransferManaging {
    func upload(sourceURL: URL, targetDirectoryId: Int64, uploadPurpose: String, batchId: String?) async throws -> UploadResult {
        throw CancellationError()
    }

    func download(remoteFileId: Int64, fileName: String, fileSize: Int64, destinationURL: URL) async throws -> DownloadResult {
        throw CancellationError()
    }

    func previewFile(remoteFileId: Int64, fileName: String, fileSize: Int64) async throws -> URL {
        throw CancellationError()
    }
}

@MainActor
private final class TestDriveVideoPlayerEngineFactory: DriveVideoPlayerEngineFactory {
    private(set) var requestedURLs: [URL] = []
    private(set) var engines: [TestDriveVideoPlayerEngine] = []

    func makeEngine(url: URL) throws -> any DriveVideoPlayerEngine {
        requestedURLs.append(url)
        let engine = TestDriveVideoPlayerEngine()
        engines.append(engine)
        return engine
    }
}

@MainActor
private final class TestDriveVideoPlayerEngine: DriveVideoPlayerEngine {
    struct SeekCall: Equatable {
        let seconds: TimeInterval
        let tolerance: TimeInterval
    }

    var player: AVPlayer? { nil }
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var seekCalls: [SeekCall] = []
    private var eventHandler: ((DriveVideoPlayerEvent) -> Void)?

    func setEventHandler(_ handler: @escaping (DriveVideoPlayerEvent) -> Void) {
        eventHandler = handler
    }

    func play() { playCallCount += 1 }
    func pause() { pauseCallCount += 1 }

    func seek(to seconds: TimeInterval, tolerance: TimeInterval) async {
        seekCalls.append(.init(seconds: seconds, tolerance: tolerance))
    }

    func invalidate() { eventHandler = nil }
    func emit(_ event: DriveVideoPlayerEvent) { eventHandler?(event) }
}

@MainActor
private final class DriveVideoRefreshGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        entered = true
        let currentWaiters = enteredWaiters
        enteredWaiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let currentWaiters = releaseWaiters
        releaseWaiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

@MainActor
private func makeRefreshableVideoController(
    factory: TestDriveVideoPlayerEngineFactory,
    refreshGate: DriveVideoRefreshGate
) -> DriveVideoPlaybackController {
    let initial = MediaPlayback(
        fileId: 101,
        playURL: URL(string: "https://127.0.0.1:10188/media/old.mp4?token=old")!,
        fileSize: 10,
        mimeType: "video/mp4",
        expiresInSeconds: 300
    )
    let refreshed = MediaPlayback(
        fileId: 101,
        playURL: URL(string: "https://127.0.0.1:10188/media/new.mp4?token=new")!,
        fileSize: 10,
        mimeType: "video/mp4",
        expiresInSeconds: 300
    )
    return DriveVideoPlaybackController(
        playback: initial,
        engineFactory: factory,
        refreshPlayback: {
            await refreshGate.waitUntilReleased()
            return refreshed
        }
    )
}

@MainActor
private func waitForVideoEngineCount(
    _ factory: TestDriveVideoPlayerEngineFactory,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if factory.engines.count >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DriveRequestTimeout()
}

@MainActor
private func waitForDriveTransferCalls(
    _ manager: CoordinatedDriveTransferManager,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await manager.callCount >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DriveRequestTimeout()
}

@MainActor
private func waitForDeletedFiles(
    _ repository: DriveRepositorySpy,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await repository.deletedFiles.count >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DriveRequestTimeout()
}

private actor FailingPreviewTransferManager: DriveTransferManaging {
    func upload(sourceURL: URL, targetDirectoryId: Int64, uploadPurpose: String, batchId: String?) async throws -> UploadResult {
        throw DriveRepositoryError.server("上传失败")
    }

    func download(remoteFileId: Int64, fileName: String, fileSize: Int64, destinationURL: URL) async throws -> DownloadResult {
        throw DriveRepositoryError.server("下载失败")
    }

    func previewFile(remoteFileId: Int64, fileName: String, fileSize: Int64) async throws -> URL {
        throw DriveRepositoryError.server("缩略图失败")
    }
}

private actor ThumbnailDriveTransferManagerSpy: DriveTransferManaging {
    struct ThumbnailRequest: Equatable, Sendable {
        let remoteFileId: Int64
        let maximumBytes: Int64
    }

    private let data: Data
    private(set) var thumbnailRequests: [ThumbnailRequest] = []
    private(set) var previewCalls = 0

    init(data: Data) { self.data = data }

    func upload(sourceURL: URL, targetDirectoryId: Int64, uploadPurpose: String, batchId: String?) async throws -> UploadResult {
        throw DriveRepositoryError.server("unused")
    }

    func download(remoteFileId: Int64, fileName: String, fileSize: Int64, destinationURL: URL) async throws -> DownloadResult {
        throw DriveRepositoryError.server("unused")
    }

    func previewFile(remoteFileId: Int64, fileName: String, fileSize: Int64) async throws -> URL {
        previewCalls += 1
        throw DriveRepositoryError.server("不应下载完整预览")
    }

    func thumbnailData(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        maximumBytes: Int64
    ) async throws -> Data {
        thumbnailRequests.append(.init(remoteFileId: remoteFileId, maximumBytes: maximumBytes))
        return data
    }
}

private extension DrivePage {
    static let empty = DrivePage(records: [], currentPage: 1, pageSize: 20, totalCount: 0)
}

private extension DriveFileEntry {
    static func root(children: [DriveFileEntry] = []) -> DriveFileEntry {
        directory(id: 1, parentId: 0, name: "网盘", children: children)
    }

    static func directory(
        id: Int64,
        parentId: Int64,
        name: String,
        children: [DriveFileEntry] = []
    ) -> DriveFileEntry {
        DriveFileEntry(
            id: id,
            parentId: parentId,
            name: name,
            size: nil,
            fileType: "",
            isFile: false,
            hasChildren: !children.isEmpty,
            modifiedAt: nil,
            children: children
        )
    }

    static func file(
        id: Int64,
        parentId: Int64,
        name: String,
        path: String = "",
        size: Int64 = 128,
        modifiedAt: Int64? = nil,
        md5: String? = nil
    ) -> DriveFileEntry {
        DriveFileEntry(
            id: id,
            parentId: parentId,
            name: name,
            path: path,
            size: size,
            fileType: (name as NSString).pathExtension,
            isFile: true,
            hasChildren: false,
            modifiedAt: modifiedAt,
            md5: md5
        )
    }
}
