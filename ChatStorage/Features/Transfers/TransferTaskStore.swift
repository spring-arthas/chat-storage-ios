import Foundation

enum TransferDirection: String, Codable, Equatable, Sendable {
    case upload
    case download
}

// [修改] 远端文件名只能作为本地文件名，不能携带目录跳转或控制字符影响落盘位置。
enum TransferFileName {
    static func safeLocalName(_ rawValue: String, fallback: String) -> String {
        let normalizedSeparators = rawValue.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = (normalizedSeparators as NSString).lastPathComponent
        let withoutControlCharacters = lastComponent.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutControlCharacters.isEmpty,
              withoutControlCharacters != ".",
              withoutControlCharacters != ".." else {
            return fallback
        }
        return withoutControlCharacters
    }

    // [修改] iOS 数据卷按不区分大小写处理文件名，同时统一 Unicode 组合形式用于防重名。
    static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

enum TransferStatus: String, Codable, Equatable, Hashable, Sendable {
    // 相册大文件在系统导入/本地落盘完成前也必须可见，不能等到真正开始传输才创建任务。
    case preparing
    case queued
    case hashing
    case running
    case paused
    case pausedAuthentication
    case completed
    case failed
    case cancelled

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    var isActive: Bool { !isTerminal }
    // [修改] “进行中”只包含实际排队或执行状态，暂停任务单独分组。
    var isExecuting: Bool { self == .preparing || self == .queued || self == .hashing || self == .running }
}

struct TransferTaskRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let direction: TransferDirection
    var status: TransferStatus
    let sourcePath: String?
    // 网盘相册视频的零副本上传只保存 Photos 资源标识，不在 App 沙盒落盘源文件。
    let photoLibraryAssetIdentifier: String?
    let destinationPath: String?
    // [修改] 外部目录下载必须持久化相对路径，避免恢复后压平子目录并覆盖同名文件。
    let destinationRelativePath: String?
    // [修改] 外部下载目录授权随任务持久化，重启恢复仍能重新进入安全作用域。
    var destinationDirectoryBookmark: Data?
    let fileName: String
    let fileType: String
    var fileSize: Int64
    var remoteFileId: Int64?
    let targetDirectoryId: Int64?
    let uploadPurpose: String?
    let batchId: String?
    // [修改] 旧记录缺少服务器指纹时解码为 nil，并且不会被任何正式 TransferManager 恢复。
    let serverScopeID: String?
    let userId: Int64
    let username: String
    var md5: String?
    var transferredBytes: Int64
    var bytesPerSecond: Double? = nil
    var errorMessage: String?
    let createdAt: Int64
    var updatedAt: Int64

    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(max(Double(transferredBytes) / Double(fileSize), 0), 1)
    }

    init(
        id: String,
        direction: TransferDirection,
        status: TransferStatus,
        sourcePath: String?,
        photoLibraryAssetIdentifier: String? = nil,
        destinationPath: String?,
        destinationRelativePath: String? = nil,
        destinationDirectoryBookmark: Data? = nil,
        fileName: String,
        fileType: String,
        fileSize: Int64,
        remoteFileId: Int64?,
        targetDirectoryId: Int64?,
        uploadPurpose: String?,
        batchId: String?,
        serverScopeID: String? = nil,
        userId: Int64,
        username: String,
        md5: String?,
        transferredBytes: Int64,
        bytesPerSecond: Double? = nil,
        errorMessage: String?,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.direction = direction
        self.status = status
        self.sourcePath = sourcePath
        self.photoLibraryAssetIdentifier = photoLibraryAssetIdentifier
        self.destinationPath = destinationPath
        self.destinationRelativePath = destinationRelativePath
        self.destinationDirectoryBookmark = destinationDirectoryBookmark
        self.fileName = fileName
        self.fileType = fileType
        self.fileSize = fileSize
        self.remoteFileId = remoteFileId
        self.targetDirectoryId = targetDirectoryId
        self.uploadPurpose = uploadPurpose
        self.batchId = batchId
        self.serverScopeID = serverScopeID
        self.userId = userId
        self.username = username
        self.md5 = md5
        self.transferredBytes = transferredBytes
        self.bytesPerSecond = bytesPerSecond
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// [修改] 安全作用域访问对象在预览/分享 sheet 生命周期内持有权限，释放时自动归还。
final class TransferScopedURLAccess: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let refreshedBookmarkData: Data?
    private let scopedRootURL: URL?
    private let retainedAccess: TransferScopedURLAccess?

    init(
        url: URL,
        scopedRootURL: URL?,
        retainedAccess: TransferScopedURLAccess? = nil,
        refreshedBookmarkData: Data? = nil
    ) {
        self.url = url
        self.scopedRootURL = scopedRootURL
        self.retainedAccess = retainedAccess
        self.refreshedBookmarkData = refreshedBookmarkData
    }

    deinit {
        scopedRootURL?.stopAccessingSecurityScopedResource()
    }
}

