import XCTest
import UIKit
@testable import ChatStorage

@MainActor
final class ProfileSettingsViewModelTests: XCTestCase {
    func testLocalStorageUsageIncludesDrivePreviewAndThumbnailCaches() async throws {
        let directories = try LocalStorageTestDirectories()
        try directories.write(byteCount: 2, to: directories.downloadsURL, name: "download.bin")
        try directories.write(byteCount: 3, to: directories.previewsURL, name: "preview.bin")
        try directories.write(byteCount: 5, to: directories.thumbnailsURL, name: "thumbnail.jpg")
        let manager = directories.makeManager()

        let usage = try await manager.usage()

        XCTAssertEqual(usage.downloadBytes, 10)
    }

    // [修改] 网盘下载和聊天附件缓存位于两个根目录时，都必须出现在存储统计中。
    func testLocalStorageUsageIncludesChatAttachmentCache() async throws {
        let directories = try LocalStorageTestDirectories()
        try directories.write(byteCount: 2, to: directories.downloadsURL, name: "drive.bin")
        try directories.write(byteCount: 3, to: directories.attachmentsURL, name: "message.jpg")
        let manager = directories.makeManager()

        let usage = try await manager.usage()

        XCTAssertEqual(usage.downloadBytes, 5)
    }

    func testClearDownloadsRemovesDrivePreviewAndThumbnailCaches() async throws {
        let directories = try LocalStorageTestDirectories()
        try directories.write(byteCount: 2, to: directories.downloadsURL, name: "download.bin")
        try directories.write(byteCount: 3, to: directories.previewsURL, name: "preview.bin")
        try directories.write(byteCount: 5, to: directories.thumbnailsURL, name: "thumbnail.jpg")
        let manager = directories.makeManager()

        try await manager.clearDownloads()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.downloadsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.previewsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.thumbnailsURL.path))
    }

    // [修改] 清理可重建缓存时必须保留下载断点，否则暂停任务会从零开始。
    func testClearDownloadsPreservesPartialDownloadFiles() async throws {
        let directories = try LocalStorageTestDirectories()
        try directories.write(byteCount: 2, to: directories.downloadsURL, name: "finished.bin")
        try directories.write(byteCount: 7, to: directories.downloadsURL, name: "paused.bin.part")
        try directories.write(byteCount: 3, to: directories.attachmentsURL, name: "attachment.bin")
        try directories.write(byteCount: 11, to: directories.attachmentsURL, name: "attachment.bin.part")
        let manager = directories.makeManager()

        try await manager.clearDownloads()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.downloadsURL.appendingPathComponent("finished.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directories.downloadsURL.appendingPathComponent("paused.bin.part").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.attachmentsURL.appendingPathComponent("attachment.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directories.attachmentsURL.appendingPathComponent("attachment.bin.part").path))
    }

    // [修改] .part 是断点传输数据，不应显示成可清理的下载缓存。
    func testLocalStorageUsageCountsPartialDownloadsAsTransferBytes() async throws {
        let directories = try LocalStorageTestDirectories()
        try directories.write(byteCount: 2, to: directories.downloadsURL, name: "finished.bin")
        try directories.write(byteCount: 7, to: directories.downloadsURL, name: "paused.bin.part")
        try directories.write(byteCount: 11, to: directories.attachmentsURL, name: "attachment.bin.part")
        try directories.write(byteCount: 3, to: directories.transfersURL, name: "upload-source.bin")
        let manager = directories.makeManager()

        let usage = try await manager.usage()

        XCTAssertEqual(usage.downloadBytes, 2)
        XCTAssertEqual(usage.transferBytes, 21)
    }

    func testLoadReadsNotificationPermissionAndStorageUsage() async {
        let notifications = ProfileNotificationProvider(status: .denied, requestedStatus: .authorized)
        let storage = ProfileStorageManager(usage: LocalStorageUsage(downloadBytes: 8, backgroundBytes: 4, transferBytes: 2))
        let model = ProfileSettingsViewModel(notificationProvider: notifications, storageManager: storage)

        await model.load()

        XCTAssertEqual(model.notificationStatus, .denied)
        XCTAssertEqual(model.storageUsage, LocalStorageUsage(downloadBytes: 8, backgroundBytes: 4, transferBytes: 2))
    }

    func testRequestNotificationPermissionUpdatesStatus() async {
        let notifications = ProfileNotificationProvider(status: .notDetermined, requestedStatus: .authorized)
        let model = ProfileSettingsViewModel(notificationProvider: notifications, storageManager: ProfileStorageManager(usage: .zero))

        await model.requestNotificationPermission()

        XCTAssertEqual(model.notificationStatus, .authorized)
        let requestCount = await notifications.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testIncomingMessageNotificationUsesPreviewAndFriendRoute() async {
        let center = RecordingMessageNotificationCenter()
        let coordinator = MessageNotificationCoordinator(
            center: center,
            routeStore: MessageNotificationRouteStore(),
            previewEnabled: { true }
        )
        let message = ChatMessage(messageId: 41, senderId: 9, receiverId: 7, content: "晚上一起看照片")

        await coordinator.handle(
            .message(message),
            currentUserId: 7,
            currentFriendId: nil,
            friendName: "张三"
        )

        let delivered = await center.requests
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].title, "张三")
        XCTAssertEqual(delivered[0].body, "晚上一起看照片")
        XCTAssertEqual(delivered[0].friendId, 9)
    }

    func testNotificationHidesPreviewWhenPreferenceIsDisabled() async {
        let center = RecordingMessageNotificationCenter()
        let coordinator = MessageNotificationCoordinator(
            center: center,
            routeStore: MessageNotificationRouteStore(),
            previewEnabled: { false }
        )

        await coordinator.handle(
            .message(ChatMessage(messageId: 42, senderId: 9, receiverId: 7, content: "私密内容")),
            currentUserId: 7,
            currentFriendId: nil,
            friendName: "张三"
        )

        let delivered = await center.requests
        XCTAssertEqual(delivered.first?.body, "你收到一条新消息")
        XCTAssertFalse(delivered.first?.body.contains("私密内容") ?? true)
    }

    func testOwnAndActivelyVisibleConversationMessagesDoNotNotify() async {
        let center = RecordingMessageNotificationCenter()
        let coordinator = MessageNotificationCoordinator(
            center: center,
            routeStore: MessageNotificationRouteStore(),
            previewEnabled: { true }
        )

        await coordinator.handle(
            .message(ChatMessage(messageId: 43, senderId: 7, receiverId: 9, content: "我发出的消息")),
            currentUserId: 7,
            currentFriendId: nil,
            friendName: "张三"
        )
        await coordinator.handle(
            .message(ChatMessage(messageId: 44, senderId: 9, receiverId: 7, content: "正在看的会话")),
            currentUserId: 7,
            currentFriendId: 9,
            isMessagesTabActive: true,
            isSceneActive: true,
            friendName: "张三"
        )

        let delivered = await center.requests
        XCTAssertTrue(delivered.isEmpty)
    }

    // [修改] 导航栈保留好友不代表聊天页仍可见；切到网盘/我的后仍要通知。
    func testConversationStillNotifiesWhenMessagesTabIsInactive() async {
        let center = RecordingMessageNotificationCenter()
        let coordinator = MessageNotificationCoordinator(
            center: center,
            routeStore: MessageNotificationRouteStore(),
            previewEnabled: { true }
        )

        await coordinator.handle(
            .message(ChatMessage(messageId: 45, senderId: 9, receiverId: 7, content: "切到网盘后收到")),
            currentUserId: 7,
            currentFriendId: 9,
            isMessagesTabActive: false,
            isSceneActive: true,
            friendName: "张三"
        )

        let delivered = await center.requests
        XCTAssertEqual(delivered.map(\.friendId), [9])
    }

    // [修改] App 退到后台后，即使聊天导航栈还在，也要交给系统通知提醒。
    func testConversationStillNotifiesWhenSceneIsInactive() async {
        let center = RecordingMessageNotificationCenter()
        let coordinator = MessageNotificationCoordinator(
            center: center,
            routeStore: MessageNotificationRouteStore(),
            previewEnabled: { true }
        )

        await coordinator.handle(
            .message(ChatMessage(messageId: 46, senderId: 9, receiverId: 7, content: "后台收到")),
            currentUserId: 7,
            currentFriendId: 9,
            isMessagesTabActive: true,
            isSceneActive: false,
            friendName: "张三"
        )

        let delivered = await center.requests
        XCTAssertEqual(delivered.map(\.friendId), [9])
    }

    func testClearDownloadsRefreshesStorageUsage() async {
        let storage = ProfileStorageManager(usage: LocalStorageUsage(downloadBytes: 10, backgroundBytes: 4, transferBytes: 2))
        let model = ProfileSettingsViewModel(notificationProvider: ProfileNotificationProvider(status: .authorized, requestedStatus: .authorized), storageManager: storage)
        await model.load()

        await model.clearDownloads()

        XCTAssertEqual(model.storageUsage.downloadBytes, 0)
        let clearCount = await storage.clearDownloadsCount
        XCTAssertEqual(clearCount, 1)
    }

    // [修改] 头像缩放和 JPEG 编码由后台处理器完成，最长边不能超过 1024px。
    func testAvatarImageProcessorResizesLargeImageAndEncodesJPEG() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 1024)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        }
        let sourceData = try XCTUnwrap(source.pngData())

        let jpegData = try await ProfileAvatarImageProcessor.prepareJPEG(from: sourceData)
        let processed = try XCTUnwrap(UIImage(data: jpegData))

        XCTAssertEqual(Array(jpegData.prefix(2)), [0xFF, 0xD8])
        XCTAssertLessThanOrEqual(max(processed.size.width, processed.size.height), 1024)
        XCTAssertEqual(processed.size.width / processed.size.height, 2, accuracy: 0.01)
    }
}

