import Foundation
import Network

protocol FileDownloadManaging: Sendable {
    func download(remoteFileId: Int64, fileName: String, fileSize: Int64, destinationURL: URL) async throws -> DownloadResult
}

protocol TransferManaging: Sendable {
    func pause(_ taskId: String) async
    func retry(_ taskId: String) async
    func cancel(_ taskId: String) async
    func cancelAll() async
    func cleanupCompletedArtifacts(taskIDs: Set<String>) async throws
}

struct TransferCompletionEvent: Equatable, Sendable {
    let taskId: String
    let direction: TransferDirection
    let remoteFileId: Int64?
    let destinationPath: String?
}

actor TransferManager {
    nonisolated private let completionBroadcaster = TransferCompletionBroadcaster()

    nonisolated var completionEvents: AsyncStream<TransferCompletionEvent> {
        completionBroadcaster.stream()
    }
    private enum ActiveJob {
        case upload(Task<UploadResult, Error>)
        case download(Task<DownloadResult, Error>)

        func cancel() {
            switch self {
            case .upload(let task): task.cancel()
            case .download(let task): task.cancel()
            }
        }

        func waitForCompletion() async {
            switch self {
            case .upload(let task): _ = await task.result
            case .download(let task): _ = await task.result
            }
        }
    }

    private struct PreviewJob {
        let id: UUID
        let task: Task<URL, Error>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
        var acceptsWaiters: Bool
    }

    private let configuration: ServerConfiguration
    private let credentialStore: TransferCredentialStore
    private let ownerUserId: Int64
    private let store: FileTransferTaskStore
    private let uploadEngine: any FileUploading
    private let downloadEngine: any FileDownloading
    private let rangePullEngine: any FileRangePulling
    private let executionLimiter: TransferExecutionLimiter
    private let networkGate: TransferNetworkGate
    private let managesNetworkMonitor: Bool
    private let sourceRootURL: URL
    private let previewRootURL: URL
    private let previewCacheLimitBytes: Int64
    private var activeJobs: [String: ActiveJob] = [:]
    private var previewJobs: [String: PreviewJob] = [:]
    private var networkMonitor: TransferNetworkPathMonitor?
    // [修改] 下载路径按任务占用，普通下载、恢复下载和防重名下载统一参与冲突判断。
    private var reservedDownloadPathsByTaskID: [String: String] = [:]

    init(
        configuration: ServerConfiguration,
        identity: TransferIdentity,
        credentialStore: TransferCredentialStore? = nil,
        store: FileTransferTaskStore = .shared,
        uploadEngine: any FileUploading = FileUploadEngine(),
        downloadEngine: any FileDownloading = FileDownloadEngine(),
        rangePullEngine: any FileRangePulling = FileRangePullEngine(),
        sourceRootURL: URL? = nil,
        previewRootURL: URL? = nil,
        previewCacheLimitBytes: Int64 = 512 * 1024 * 1024,
        maxConcurrentTransfers: Int = 5,
        wifiOnlyTransfers: Bool = false,
        networkGate: TransferNetworkGate? = nil
    ) {
        self.configuration = configuration
        let credentialStore = credentialStore ?? TransferCredentialStore(identity: identity)
        self.credentialStore = credentialStore
        self.ownerUserId = identity.userId
        self.store = store
        self.uploadEngine = uploadEngine
        self.downloadEngine = downloadEngine
        self.rangePullEngine = rangePullEngine
        executionLimiter = TransferExecutionLimiter(maxConcurrent: maxConcurrentTransfers)
        let resolvedNetworkGate = networkGate ?? TransferNetworkGate(
            wifiOnly: wifiOnlyTransfers,
            isOnWiFi: false
        )
        self.networkGate = resolvedNetworkGate
        managesNetworkMonitor = networkGate == nil
        self.networkMonitor = wifiOnlyTransfers && networkGate == nil
            ? TransferNetworkPathMonitor(gate: resolvedNetworkGate)
            : nil
        if let sourceRootURL {
            self.sourceRootURL = sourceRootURL
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.sourceRootURL = root
                .appendingPathComponent("ChatStorage/Transfers/Sources", isDirectory: true)
                .appendingPathComponent(configuration.storageScopeID, isDirectory: true)
        }
        if let previewRootURL {
            self.previewRootURL = previewRootURL
        } else {
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.previewRootURL = root.appendingPathComponent("ChatStorage/DrivePreviews", isDirectory: true)
        }
        self.previewCacheLimitBytes = max(1, previewCacheLimitBytes)
    }

    // [修改] 设置只约束尚未启动的任务；正在传输的 socket 不会被强制中断。
    func setWifiOnlyTransfers(_ enabled: Bool) async {
        await networkGate.setWifiOnly(enabled)
        guard managesNetworkMonitor else { return }
        if enabled {
            if networkMonitor == nil {
                networkMonitor = TransferNetworkPathMonitor(gate: networkGate)
            }
        } else {
            networkMonitor?.cancel()
            networkMonitor = nil
        }
    }

    // [修改] 先复制到应用目录再上传，确保文件选择器授权结束后仍可断点重试。
    func upload(
        sourceURL: URL,
        targetDirectoryId: Int64,
        uploadPurpose: String = "CLOUD_FILE",
        batchId: String? = nil
    ) async throws -> UploadResult {
        let identity = credentialStore.current()
        let taskId = UUID().uuidString
        let persistedSource = try persistSource(sourceURL, taskId: taskId)
        let record: TransferTaskRecord
        do {
            let values = try persistedSource.resourceValues(forKeys: [.fileSizeKey])
            let now = Self.now
            record = TransferTaskRecord(
                id: taskId,
                direction: .upload,
                status: .queued,
                sourcePath: persistedSource.path,
                destinationPath: nil,
                fileName: persistedSource.lastPathComponent,
                fileType: persistedSource.pathExtension.lowercased(),
                fileSize: Int64(values.fileSize ?? 0),
                remoteFileId: nil,
                targetDirectoryId: targetDirectoryId,
                uploadPurpose: uploadPurpose,
                batchId: batchId,
                serverScopeID: configuration.storageScopeID,
                userId: identity.userId,
                username: identity.username,
                md5: nil,
                transferredBytes: 0,
                errorMessage: nil,
                createdAt: now,
                updatedAt: now
            )
            try await store.insert(record)
        } catch {
            // [修改] 任务记录没有成功落盘时立即删除应用内副本，避免产生无法重试和无法清理的孤儿文件。
            try? removePersistedUploadSource(at: persistedSource)
            throw error
        }
        let job = makeUploadJob(record)
        activeJobs[taskId] = .upload(job)
        do {
            let result = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                Task { await self.pause(taskId) }
            }
            activeJobs.removeValue(forKey: taskId)
            return result
        } catch {
            activeJobs.removeValue(forKey: taskId)
            throw error
        }
    }

    func download(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        destinationURL: URL
    ) async throws -> DownloadResult {
        try await download(
            remoteFileId: remoteFileId,
            fileName: fileName,
            fileSize: fileSize,
            destinationURL: destinationURL,
            destinationDirectoryBookmark: nil
        )
    }

    func download(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        destinationURL: URL,
        destinationDirectoryBookmark: Data?
    ) async throws -> DownloadResult {
        let taskId = UUID().uuidString
        reserveDownloadDestination(destinationURL, for: taskId)
        defer { releaseDownloadDestination(for: taskId) }
        return try await performDownload(
            taskId: taskId,
            remoteFileId: remoteFileId,
            fileName: fileName,
            fileSize: fileSize,
            destinationURL: destinationURL,
            destinationDirectoryBookmark: destinationDirectoryBookmark
        )
    }

    private func performDownload(
        taskId: String,
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        destinationURL: URL,
        destinationDirectoryBookmark: Data? = nil
    ) async throws -> DownloadResult {
        let identity = credentialStore.current()
        let now = Self.now
        var persistedBookmark = destinationDirectoryBookmark
        var destinationRelativePath: String?
        if let destinationDirectoryBookmark {
            // [修改] 任务创建时记录书签根目录内的完整相对路径，重启后恢复同一目录结构。
            let directoryAccess = try TransferDestinationResolver.directoryAccess(bookmarkData: destinationDirectoryBookmark)
            destinationRelativePath = try TransferDestinationResolver.relativePath(
                destinationURL: destinationURL,
                directoryURL: directoryAccess.url
            )
            persistedBookmark = directoryAccess.refreshedBookmarkData ?? destinationDirectoryBookmark
        }
        let record = TransferTaskRecord(
            id: taskId,
            direction: .download,
            status: .queued,
            sourcePath: nil,
            destinationPath: destinationURL.path,
            destinationRelativePath: destinationRelativePath,
            destinationDirectoryBookmark: persistedBookmark,
            fileName: fileName,
            fileType: URL(fileURLWithPath: fileName).pathExtension.lowercased(),
            fileSize: fileSize,
            remoteFileId: remoteFileId,
            targetDirectoryId: nil,
            uploadPurpose: nil,
            batchId: nil,
            serverScopeID: configuration.storageScopeID,
            userId: identity.userId,
            username: identity.username,
            md5: nil,
            transferredBytes: 0,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        try await store.insert(record)
        let job = makeDownloadJob(record)
        activeJobs[taskId] = .download(job)
        do {
            let result = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                Task { await self.pause(taskId) }
            }
            activeJobs.removeValue(forKey: taskId)
            return result
        } catch {
            activeJobs.removeValue(forKey: taskId)
            throw error
        }
    }

    func downloadUnique(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        suggestedDestinationURL: URL
    ) async throws -> DownloadResult {
        try await downloadUnique(
            remoteFileId: remoteFileId,
            fileName: fileName,
            fileSize: fileSize,
            suggestedDestinationURL: suggestedDestinationURL,
            destinationDirectoryBookmark: nil
        )
    }

    func downloadUnique(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        suggestedDestinationURL: URL,
        destinationDirectoryBookmark: Data?
    ) async throws -> DownloadResult {
        let taskId = UUID().uuidString
        let destinationURL = reserveUniqueDownloadDestination(suggestedDestinationURL, for: taskId)
        defer { releaseDownloadDestination(for: taskId) }
        return try await performDownload(
            taskId: taskId,
            remoteFileId: remoteFileId,
            fileName: fileName,
            fileSize: fileSize,
            destinationURL: destinationURL,
            destinationDirectoryBookmark: destinationDirectoryBookmark
        )
    }

    func previewFile(remoteFileId: Int64, fileName: String, fileSize: Int64) async throws -> URL {
        guard remoteFileId > 0 else { throw FileTransferError.invalidFileId }
        // [修改] 预览缓存目录只接受净化后的单个文件名，禁止“..”等路径跳转。
        let safeName = TransferFileName.safeLocalName(fileName, fallback: "file-\(remoteFileId)")
        let scopeDirectory = previewRootURL
            .appendingPathComponent(configuration.storageScopeID, isDirectory: true)
            .appendingPathComponent(String(ownerUserId), isDirectory: true)
        let directory = scopeDirectory
            .appendingPathComponent(String(remoteFileId), isDirectory: true)
        let destinationURL = directory.appendingPathComponent(safeName)
        if Self.isCompletePreview(at: destinationURL, expectedSize: fileSize) {
            // [修改] 命中缓存时刷新访问时间，并顺带收敛旧版本遗留的超限缓存。
            Self.touchPreview(at: destinationURL)
            Self.prunePreviewCache(
                in: scopeDirectory,
                keeping: destinationURL,
                maximumBytes: previewCacheLimitBytes
            )
            return destinationURL
        }

        let key = "\(configuration.storageScopeID):\(ownerUserId):\(remoteFileId):\(safeName)"
        return try await waitForPreview(
            key: key,
            remoteFileId: remoteFileId,
            fileSize: fileSize,
            scopeDirectory: scopeDirectory,
            directory: directory,
            destinationURL: destinationURL
        )
    }

    // [修改] 列表缩略图只拉有限前缀并留在内存，完整原图仅在用户主动预览时下载。
    func thumbnailData(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        maximumBytes: Int64
    ) async throws -> Data {
        guard remoteFileId > 0 else { throw FileTransferError.invalidFileId }
        let requestedLength = fileSize > 0 ? min(fileSize, maximumBytes) : maximumBytes
        guard requestedLength > 0 else {
            throw FileTransferError.invalidResponse("缩略图拉取长度无效")
        }
        let result = try await rangePullEngine.pull(
            command: RangePullCommand(
                configuration: configuration,
                identity: credentialStore.current(),
                taskId: "thumbnail-\(UUID().uuidString)",
                remoteFileId: remoteFileId,
                startOffset: 0,
                length: requestedLength
            )
        )
        guard !result.data.isEmpty else {
            throw FileTransferError.incompleteTransfer(expected: requestedLength, actual: 0)
        }
        return result.data
    }

    // 视频缩略图由 AVFoundation 按需读取文件头、尾部 moov 和首帧字节，
    // 每次只映射为一个有限 range_pull 窗口，绝不回退为整文件下载。
    func thumbnailRangeData(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        startOffset: Int64,
        length: Int64
    ) async throws -> Data {
        guard remoteFileId > 0 else { throw FileTransferError.invalidFileId }
        guard startOffset >= 0, length > 0 else {
            throw FileTransferError.invalidResponse("缩略图拉取范围无效")
        }
        let available = fileSize > 0 ? max(0, fileSize - startOffset) : length
        let requestedLength = min(length, available)
        guard requestedLength > 0 else { return Data() }
        let result = try await rangePullEngine.pull(
            command: RangePullCommand(
                configuration: configuration,
                identity: credentialStore.current(),
                taskId: "video-thumbnail-\(UUID().uuidString)",
                remoteFileId: remoteFileId,
                startOffset: startOffset,
                length: requestedLength
            )
        )
        return result.data
    }

    // [修改] 远端文件重命名或删除后清掉对应完整预览，并取消仍在进行的同文件预览任务。
    func removeCachedFile(remoteFileId: Int64) async {
        let keyPrefix = "\(configuration.storageScopeID):\(ownerUserId):\(remoteFileId):"
        let matchingKeys = previewJobs.keys.filter { $0.hasPrefix(keyPrefix) }
        for key in matchingKeys {
            guard let job = previewJobs.removeValue(forKey: key) else { continue }
            job.task.cancel()
            job.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        let directory = previewRootURL
            .appendingPathComponent(configuration.storageScopeID, isDirectory: true)
            .appendingPathComponent(String(ownerUserId), isDirectory: true)
            .appendingPathComponent(String(remoteFileId), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitForPreview(
        key: String,
        remoteFileId: Int64,
        fileSize: Int64,
        scopeDirectory: URL,
        directory: URL,
        destinationURL: URL
    ) async throws -> URL {
        while let current = previewJobs[key], !current.acceptsWaiters {
            let jobID = current.id
            _ = await current.task.result
            if previewJobs[key]?.id == jobID {
                previewJobs.removeValue(forKey: key)
            }
            try Task.checkCancellation()
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: URL = try await withCheckedThrowingContinuation { continuation in
                registerPreviewWaiter(
                    continuation,
                    waiterID: waiterID,
                    key: key,
                    remoteFileId: remoteFileId,
                    fileSize: fileSize,
                    scopeDirectory: scopeDirectory,
                    directory: directory,
                    destinationURL: destinationURL
                )
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancelPreviewWaiter(key: key, waiterID: waiterID) }
        }
    }

    private func registerPreviewWaiter(
        _ continuation: CheckedContinuation<URL, Error>,
        waiterID: UUID,
        key: String,
        remoteFileId: Int64,
        fileSize: Int64,
        scopeDirectory: URL,
        directory: URL,
        destinationURL: URL
    ) {
        if var existing = previewJobs[key], existing.acceptsWaiters {
            existing.waiters[waiterID] = continuation
            previewJobs[key] = existing
            return
        }

        let jobID = UUID()
        let job = makePreviewJob(
            remoteFileId: remoteFileId,
            fileSize: fileSize,
            scopeDirectory: scopeDirectory,
            directory: directory,
            destinationURL: destinationURL
        )
        previewJobs[key] = PreviewJob(
            id: jobID,
            task: job,
            waiters: [waiterID: continuation],
            acceptsWaiters: true
        )
        Task { [weak self] in
            let result = await job.result
            await self?.finishPreviewJob(key: key, jobID: jobID, result: result)
        }
    }

    private func makePreviewJob(
        remoteFileId: Int64,
        fileSize: Int64,
        scopeDirectory: URL,
        directory: URL,
        destinationURL: URL
    ) -> Task<URL, Error> {
        let configuration = configuration
        let credentialStore = credentialStore
        let ownerUserId = ownerUserId
        let downloadEngine = downloadEngine
        let previewCacheLimitBytes = previewCacheLimitBytes
        let taskId = "preview-\(configuration.storageScopeID)-\(ownerUserId)-\(remoteFileId)"
        return Task<URL, Error> {
            try Task.checkCancellation()
            let identity = credentialStore.current()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            _ = try await downloadEngine.download(
                command: DownloadCommand(
                    configuration: configuration,
                    identity: identity,
                    taskId: taskId,
                    remoteFileId: remoteFileId,
                    expectedFileSize: fileSize
                ),
                destinationURL: destinationURL,
                onProgress: { _ in }
            )
            // [修改] 完整预览落盘后按账号范围做 LRU 淘汰，单个刚打开的文件始终保留。
            Self.touchPreview(at: destinationURL)
            Self.prunePreviewCache(
                in: scopeDirectory,
                keeping: destinationURL,
                maximumBytes: previewCacheLimitBytes
            )
            return destinationURL
        }
    }

    private func cancelPreviewWaiter(key: String, waiterID: UUID) {
        guard var job = previewJobs[key],
              let continuation = job.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            job.acceptsWaiters = false
            job.task.cancel()
        }
        previewJobs[key] = job
    }

    private func finishPreviewJob(key: String, jobID: UUID, result: Result<URL, Error>) {
        guard let job = previewJobs[key], job.id == jobID else { return }
        previewJobs.removeValue(forKey: key)
        job.waiters.values.forEach { $0.resume(with: result) }
    }

    private static func touchPreview(at url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func prunePreviewCache(in directory: URL, keeping protectedURL: URL, maximumBytes: Int64) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var totalBytes: Int64 = 0
        var candidates: [(url: URL, bytes: Int64, modifiedAt: Date)] = []
        let protectedPath = protectedURL.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() != "part",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            totalBytes += bytes
            if url.standardizedFileURL.path != protectedPath {
                candidates.append((url, bytes, values.contentModificationDate ?? .distantPast))
            }
        }

        for candidate in candidates.sorted(by: { $0.modifiedAt < $1.modifiedAt }) where totalBytes > maximumBytes {
            guard (try? fileManager.removeItem(at: candidate.url)) != nil else { continue }
            totalBytes -= candidate.bytes
            let parent = candidate.url.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? fileManager.removeItem(at: parent)
            }
        }
    }

    func pause(_ taskId: String) async {
        guard let record = await store.task(id: taskId), owns(record) else { return }
        // [修改] 先原子持久化用户意图，再取消网络任务，迟到完成回调不能覆盖暂停。
        let changed = (try? await store.transition(
            id: taskId,
            to: .paused,
            allowedFrom: [.queued, .hashing, .running, .failed, .pausedAuthentication]
        )) == true
        if changed || record.status == .paused { activeJobs[taskId]?.cancel() }
    }

    func cancel(_ taskId: String) async {
        guard let record = await store.task(id: taskId), owns(record) else { return }
        // [修改] 取消是终态，重启后不能被自动恢复成排队任务。
        let changed = (try? await store.transition(
            id: taskId,
            to: .cancelled,
            allowedFrom: [.queued, .hashing, .running, .paused, .pausedAuthentication, .failed]
        )) == true
        if changed || record.status == .cancelled { activeJobs[taskId]?.cancel() }
    }

    func cancelAll() async {
        // [修改] 全局任务文件按账号共存，批量操作只能触碰当前登录用户的数据。
        let cancellableTasks = await store.all().filter {
            owns($0) && ($0.status.isActive || $0.status == .failed)
        }
        for task in cancellableTasks { await cancel(task.id) }
    }

    // [修改] 退出登录或切服时先持久化认证暂停，再取消并等待所有传输 socket 结束。
    func shutdown() async {
        // [修改] 手动 paused 必须保持用户意图；只有原本会自动执行的状态才切到等待登录。
        let ownedActiveTasks = await store.all().filter {
            owns($0) && [.queued, .hashing, .running].contains($0.status)
        }
        for task in ownedActiveTasks {
            _ = try? await store.transition(
                id: task.id,
                to: .pausedAuthentication,
                allowedFrom: [.queued, .hashing, .running]
            )
        }

        let jobs = Array(activeJobs.values)
        jobs.forEach { $0.cancel() }
        let previews = Array(previewJobs.values)
        previewJobs.removeAll()
        previews.forEach { preview in
            preview.task.cancel()
            preview.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        for job in jobs { await job.waitForCompletion() }
        for preview in previews { _ = await preview.task.result }
        activeJobs.removeAll()
        reservedDownloadPathsByTaskID.removeAll()
    }

    // [修改] 只清理用户本次确认的终态任务；任一文件删除失败时保留全部记录供重试。
    func cleanupCompletedArtifacts(taskIDs: Set<String>) async throws {
        let completedTasks = await store.all().filter {
            taskIDs.contains($0.id)
                && owns($0)
                && $0.status == .completed
        }
        for task in completedTasks {
            // [修改] 单个任务的残留文件清理失败不影响其他任务，也不阻断记录清理。
            switch task.direction {
            case .upload:
                try? removePersistedUploadSource(for: task)
            case .download:
                try? removePartialDownload(for: task)
            }
        }
    }

    func retry(_ taskId: String) async {
        guard activeJobs[taskId] == nil,
              let record = await store.task(id: taskId),
              owns(record),
              record.status != .completed,
              record.status != .cancelled else { return }
        switch record.direction {
        case .upload:
            let job = makeUploadJob(record)
            activeJobs[taskId] = .upload(job)
            Task { [weak self] in
                _ = await job.result
                await self?.removeActiveJob(taskId)
            }
        case .download:
            if let destinationPath = record.destinationPath {
                // [修改] 恢复任务必须继续原目标，同时在底层创建 part 文件前就占住该路径。
                let destinationURL = (try? TransferDestinationResolver.fileAccess(
                    destinationPath: destinationPath,
                    destinationRelativePath: record.destinationRelativePath,
                    bookmarkData: record.destinationDirectoryBookmark
                ).url) ?? URL(fileURLWithPath: destinationPath)
                reserveDownloadDestination(destinationURL, for: taskId)
            }
            let job = makeDownloadJob(record)
            activeJobs[taskId] = .download(job)
            Task { [weak self] in
                _ = await job.result
                await self?.removeActiveDownloadJob(taskId)
            }
        }
    }

    func reschedulePending() async {
        // [修改] 登录恢复只重启本账号任务，避免使用当前 token 继续其他账号的上传或下载。
        for task in await store.all() where owns(task) && [.queued, .hashing, .running, .pausedAuthentication].contains(task.status) {
            await retry(task.id)
        }
    }

    private func makeUploadJob(_ record: TransferTaskRecord) -> Task<UploadResult, Error> {
        let configuration = configuration
        let credentialStore = credentialStore
        let uploadEngine = uploadEngine
        let store = store
        let executionLimiter = executionLimiter
        let networkGate = networkGate
        let completionBroadcaster = completionBroadcaster
        return Task {
            // [修改] Wi-Fi 门禁放在并发许可之前，蜂窝网络等待任务不会占用 5 个传输名额。
            try await networkGate.waitUntilAllowed()
            return try await executionLimiter.withPermit {
                do {
                    let identity = credentialStore.current()
                    guard let sourcePath = record.sourcePath, let targetDirectoryId = record.targetDirectoryId else {
                        throw FileTransferError.invalidResponse("上传任务缺少本地文件或目标目录")
                    }
                    try await store.transition(
                        id: record.id,
                        to: .hashing,
                        allowedFrom: [.queued, .failed, .paused, .pausedAuthentication, .hashing, .running]
                    )
                    let result = try await uploadEngine.upload(
                        command: UploadCommand(
                            configuration: configuration,
                            identity: identity,
                            taskId: record.id,
                            targetDirectoryId: targetDirectoryId,
                            requestedOffset: record.transferredBytes,
                            knownMD5: record.md5,
                            uploadPurpose: record.uploadPurpose ?? "CLOUD_FILE",
                            batchId: record.batchId
                        ),
                        sourceURL: URL(fileURLWithPath: sourcePath),
                        onMD5Computed: { md5 in
                            // [修改] 先持久化摘要，再把任务切到传输中状态。
                            try await store.setMD5(id: record.id, md5: md5)
                            try await store.transition(id: record.id, to: .running, allowedFrom: [.hashing, .running])
                        },
                        onProgress: { progress in
                            try? await store.setProgress(
                                id: record.id,
                                transferredBytes: progress.transferredBytes,
                                totalBytes: progress.totalBytes
                            )
                        }
                    )
                    let completed = try await store.complete(id: record.id, remoteFileId: result.fileId, transferredBytes: result.uploadedBytes)
                    if completed {
                        completionBroadcaster.yield(.init(
                            taskId: record.id,
                            direction: .upload,
                            remoteFileId: result.fileId,
                            destinationPath: nil
                        ))
                    }
                    return result
                } catch is CancellationError {
                    _ = try? await store.transition(
                        id: record.id,
                        to: .paused,
                        allowedFrom: [.queued, .hashing, .running]
                    )
                    throw CancellationError()
                } catch {
                    _ = try? await store.transition(
                        id: record.id,
                        to: .failed,
                        allowedFrom: [.queued, .failed, .paused, .pausedAuthentication, .hashing, .running],
                        errorMessage: error.localizedDescription
                    )
                    throw error
                }
            }
        }
    }

    private func makeDownloadJob(_ record: TransferTaskRecord) -> Task<DownloadResult, Error> {
        let configuration = configuration
        let credentialStore = credentialStore
        let downloadEngine = downloadEngine
        let store = store
        let executionLimiter = executionLimiter
        let networkGate = networkGate
        let completionBroadcaster = completionBroadcaster
        return Task {
            try await networkGate.waitUntilAllowed()
            return try await executionLimiter.withPermit {
                do {
                    let identity = credentialStore.current()
                    guard let destinationPath = record.destinationPath, let remoteFileId = record.remoteFileId else {
                        throw FileTransferError.invalidResponse("下载任务缺少目标文件或远端文件 ID")
                    }
                    let destinationAccess = try TransferDestinationResolver.fileAccess(
                        destinationPath: destinationPath,
                        destinationRelativePath: record.destinationRelativePath,
                        bookmarkData: record.destinationDirectoryBookmark
                    )
                    if let refreshedBookmark = destinationAccess.refreshedBookmarkData {
                        // [修改] 重启恢复下载时把系统刷新后的目录授权写回任务记录。
                        try await store.setDestinationDirectoryBookmark(
                            id: record.id,
                            bookmarkData: refreshedBookmark
                        )
                    }
                    // [修改] 重启恢复时目标目录可能已被用户删除，先补齐父目录再启动下载。
                    try FileManager.default.createDirectory(
                        at: destinationAccess.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try await store.transition(
                        id: record.id,
                        to: .running,
                        allowedFrom: [.queued, .failed, .paused, .pausedAuthentication, .running]
                    )
                    let result = try await downloadEngine.download(
                        command: DownloadCommand(
                            configuration: configuration,
                            identity: identity,
                            taskId: record.id,
                            remoteFileId: remoteFileId,
                            expectedFileSize: record.fileSize
                        ),
                        destinationURL: destinationAccess.url,
                        onProgress: { progress in
                            try? await store.setProgress(
                                id: record.id,
                                transferredBytes: progress.transferredBytes,
                                totalBytes: progress.totalBytes
                            )
                        }
                    )
                    let completed = try await store.complete(id: record.id, remoteFileId: remoteFileId, transferredBytes: result.downloadedBytes)
                    if completed {
                        completionBroadcaster.yield(.init(
                            taskId: record.id,
                            direction: .download,
                            remoteFileId: remoteFileId,
                            destinationPath: result.destinationURL.path
                        ))
                    }
                    return result
                } catch is CancellationError {
                    _ = try? await store.transition(
                        id: record.id,
                        to: .paused,
                        allowedFrom: [.queued, .hashing, .running]
                    )
                    throw CancellationError()
                } catch {
                    _ = try? await store.transition(
                        id: record.id,
                        to: .failed,
                        allowedFrom: [.queued, .failed, .paused, .pausedAuthentication, .hashing, .running],
                        errorMessage: error.localizedDescription
                    )
                    throw error
                }
            }
        }
    }

    private func persistSource(_ sourceURL: URL, taskId: String) throws -> URL {
        let directory = sourceRootURL.appendingPathComponent(taskId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            // [修改] 文件复制中途失败时清掉已经创建的任务目录。
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func removePersistedUploadSource(for record: TransferTaskRecord) throws {
        guard let sourcePath = record.sourcePath else { return }
        try removePersistedUploadSource(at: URL(fileURLWithPath: sourcePath))
    }

    private func removePersistedUploadSource(at sourceURL: URL) throws {
        let taskDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
        let root = sourceRootURL.standardizedFileURL
        guard taskDirectory.path.hasPrefix(root.path + "/") else { return }
        guard FileManager.default.fileExists(atPath: taskDirectory.path) else { return }
        try FileManager.default.removeItem(at: taskDirectory)
    }

    private func removePartialDownload(for record: TransferTaskRecord) throws {
        guard let destinationPath = record.destinationPath else { return }
        // [修改] 外部目录移动后也按 bookmark 和相对路径定位残留 part 文件。
        let access = try TransferDestinationResolver.fileAccess(
            destinationPath: destinationPath,
            destinationRelativePath: record.destinationRelativePath,
            bookmarkData: record.destinationDirectoryBookmark
        )
        let partURL = access.url.appendingPathExtension("part")
        if FileManager.default.fileExists(atPath: partURL.path) {
            try FileManager.default.removeItem(at: partURL)
        }
    }

    private func removeActiveJob(_ taskId: String) { activeJobs.removeValue(forKey: taskId) }

    private func removeActiveDownloadJob(_ taskId: String) {
        activeJobs.removeValue(forKey: taskId)
        releaseDownloadDestination(for: taskId)
    }

    private func reserveDownloadDestination(_ destinationURL: URL, for taskId: String) {
        reservedDownloadPathsByTaskID[taskId] = destinationURL.standardizedFileURL.path
    }

    private func releaseDownloadDestination(for taskId: String) {
        reservedDownloadPathsByTaskID.removeValue(forKey: taskId)
    }

    private func reserveUniqueDownloadDestination(_ suggestedURL: URL, for taskId: String) -> URL {
        let directory = suggestedURL.deletingLastPathComponent()
        let source = suggestedURL.lastPathComponent as NSString
        let stem = source.deletingPathExtension
        let fileExtension = source.pathExtension
        var candidate = suggestedURL.lastPathComponent
        var index = 1

        func isOccupied(_ fileName: String) -> Bool {
            let url = directory.appendingPathComponent(fileName)
            let path = url.standardizedFileURL.path
            let partPath = url.appendingPathExtension("part").standardizedFileURL.path
            // [修改] 每个活跃目标同时占住正式路径和 `.part` 路径，并忽略大小写差异。
            let reservedKeys = Set(reservedDownloadPathsByTaskID.values.flatMap { reservedPath in
                [
                    TransferFileName.collisionKey(reservedPath),
                    TransferFileName.collisionKey("\(reservedPath).part"),
                ]
            })
            let existingKeys = Set(
                ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                    .map(TransferFileName.collisionKey)
            )
            return reservedKeys.contains(TransferFileName.collisionKey(path))
                || reservedKeys.contains(TransferFileName.collisionKey(partPath))
                || existingKeys.contains(TransferFileName.collisionKey(fileName))
                || existingKeys.contains(TransferFileName.collisionKey("\(fileName).part"))
        }

        while isOccupied(candidate) {
            candidate = fileExtension.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(fileExtension)"
            index += 1
        }
        let destinationURL = directory.appendingPathComponent(candidate)
        reserveDownloadDestination(destinationURL, for: taskId)
        return destinationURL
    }

    private func owns(_ record: TransferTaskRecord) -> Bool {
        record.serverScopeID == configuration.storageScopeID && record.userId == ownerUserId
    }

    private static func isCompletePreview(at url: URL, expectedSize: Int64) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let actualSize = values.fileSize else { return false }
        return expectedSize <= 0 ? actualSize > 0 : Int64(actualSize) == expectedSize
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}

extension TransferManager: TransferManaging {}
extension TransferManager: FileDownloadManaging {}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// [修改] 新建和恢复任务共用同一网络门禁；关闭限制或切回 Wi-Fi 时一次唤醒全部等待任务。
actor TransferNetworkGate {
    private var wifiOnly: Bool
    private var isOnWiFi: Bool
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(wifiOnly: Bool, isOnWiFi: Bool) {
        self.wifiOnly = wifiOnly
        self.isOnWiFi = isOnWiFi
    }

    func setWifiOnly(_ enabled: Bool) {
        wifiOnly = enabled
        resumeWaitersIfAllowed()
    }

    func updatePath(isOnWiFi: Bool) {
        self.isOnWiFi = isOnWiFi
        resumeWaitersIfAllowed()
    }

    func waitUntilAllowed() async throws {
        guard !wifiOnly || isOnWiFi else {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    if !wifiOnly || isOnWiFi {
                        continuation.resume()
                    } else {
                        waiterOrder.append(waiterID)
                        waiters[waiterID] = continuation
                    }
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
            return
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func resumeWaitersIfAllowed() {
        guard !wifiOnly || isOnWiFi else { return }
        let currentOrder = waiterOrder
        waiterOrder.removeAll()
        for waiterID in currentOrder {
            waiters.removeValue(forKey: waiterID)?.resume()
        }
    }
}

// [修改] Network.framework 只把“当前是否为可用 Wi-Fi”事实推给门禁，不参与任何任务状态修改。
private final class TransferNetworkPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.alibaba.chatstorage.transfer-network-\(UUID().uuidString)")

    init(gate: TransferNetworkGate) {
        monitor.pathUpdateHandler = { path in
            let isOnWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { await gate.updatePath(isOnWiFi: isOnWiFi) }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }
}

// [修改] 上传和下载共用全局执行许可，所有任务先落盘，最多 5 个同时占用传输连接。
private actor TransferExecutionLimiter {
    private let maxConcurrent: Int
    private var activeCount = 0
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func withPermit<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiterOrder.append(waiterID)
                waiters[waiterID] = continuation
            }
            do {
                try Task.checkCancellation()
            } catch {
                release()
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while !waiterOrder.isEmpty {
            let waiterID = waiterOrder.removeFirst()
            guard let continuation = waiters.removeValue(forKey: waiterID) else { continue }
            continuation.resume()
            return
        }
        activeCount = max(0, activeCount - 1)
    }
}

// [修改] 传输完成事件支持多个页面同时订阅，上传重试完成后网盘页也能收到刷新信号。
private final class TransferCompletionBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<TransferCompletionEvent>.Continuation] = [:]

    func stream() -> AsyncStream<TransferCompletionEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
        }
    }

    func yield(_ event: TransferCompletionEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(event) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