struct TransferTaskStoreRecoveryNotice: Equatable, Sendable {
    let message: String
    let backupURL: URL?
}

enum TransferTaskStoreError: LocalizedError, Equatable, Sendable {
    case corruptedFileBackupFailed

    var errorDescription: String? {
        switch self {
        case .corruptedFileBackupFailed:
            "传输记录损坏且无法备份，已停止写入以保护原文件"
        }
    }
}

enum TransferDestinationResolver {
    // [修改] iOS 文件提供器目录保存为 bookmark，任务模型不保存任何凭据。
    static func bookmarkData(for directoryURL: URL) throws -> Data {
        try directoryURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func directoryAccess(bookmarkData: Data) throws -> TransferScopedURLAccess {
        var isStale = false
        let directoryURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let scoped = directoryURL.startAccessingSecurityScopedResource()
        do {
            // [修改] 系统报告 bookmark 过期时立即生成新数据，调用方负责写回持久化位置。
            let refreshedBookmark = try refreshedBookmarkData(for: directoryURL, isStale: isStale)
            return TransferScopedURLAccess(
                url: directoryURL,
                scopedRootURL: scoped ? directoryURL : nil,
                refreshedBookmarkData: refreshedBookmark
            )
        } catch {
            if scoped { directoryURL.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    static func refreshedBookmarkData(for directoryURL: URL, isStale: Bool) throws -> Data? {
        guard isStale else { return nil }
        return try bookmarkData(for: directoryURL)
    }

    // [修改] 只允许授权目录内的相对路径，拒绝绝对路径和任何目录跳转。
    static func relativePath(destinationURL: URL, directoryURL: URL) throws -> String {
        // [修改] 目标子目录尚未创建时，先规范化最近存在的父目录，再补回剩余路径。
        let directory = canonicalizedURLAllowingMissingComponents(directoryURL)
        let destination = canonicalizedURLAllowingMissingComponents(destinationURL)
        let directoryComponents = directory.pathComponents
        let destinationComponents = destination.pathComponents
        guard destinationComponents.count > directoryComponents.count,
              Array(destinationComponents.prefix(directoryComponents.count)) == directoryComponents else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let relativePath = destinationComponents.dropFirst(directoryComponents.count).joined(separator: "/")
        return try validatedRelativePath(relativePath)
    }

    static func fileAccess(
        destinationPath: String,
        destinationRelativePath: String? = nil,
        bookmarkData: Data?
    ) throws -> TransferScopedURLAccess {
        let originalURL = URL(fileURLWithPath: destinationPath)
        guard let bookmarkData else {
            return TransferScopedURLAccess(url: originalURL, scopedRootURL: nil)
        }
        let directoryAccess = try directoryAccess(bookmarkData: bookmarkData)
        let relativePath = try validatedRelativePath(destinationRelativePath ?? originalURL.lastPathComponent)
        let resolvedFileURL = relativePath.split(separator: "/").reduce(directoryAccess.url) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }
        let canonicalResolvedFileURL = canonicalizedURLAllowingMissingComponents(resolvedFileURL)
        let rootURL = canonicalizedURLAllowingMissingComponents(directoryAccess.url)
        // [修改] 用路径组件验证授权目录边界，避免字符串前缀误接收 sibling 目录。
        let rootComponents = rootURL.pathComponents
        let resolvedComponents = canonicalResolvedFileURL.pathComponents
        guard resolvedComponents.count > rootComponents.count,
              Array(resolvedComponents.prefix(rootComponents.count)) == rootComponents else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return TransferScopedURLAccess(
            // [修改] 规范路径只用于安全边界校验，实际访问继续使用书签恢复出的原始 URL。
            url: resolvedFileURL.standardizedFileURL,
            scopedRootURL: nil,
            retainedAccess: directoryAccess,
            refreshedBookmarkData: directoryAccess.refreshedBookmarkData
        )
    }

    // [修改] resolvingSymlinksInPath 只会规范化已存在的完整路径；下载目标尚不存在时要从最近存在的父目录开始处理。
    private static func canonicalizedURLAllowingMissingComponents(_ url: URL) -> URL {
        var existingAncestor = URL(fileURLWithPath: url.path)
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path) {
            let component = existingAncestor.lastPathComponent
            let parent = existingAncestor.deletingLastPathComponent()
            guard !component.isEmpty, parent.path != existingAncestor.path else { break }
            missingComponents.insert(component, at: 0)
            existingAncestor = parent
        }
        return missingComponents.reduce(existingAncestor.resolvingSymlinksInPath()) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }.standardizedFileURL
    }

    private static func validatedRelativePath(_ rawValue: String) throws -> String {
        let normalized = rawValue.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !(normalized as NSString).isAbsolutePath,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return components.joined(separator: "/")
    }
}

actor FileTransferTaskStore {
    static let shared = FileTransferTaskStore(fileURL: defaultFileURL)

    // [修改] 任务清单按服务器落盘，旧全局 tasks.json 不会被切服后的账号自动恢复。
    static func serverScoped(configuration: ServerConfiguration, rootURL: URL? = nil) -> FileTransferTaskStore {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChatStorage", isDirectory: true)
        let fileURL = root
            .appendingPathComponent("Servers", isDirectory: true)
            .appendingPathComponent(configuration.storageScopeID, isDirectory: true)
            .appendingPathComponent("Transfers", isDirectory: true)
            .appendingPathComponent("tasks.json")
        return FileTransferTaskStore(fileURL: fileURL)
    }

    private let fileURL: URL
    private let broadcaster: TransferTaskBroadcaster
    private var records: [String: TransferTaskRecord]
    private var persistedProgressBytes: [String: Int64]
    private var recoveryNotice: TransferTaskStoreRecoveryNotice?
    private var corruptedFileRequiresBackup: Bool

    init(fileURL: URL) {
        self.fileURL = fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            records = [:]
            recoveryNotice = nil
            corruptedFileRequiresBackup = false
        } else {
            do {
                let data = try Data(contentsOf: fileURL)
                let values = try ProtocolJSON.decoder().decode([TransferTaskRecord].self, from: data)
                // [修改] 历史文件即使出现重复 ID，也按更新时间保留最新记录，避免 Dictionary 初始化崩溃。
                records = Self.latestRecords(values)
                recoveryNotice = nil
                corruptedFileRequiresBackup = false
            } catch {
                records = [:]
                // [修改] 解码失败先移动原文件留存现场，之后的新任务写入全新的 tasks.json。
                if let backupURL = Self.backupCorruptedFile(at: fileURL) {
                    recoveryNotice = TransferTaskStoreRecoveryNotice(
                        message: "传输记录损坏，已备份旧文件并重新建立任务列表",
                        backupURL: backupURL
                    )
                    corruptedFileRequiresBackup = false
                } else {
                    recoveryNotice = TransferTaskStoreRecoveryNotice(
                        message: "传输记录损坏且无法备份，已停止写入以保护原文件",
                        backupURL: nil
                    )
                    corruptedFileRequiresBackup = true
                }
            }
        }
        persistedProgressBytes = Dictionary(uniqueKeysWithValues: records.values.map { ($0.id, $0.transferredBytes) })
        // [修改] 广播流允许多个订阅者同时消费（网盘红点 + 传输中心列表）。
        self.broadcaster = TransferTaskBroadcaster()
    }

