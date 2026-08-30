import Foundation

/// A client-only history entry for a successfully completed download.
/// The remote file is never changed when an entry is removed from this store.
struct DownloadedFileRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let remoteFileId: Int64?
    let fileName: String
    let fileType: String
    let fileSize: Int64
    let destinationPath: String
    let destinationRelativePath: String?
    let destinationDirectoryBookmark: Data?
    let downloadedAt: Int64

    var fileExtension: String {
        let rawType = fileType.split(separator: "/").last.map(String.init) ?? fileType
        let normalized = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.isEmpty { return normalized }
        return (fileName as NSString).pathExtension.lowercased()
    }

    var isImage: Bool {
        ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(fileExtension)
    }

    var isVideo: Bool {
        ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(fileExtension)
    }
}

actor DownloadedFileStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private let attachmentCacheRootURL: URL
    private var records: [String: DownloadedFileRecord]
    private let broadcaster: DownloadedFileHistoryBroadcaster

    init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.attachmentCacheRootURL = caches.appendingPathComponent(
            "ChatStorage/Downloads/ChatAttachments",
            isDirectory: true
        ).standardizedFileURL
        if let data = try? Data(contentsOf: fileURL),
           let values = try? ProtocolJSON.decoder().decode([DownloadedFileRecord].self, from: data) {
            self.records = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        } else {
            self.records = [:]
        }
        self.broadcaster = DownloadedFileHistoryBroadcaster()
    }

    static func serverScoped(
        configuration: ServerConfiguration,
        userId: Int64,
        rootURL: URL? = nil
    ) -> DownloadedFileStore {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChatStorage", isDirectory: true)
        let fileURL = root
            .appendingPathComponent("Servers", isDirectory: true)
            .appendingPathComponent(configuration.storageScopeID, isDirectory: true)
            .appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent(String(userId), isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("history.json")
        return DownloadedFileStore(fileURL: fileURL)
    }

    nonisolated func stream() -> AsyncStream<[DownloadedFileRecord]> {
        broadcaster.stream()
    }

    func all() -> [DownloadedFileRecord] {
        sortedRecords
    }

    /// Resolves the downloaded file and keeps any security-scoped directory access alive.
    /// The returned access object must be retained for as long as the file is being read.
    func fileAccess(for record: DownloadedFileRecord) throws -> TransferScopedURLAccess {
        try TransferDestinationResolver.fileAccess(
            destinationPath: record.destinationPath,
            destinationRelativePath: record.destinationRelativePath,
            bookmarkData: record.destinationDirectoryBookmark
        )
    }

    /// Inserts or replaces the history entry using the transfer task ID as its stable key.
    /// Attachment preview downloads are intentionally excluded because they are disposable caches.
    func record(task: TransferTaskRecord) throws {
        guard task.direction == .download,
              task.status == .completed,
              let destinationPath = task.destinationPath,
              !isAttachmentCachePath(destinationPath) else { return }

        let fileURL = URL(fileURLWithPath: destinationPath)
        let size: Int64
        if task.fileSize > 0 {
            size = task.fileSize
        } else {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            size = Int64(values?.fileSize ?? 0)
        }
        let record = DownloadedFileRecord(
            id: task.id,
            remoteFileId: task.remoteFileId,
            fileName: task.fileName,
            fileType: task.fileType.isEmpty ? fileURL.pathExtension.lowercased() : task.fileType,
            fileSize: max(size, 0),
            destinationPath: destinationPath,
            destinationRelativePath: task.destinationRelativePath,
            destinationDirectoryBookmark: task.destinationDirectoryBookmark,
            downloadedAt: task.updatedAt
        )
        var updated = records
        updated[record.id] = record
        try commit(updated)
    }

    func remove(id: String) throws {
        try remove(ids: [id])
    }

    /// Removes selected history entries and their local files in one client-side commit.
    /// No request is sent to the server because these records belong only to this device.
    func remove(ids: Set<String>) throws {
        let matching = records.values.filter { ids.contains($0.id) }
        guard !matching.isEmpty else { return }
        for record in matching {
            try removeLocalFiles(for: record)
        }
        var updated = records
        matching.forEach { updated.removeValue(forKey: $0.id) }
        try commit(updated)
    }

    func clear() throws {
        guard !records.isEmpty else { return }
        for record in records.values {
            try removeLocalFiles(for: record)
        }
        try commit([:])
    }

    private var sortedRecords: [DownloadedFileRecord] {
        records.values.sorted {
            if $0.downloadedAt == $1.downloadedAt { return $0.id > $1.id }
            return $0.downloadedAt > $1.downloadedAt
        }
    }

    private func isAttachmentCachePath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = attachmentCacheRootURL.path
        return normalized == root || normalized.hasPrefix(root + "/")
    }

    private func removeLocalFiles(for record: DownloadedFileRecord) throws {
        let access = try? fileAccess(for: record)
        let destinationURL = access?.url ?? URL(fileURLWithPath: record.destinationPath)
        for url in [destinationURL, destinationURL.appendingPathExtension("part")] {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private func commit(_ updated: [String: DownloadedFileRecord]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try ProtocolJSON.encoder().encode(Self.sorted(updated))
        try data.write(to: fileURL, options: .atomic)
        records = updated
        broadcaster.yield(Self.sorted(updated))
    }

    private static func sorted(_ values: [String: DownloadedFileRecord]) -> [DownloadedFileRecord] {
        values.values.sorted {
            if $0.downloadedAt == $1.downloadedAt { return $0.id > $1.id }
            return $0.downloadedAt > $1.downloadedAt
        }
    }
}

private final class DownloadedFileHistoryBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[DownloadedFileRecord]>.Continuation] = [:]

    func stream() -> AsyncStream<[DownloadedFileRecord]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
        }
    }

    func yield(_ records: [DownloadedFileRecord]) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(records) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
