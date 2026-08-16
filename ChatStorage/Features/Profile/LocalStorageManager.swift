import Foundation

struct LocalStorageUsage: Equatable, Sendable {
    let downloadBytes: Int64
    let backgroundBytes: Int64
    let transferBytes: Int64

    static let zero = LocalStorageUsage(downloadBytes: 0, backgroundBytes: 0, transferBytes: 0)
    var totalBytes: Int64 { downloadBytes + backgroundBytes + transferBytes }
}

protocol LocalStorageManaging: Sendable {
    func usage() async throws -> LocalStorageUsage
    func clearDownloads() async throws
    func clearChatBackgrounds() async throws
}

actor LocalStorageManager: LocalStorageManaging {
    private let fileManager: FileManager
    private let downloadsURL: URL
    private let attachmentDownloadsURL: URL
    private let previewsURL: URL
    private let thumbnailsURL: URL
    private let backgroundsURL: URL
    private let transfersURL: URL

    init(
        fileManager: FileManager = .default,
        downloadsURL: URL? = nil,
        attachmentDownloadsURL: URL? = nil,
        previewsURL: URL? = nil,
        thumbnailsURL: URL? = nil,
        backgroundsURL: URL? = nil,
        transfersURL: URL? = nil
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
    }

    func usage() async throws -> LocalStorageUsage {
        let partialDownloadBytes = try partialSize(in: downloadsURL) + partialSize(in: attachmentDownloadsURL)
        return LocalStorageUsage(
            downloadBytes: try regularSize(in: downloadsURL)
                + regularSize(in: attachmentDownloadsURL)
                + directorySize(previewsURL)
                + directorySize(thumbnailsURL),
            backgroundBytes: try directorySize(backgroundsURL),
            transferBytes: try directorySize(transfersURL) + partialDownloadBytes
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

    private func directorySize(
        _ directory: URL,
        including shouldInclude: (URL) -> Bool = { _ in true }
    ) throws -> Int64 {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true, shouldInclude(url) {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func regularSize(in directory: URL) throws -> Int64 {
        try directorySize(directory) { url in
            url.pathExtension.lowercased() != "part"
        }
    }

    private func partialSize(in directory: URL) throws -> Int64 {
        try directorySize(directory) { url in
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