    // [修改] 每个订阅者取独立流，避免多消费者共享单个 AsyncStream 互相抢占。
    nonisolated func taskStream() -> AsyncStream<[TransferTaskRecord]> {
        broadcaster.stream()
    }

    func all() -> [TransferTaskRecord] { sortedRecords }

    func task(id: String) -> TransferTaskRecord? { records[id] }

    // [修改] 恢复告警只交给传输中心展示一次，避免每次列表刷新重复弹窗。
    func consumeRecoveryNotice() -> TransferTaskStoreRecoveryNotice? {
        defer { recoveryNotice = nil }
        return recoveryNotice
    }

    // [修改] 任务状态持久化到 Application Support，敏感 token 不属于模型字段。
    func insert(_ task: TransferTaskRecord) throws {
        var updatedRecords = records
        updatedRecords[task.id] = task
        try commit(updatedRecords)
    }

    func setStatus(id: String, status: TransferStatus, errorMessage: String? = nil) throws {
        guard var task = records[id] else { return }
        // [修改] 终态不可被迟到的网络回调重新改写。
        guard !task.status.isTerminal || task.status == status else { return }
        task.status = status
        if status != .running { task.bytesPerSecond = nil }
        task.errorMessage = errorMessage
        task.updatedAt = Self.now
        var updatedRecords = records
        updatedRecords[id] = task
        try commit(updatedRecords)
    }