private actor RecordingMessageNotificationCenter: MessageNotificationDelivering {
    private(set) var requests: [MessageNotificationRequest] = []

    func deliver(_ request: MessageNotificationRequest) async throws {
        requests.append(request)
    }
}

private struct LocalStorageTestDirectories {
    let rootURL: URL
    let downloadsURL: URL
    let attachmentsURL: URL
    let previewsURL: URL
    let thumbnailsURL: URL
    let backgroundsURL: URL
    let transfersURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        downloadsURL = rootURL.appendingPathComponent("downloads", isDirectory: true)
        attachmentsURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
        previewsURL = rootURL.appendingPathComponent("previews", isDirectory: true)
        thumbnailsURL = rootURL.appendingPathComponent("thumbnails", isDirectory: true)
        backgroundsURL = rootURL.appendingPathComponent("backgrounds", isDirectory: true)
        transfersURL = rootURL.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func makeManager() -> LocalStorageManager {
        LocalStorageManager(
            downloadsURL: downloadsURL,
            attachmentDownloadsURL: attachmentsURL,
            previewsURL: previewsURL,
            thumbnailsURL: thumbnailsURL,
            backgroundsURL: backgroundsURL,
            transfersURL: transfersURL
        )
    }

    func write(byteCount: Int, to directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: byteCount).write(to: directory.appendingPathComponent(name))
    }
}

