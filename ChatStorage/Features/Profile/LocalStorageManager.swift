import Foundation

struct LocalStorageDirectoryUsage: Equatable, Sendable {
    let bytes: Int64
    let fileCount: Int

    static let zero = LocalStorageDirectoryUsage(bytes: 0, fileCount: 0)

    func adding(_ other: LocalStorageDirectoryUsage) -> LocalStorageDirectoryUsage {
        LocalStorageDirectoryUsage(bytes: bytes + other.bytes, fileCount: fileCount + other.fileCount)
    }
}

struct LocalStorageUsage: Equatable, Sendable {
    let driveDownloads: LocalStorageDirectoryUsage
    let chatAttachmentCache: LocalStorageDirectoryUsage
    let drivePreviewCache: LocalStorageDirectoryUsage
    let driveThumbnailCache: LocalStorageDirectoryUsage
    let chatBackgrounds: LocalStorageDirectoryUsage
    let transferSources: LocalStorageDirectoryUsage
    let dynamicDraftMedia: LocalStorageDirectoryUsage
    let outgoingAttachments: LocalStorageDirectoryUsage

    init(
        driveDownloads: LocalStorageDirectoryUsage = .zero,
        chatAttachmentCache: LocalStorageDirectoryUsage = .zero,
        drivePreviewCache: LocalStorageDirectoryUsage = .zero,
        driveThumbnailCache: LocalStorageDirectoryUsage = .zero,
        chatBackgrounds: LocalStorageDirectoryUsage = .zero,
        transferSources: LocalStorageDirectoryUsage = .zero,
        dynamicDraftMedia: LocalStorageDirectoryUsage = .zero,
        outgoingAttachments: LocalStorageDirectoryUsage = .zero
    ) {
        self.driveDownloads = driveDownloads
        self.chatAttachmentCache = chatAttachmentCache
        self.drivePreviewCache = drivePreviewCache
        self.driveThumbnailCache = driveThumbnailCache
        self.chatBackgrounds = chatBackgrounds
        self.transferSources = transferSources
        self.dynamicDraftMedia = dynamicDraftMedia
        self.outgoingAttachments = outgoingAttachments
    }

    // [修改] 兼容原有调用方；新页面使用逐目录明细，不再把所有文件压成三个数字。
    init(downloadBytes: Int64, backgroundBytes: Int64, transferBytes: Int64) {
        self.init(
            driveDownloads: LocalStorageDirectoryUsage(bytes: downloadBytes, fileCount: 0),
            chatBackgrounds: LocalStorageDirectoryUsage(bytes: backgroundBytes, fileCount: 0),
            transferSources: LocalStorageDirectoryUsage(bytes: transferBytes, fileCount: 0)
        )
    }

    static let zero = LocalStorageUsage()
    var downloadBytes: Int64 {
        driveDownloads.bytes + chatAttachmentCache.bytes + drivePreviewCache.bytes + driveThumbnailCache.bytes
    }
    var backgroundBytes: Int64 { chatBackgrounds.bytes }
    var transferBytes: Int64 { transferSources.bytes }
    var totalBytes: Int64 {
        downloadBytes + backgroundBytes + transferBytes + dynamicDraftMedia.bytes + outgoingAttachments.bytes
    }
}

protocol LocalStorageManaging: Sendable {
    func usage() async throws -> LocalStorageUsage
    func clearDownloads() async throws
    func clearChatBackgrounds() async throws
    func clearReclaimableStorage() async throws
}