    // [修改] 状态比较与写入在同一个 store actor 内完成，暂停/取消和完成不会互相覆盖。
    @discardableResult
    func transition(
        id: String,
        to status: TransferStatus,
        allowedFrom: Set<TransferStatus>,
        errorMessage: String? = nil
    ) throws -> Bool {
        guard var task = records[id], allowedFrom.contains(task.status) else { return false }
        task.status = status
        if status != .running { task.bytesPerSecond = nil }
        task.errorMessage = errorMessage
        task.updatedAt = Self.now
        var updatedRecords = records
        updatedRecords[id] = task
        try commit(updatedRecords)
        return true
    }

    // [修改] 首次计算出的 MD5 单独落盘，上传失败或重启后可以直接复用。
    func setMD5(id: String, md5: String) throws {
        guard var task = records[id], task.md5 != md5 else { return }
        task.md5 = md5
        task.updatedAt = Self.now
        var updatedRecords = records
        updatedRecords[id] = task
        try commit(updatedRecords)
    }

    // 相册流式源需先扫描一次才能得到大小和 MD5；两项必须一次提交，避免界面显示互相矛盾的元数据。
    func setPhotoLibraryUploadMetadata(id: String, fileSize: Int64, md5: String) throws {
        guard var task = records[id], task.photoLibraryAssetIdentifier != nil else { return }
        task.fileSize = max(0, fileSize)
        task.md5 = md5
        task.updatedAt = Self.now
        var updatedRecords = records
        updatedRecords[id] = task
        try commit(updatedRecords)
    }

    // 相册导入完成后才知道实际文件大小；同一个已显示的任务随后进入上传队列。
    func finishPreparingUpload(id: String, fileSize: Int64) throws -> TransferTaskRecord? {
        guard var task = records[id], task.direction == .upload, task.status == .preparing else { return nil }
        task.fileSize = max(0, fileSize)
        task.status = .queued
        task.errorMessage = nil
        task.updatedAt = Self.now
        var updatedRecords = records
        updatedRecords[id] = task
        try commit(updatedRecords)
        return task
    }

    // [修改] security-scoped bookmark 过期后写回新授权，保证重启恢复任务仍能访问原目录。
    func setDestinationDirectoryBookmark(id: String, bookmarkData: Data) throws {
        guard var task = records[id], task.destinationDirectoryBookmark != bookmarkData else { return }
        task.destinationDirectoryBookmark = bookmarkData
        task.updatedAt = Self.now
        var updatedRecords = records
        updatedRecords[id] = task
        try commit(updatedRecords)
    }

    func setProgress(
        id: String,
        transferredBytes: Int64,
        totalBytes: Int64? = nil,
        timestamp: Int64? = nil
    ) throws {
        guard var task = records[id] else { return }
        let previousFileSize = task.fileSize
        if let totalBytes, totalBytes > 0 { task.fileSize = totalBytes }
        let normalized = task.fileSize > 0
            ? min(max(transferredBytes, 0), task.fileSize)
            : max(transferredBytes, 0)
        let now = timestamp ?? Self.now
        let previousBytes = task.transferredBytes
        let elapsedMilliseconds = now - task.updatedAt
        if normalized > previousBytes, elapsedMilliseconds > 0 {
            task.bytesPerSecond = Double(normalized - previousBytes) * 1_000 / Double(elapsedMilliseconds)
        }
        task.transferredBytes = normalized
        task.updatedAt = now
        let persistedBytes = persistedProgressBytes[id] ?? 0
        let shouldPersist = task.fileSize != previousFileSize
            || (task.fileSize > 0 && normalized == task.fileSize)
            || abs(normalized - persistedBytes) >= 1_048_576
        if shouldPersist {
            var updatedRecords = records
            updatedRecords[id] = task
            try commit(updatedRecords)
        } else {
            // [修改] 小进度先发布内存状态供 UI 显示速度，磁盘仍按 1MB 阈值节流。
            records[id] = task
            broadcaster.yield(sortedRecords)
        }
    }

