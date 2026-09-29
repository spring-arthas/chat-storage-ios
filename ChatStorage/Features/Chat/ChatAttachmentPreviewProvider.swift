import Foundation

enum ChatAttachmentPreviewKind: Equatable, Sendable {
    case image
    case video
    case file
}

struct ChatAttachmentPreview: Identifiable, Sendable {
    let attachment: ChatAttachment
    let kind: ChatAttachmentPreviewKind
    let url: URL
    // [修改] 视频预览保留服务端返回的有效期，并提供同文件重新申请播放地址的入口。
    let playback: MediaPlayback?
    let refreshPlayback: (@MainActor @Sendable () async throws -> MediaPlayback)?

    var id: String { "\(attachment.fileId)-\(kind)" }

    init(
        attachment: ChatAttachment,
        kind: ChatAttachmentPreviewKind,
        url: URL,
        playback: MediaPlayback? = nil,
        refreshPlayback: (@MainActor @Sendable () async throws -> MediaPlayback)? = nil
    ) {
        self.attachment = attachment
        self.kind = kind
        self.url = url
        self.playback = playback
        self.refreshPlayback = refreshPlayback
    }
}

enum ChatAttachmentPreviewError: Error, LocalizedError, Sendable {
    case invalidFile
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .invalidFile: "附件信息无效"
        case .incompleteDownload: "附件下载不完整，请重试"
        }
    }
}

protocol ChatAttachmentPreviewProviding: Sendable {
    // [修改] ownerUsername 为附件归属者（如动态作者）的用户名；nil 时回退为当前登录用户。
    func preview(for attachment: ChatAttachment, ownerUsername: String?) async throws -> ChatAttachmentPreview
    // [修改] 删除动态/消息后清理本地已下载的图片缓存文件，按 fileId 精确匹配。
    func removeCachedFiles(for fileIDs: Set<Int64>) async
}

extension ChatAttachmentPreviewProviding {
    // [修改] 聊天等不区分归属者的调用保持原签名，owner 为空即当前用户。
    func preview(for attachment: ChatAttachment) async throws -> ChatAttachmentPreview {
        try await preview(for: attachment, ownerUsername: nil)
    }
    // [修改] 测试 mock 等无本地文件系统的实现保留空操作默认值，不破坏既有 conformer。
    func removeCachedFiles(for fileIDs: Set<Int64>) async {}
}

actor DefaultChatAttachmentPreviewProvider: ChatAttachmentPreviewProviding {
    private let downloadManager: any FileDownloadManaging
    private let mediaRepository: any MediaPlaybackProviding
    private let username: String
    private let cacheRootURL: URL
    private let fileManager: FileManager
    // [修改] 同一附件的并发打开共享一次下载，避免同时写同一个目标和 part 文件。
    private var inFlightPreviews: [String: Task<ChatAttachmentPreview, Error>] = [:]

    init(
        downloadManager: any FileDownloadManaging,
        mediaRepository: any MediaPlaybackProviding,
        username: String,
        serverScopeID: String,
        userId: Int64,
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.downloadManager = downloadManager
        self.mediaRepository = mediaRepository
        self.username = username
        self.fileManager = fileManager
        let root: URL
        if let cacheRootURL {
            root = cacheRootURL
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            root = caches.appendingPathComponent("ChatStorage/Downloads/ChatAttachments", isDirectory: true)
        }
        // [修改] 附件缓存按服务器和账号分区，相同 fileId 在切服或换号后不会复用旧文件。
        self.cacheRootURL = root
            .appendingPathComponent("Servers", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(serverScopeID), isDirectory: true)
            .appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent("\(userId)-\(Self.safePathComponent(username))", isDirectory: true)
    }

    // [修改] 视频直接使用媒体 Range 地址；其余附件先校验本地完整缓存，再决定是否下载。
    // [修改] ownerUsername 指定附件归属者（如动态作者），好友查看他人动态附件时用它申请媒体地址。
    func preview(for attachment: ChatAttachment, ownerUsername: String?) async throws -> ChatAttachmentPreview {
        guard attachment.fileId > 0 else { throw ChatAttachmentPreviewError.invalidFile }
        let identity = Self.nonBlank(ownerUsername) ?? username
        if attachment.isVideo {
            let playback = try await mediaRepository.playback(fileId: attachment.fileId, username: identity)
            let mediaRepository = self.mediaRepository
            let identity = identity
            return ChatAttachmentPreview(
                attachment: attachment,
                kind: .video,
                url: playback.playURL,
                playback: playback,
                refreshPlayback: {
                    try await mediaRepository.playback(fileId: attachment.fileId, username: identity)
                }
            )
        }

        let destination = destinationURL(for: attachment)
        if try isComplete(destination, expectedSize: attachment.fileSize) {
            return localPreview(attachment: attachment, url: destination)
        }

        let key = destination.standardizedFileURL.path
        if let existing = inFlightPreviews[key] {
            return try await existing.value
        }
        let job = Task {
            try await downloadLocalPreview(attachment: attachment, destination: destination, ownerUsername: identity)
        }
        inFlightPreviews[key] = job
        do {
            let preview = try await job.value
            inFlightPreviews.removeValue(forKey: key)
            return preview
        } catch {
            inFlightPreviews.removeValue(forKey: key)
            throw error
        }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // [修改] 动态删除成功后按 fileId 清理本地已下载的图片缓存文件；文件名格式为 "<fileId>-<fileName>"。
    func removeCachedFiles(for fileIDs: Set<Int64>) async {
        guard !fileIDs.isEmpty,
              let entries = try? fileManager.contentsOfDirectory(at: cacheRootURL, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            let filename = entry.lastPathComponent
            guard let dash = filename.firstIndex(of: "-") else { continue }
            guard let fileID = Int64(filename[..<dash]), fileIDs.contains(fileID) else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private func downloadLocalPreview(
        attachment: ChatAttachment,
        destination: URL,
        ownerUsername: String? = nil
    ) async throws -> ChatAttachmentPreview {
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await downloadManager.download(
            remoteFileId: attachment.fileId,
            fileName: attachment.fileName,
            fileSize: attachment.fileSize,
            destinationURL: destination,
            ownerUsername: ownerUsername
        )
        guard try isComplete(destination, expectedSize: attachment.fileSize) else {
            throw ChatAttachmentPreviewError.incompleteDownload
        }
        return localPreview(attachment: attachment, url: destination)
    }

    private func localPreview(attachment: ChatAttachment, url: URL) -> ChatAttachmentPreview {
        ChatAttachmentPreview(
            attachment: attachment,
            kind: attachment.isImage ? .image : .file,
            url: url
        )
    }

    private func destinationURL(for attachment: ChatAttachment) -> URL {
        let safeName = URL(fileURLWithPath: attachment.fileName).lastPathComponent
        let normalizedName = safeName.isEmpty ? "attachment" : safeName
        return cacheRootURL.appendingPathComponent("\(attachment.fileId)-\(normalizedName)")
    }

    private func isComplete(_ url: URL, expectedSize: Int64) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        if expectedSize <= 0 { return true }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? -1) == expectedSize
    }

    private static func safePathComponent(_ value: String) -> String {
        let sanitized = value.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}