actor LocalStorageManager: LocalStorageManaging {
    private let fileManager: FileManager
    private let downloadsURL: URL
    private let attachmentDownloadsURL: URL
    private let previewsURL: URL
    private let thumbnailsURL: URL
    private let backgroundsURL: URL
    private let transfersURL: URL
    private let dynamicDraftMediaURL: URL
    private let outgoingAttachmentsURL: URL

    init(
        fileManager: FileManager = .default,
        downloadsURL: URL? = nil,
        attachmentDownloadsURL: URL? = nil,
        previewsURL: URL? = nil,
        thumbnailsURL: URL? = nil,
        backgroundsURL: URL? = nil,
        transfersURL: URL? = nil,
        dynamicDraftMediaURL: URL? = nil,
        outgoingAttachmentsURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // [修改] 网盘正式下载放 Documents，聊天附件仍放 Caches，和各自写入方保持一致。
        self.downloadsURL = downloadsURL ?? documents.appendingPathComponent("ChatStorage/Downloads", isDirectory: true)
        self.attachmentDownloadsURL = attachmentDownloadsURL ?? caches.appendingPathComponent("ChatStorage/Downloads/ChatAttachments", isDirectory: true)
        self.previewsURL = previewsURL ?? caches.appendingPathComponent("ChatStorage/DrivePreviews", isDirectory: true)
        self.thumbnailsURL = thumbnailsURL ?? caches.appendingPathComponent("ChatStorage/DriveThumbnails", isDirectory: true)
        self.backgroundsURL = backgroundsURL ?? support.appendingPathComponent("ChatBackgrounds", isDirectory: true)
        self.transfersURL = transfersURL ?? support.appendingPathComponent("ChatStorage/Transfers/Sources", isDirectory: true)
        self.dynamicDraftMediaURL = dynamicDraftMediaURL ?? support.appendingPathComponent("ChatStorage/DynamicDrafts/Media", isDirectory: true)
        self.outgoingAttachmentsURL = outgoingAttachmentsURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("ChatStorage/OutgoingAttachments", isDirectory: true)
    }

    func usage() async throws -> LocalStorageUsage {
        return LocalStorageUsage(
            driveDownloads: try regularUsage(in: downloadsURL),
            chatAttachmentCache: try regularUsage(in: attachmentDownloadsURL),
            drivePreviewCache: try directoryUsage(previewsURL),
            driveThumbnailCache: try directoryUsage(thumbnailsURL),
            chatBackgrounds: try directoryUsage(backgroundsURL),
            transferSources: try directoryUsage(transfersURL)
                .adding(partialUsage(in: downloadsURL))
                .adding(partialUsage(in: attachmentDownloadsURL)),
            dynamicDraftMedia: try directoryUsage(dynamicDraftMediaURL),
            outgoingAttachments: try directoryUsage(outgoingAttachmentsURL)
        )
    }

    // [修改] 下载、主动预览和列表缩略图都可重建，统一清理；传输中心断点文件继续保留。
    func clearDownloads() async throws {
        // [修改] 下载引擎把续传数据保存在目标文件旁的 .part 文件中，不能整目录删除。
        try removeFiles(in: downloadsURL) { url in
            url.pathExtension.lowercased() != "part"
        }
        try removeFiles(in: attachmentDownloadsURL) { url in
            url.pathExtension.lowercased() != "part"
        }
        try removeDirectory(previewsURL)
        try removeDirectory(thumbnailsURL)
    }

    func clearChatBackgrounds() async throws {
        try removeDirectory(backgroundsURL)
    }

    // [修改] 一键清理只碰可重建文件；动态草稿、待发送附件和断点传输文件用于恢复，不在这里删除。
    func clearReclaimableStorage() async throws {
        try await clearDownloads()
        try await clearChatBackgrounds()
    }

    private func directoryUsage(
        _ directory: URL,
        including shouldInclude: (URL) -> Bool = { _ in true }
    ) throws -> LocalStorageDirectoryUsage {
        guard fileManager.fileExists(atPath: directory.path) else { return .zero }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return .zero }
        var total: Int64 = 0
        var fileCount = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true, shouldInclude(url) {
                total += Int64(values.fileSize ?? 0)
                fileCount += 1
            }
        }
        return LocalStorageDirectoryUsage(bytes: total, fileCount: fileCount)
    }

    private func regularUsage(in directory: URL) throws -> LocalStorageDirectoryUsage {
        try directoryUsage(directory) { url in
            url.pathExtension.lowercased() != "part"
        }
    }

    private func partialUsage(in directory: URL) throws -> LocalStorageDirectoryUsage {
        try directoryUsage(directory) { url in
            url.pathExtension.lowercased() == "part"
        }
    }

    private func removeFiles(in directory: URL, matching shouldRemove: (URL) -> Bool) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var emptyDirectoryCandidates: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true, shouldRemove(url) {
                try fileManager.removeItem(at: url)
            } else if values.isDirectory == true {
                emptyDirectoryCandidates.append(url)
            }
        }

        // [修改] 从最深层向上清掉空目录；只要存在 .part，Downloads 根目录就会保留。
        for candidate in emptyDirectoryCandidates.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            if try fileManager.contentsOfDirectory(atPath: candidate.path).isEmpty {
                try fileManager.removeItem(at: candidate)
            }
        }
        if try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }

    private func removeDirectory(_ directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }
}