    @discardableResult
    func complete(id: String, remoteFileId: Int64?, transferredBytes: Int64) throws -> Bool {
        guard var task = records[id], task.status.isExecuting else { return false }
        task.status = .completed
        task.remoteFileId = remoteFileId ?? task.remoteFileId
        // [修改] 完成帧中的实际字节数是最终真值，覆盖列表阶段可能已经过期的文件大小。
        let completedBytes = max(transferredBytes, 0)
        task.fileSize = completedBytes
        task.transferredBytes = completedBytes
        task.bytesPerSecond = nil
        task.errorMessage = nil
        task.updatedAt = Self.now
        var updatedRecords = records
        updatedRecords[id] = task
        try commit(updatedRecords)
        return true
    }

    func clearCompleted(taskIDs: Set<String>, userId: Int64, serverScopeID: String? = nil) throws {
        // [修改] 只删除「已完成」记录，不误删已取消或其他终态。
        let updatedRecords = records.filter { _, task in
            let ownsServer = serverScopeID == nil || task.serverScopeID == serverScopeID
            let ownsTask = ownsServer && task.userId == userId
            let isRequestedCompleted = taskIDs.contains(task.id) && task.status == .completed
            return !ownsTask || !isRequestedCompleted
        }
        try commit(updatedRecords)
    }

    func publishCurrent() { broadcaster.yield(sortedRecords) }

    private var sortedRecords: [TransferTaskRecord] {
        Self.sorted(records)
    }

    // [修改] 只有磁盘原子写入成功后才替换内存快照，写入失败时 UI 和重启后的状态保持一致。
    private func commit(_ updatedRecords: [String: TransferTaskRecord]) throws {
        try protectCorruptedFileBeforeWrite()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sorted = Self.sorted(updatedRecords)
        let data = try ProtocolJSON.encoder().encode(sorted)
        try data.write(to: fileURL, options: .atomic)
        records = updatedRecords
        persistedProgressBytes = Dictionary(uniqueKeysWithValues: updatedRecords.values.map { ($0.id, $0.transferredBytes) })
        broadcaster.yield(sorted)
    }

    private func protectCorruptedFileBeforeWrite() throws {
        guard corruptedFileRequiresBackup else { return }
        guard let backupURL = Self.backupCorruptedFile(at: fileURL) else {
            throw TransferTaskStoreError.corruptedFileBackupFailed
        }
        corruptedFileRequiresBackup = false
        recoveryNotice = TransferTaskStoreRecoveryNotice(
            message: "传输记录损坏，已备份旧文件并重新建立任务列表",
            backupURL: backupURL
        )
    }

    private static func latestRecords(_ values: [TransferTaskRecord]) -> [String: TransferTaskRecord] {
        values.reduce(into: [:]) { result, task in
            guard let current = result[task.id] else {
                result[task.id] = task
                return
            }
            if task.updatedAt >= current.updatedAt {
                result[task.id] = task
            }
        }
    }

    private static func sorted(_ records: [String: TransferTaskRecord]) -> [TransferTaskRecord] {
        records.values.sorted { lhs, rhs in
            let lhsRank = executionRank(lhs.status)
            let rhsRank = executionRank(rhs.status)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    // [修改] 执行中的任务排在前面，上传中优先于待上传，暂停与终态靠后。
    private static func executionRank(_ status: TransferStatus) -> Int {
        switch status {
        case .running: 0
        case .hashing: 1
        case .preparing: 2
        case .queued: 3
        case .paused, .pausedAuthentication: 4
        case .completed, .failed, .cancelled: 5
        }
    }

    private static func backupCorruptedFile(at fileURL: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let fileExtension = fileURL.pathExtension
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).corrupted-\(UUID().uuidString)\(suffix)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    private static var defaultFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("ChatStorage", isDirectory: true)
            .appendingPathComponent("Transfers", isDirectory: true)
            .appendingPathComponent("tasks.json")
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}

// [修改] 任务清单广播支持多个订阅者（网盘红点 + 传输中心列表），避免 AsyncStream 单消费者互相抢占导致进度假死。
final class TransferTaskBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[TransferTaskRecord]>.Continuation] = [:]

    func stream() -> AsyncStream<[TransferTaskRecord]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
        }
    }

    func yield(_ tasks: [TransferTaskRecord]) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(tasks) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