private actor ProfileNotificationProvider: NotificationPermissionProviding {
    private let initialStatus: NotificationPermissionStatus
    private let requestedStatus: NotificationPermissionStatus
    private(set) var requestCount = 0

    init(status: NotificationPermissionStatus, requestedStatus: NotificationPermissionStatus) {
        initialStatus = status
        self.requestedStatus = requestedStatus
    }

    func status() async -> NotificationPermissionStatus { requestCount == 0 ? initialStatus : requestedStatus }

    func requestAuthorization() async throws -> NotificationPermissionStatus {
        requestCount += 1
        return requestedStatus
    }
}

private actor ProfileStorageManager: LocalStorageManaging {
    private var currentUsage: LocalStorageUsage
    private(set) var clearDownloadsCount = 0

    init(usage: LocalStorageUsage) { currentUsage = usage }

    func usage() async throws -> LocalStorageUsage { currentUsage }

    func clearDownloads() async throws {
        clearDownloadsCount += 1
        currentUsage = LocalStorageUsage(
            downloadBytes: 0,
            backgroundBytes: currentUsage.backgroundBytes,
            transferBytes: currentUsage.transferBytes
        )
    }

    func clearChatBackgrounds() async throws {
        currentUsage = LocalStorageUsage(
            downloadBytes: currentUsage.downloadBytes,
            backgroundBytes: 0,
            transferBytes: currentUsage.transferBytes
        )
    }
}
