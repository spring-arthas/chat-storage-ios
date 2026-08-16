import XCTest
@testable import ChatStorage

@MainActor
final class TransferCenterViewModelTests: XCTestCase {
    func testLoadShowsPersistedTasksAndRetryUsesTaskID() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("transfers.json")
        let store = FileTransferTaskStore(fileURL: fileURL)
        let manager = TransferManagerSpy()
        let task = TransferTaskRecord(
            id: "failed-task",
            direction: .upload,
            status: .failed,
            sourcePath: "/tmp/report.pdf",
            destinationPath: nil,
            fileName: "report.pdf",
            fileType: "pdf",
            fileSize: 10,
            remoteFileId: nil,
            targetDirectoryId: 12,
            uploadPurpose: "CLOUD_FILE",
            batchId: nil,
            userId: 7,
            username: "alice",
            md5: nil,
            transferredBytes: 4,
            bytesPerSecond: nil,
            errorMessage: "网络断开",
            createdAt: 1,
            updatedAt: 2
        )
        try await store.insert(task)
        let model = TransferCenterViewModel(store: store, manager: manager, userId: 7)

        await model.load()
        await model.retry(task)

        XCTAssertEqual(model.tasks, [task])
        let retriedIDs = await manager.retriedIDs
        XCTAssertEqual(retriedIDs, ["failed-task"])
    }

    func testFiltersTasksByDirectionAndStatusAndReportsCounts() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let upload = TransferTaskRecord.fixture(id: "upload-running", direction: .upload, status: .running)
        let download = TransferTaskRecord.fixture(id: "download-complete", direction: .download, status: .completed)
        let failed = TransferTaskRecord.fixture(id: "download-failed", direction: .download, status: .failed)
        try await store.insert(upload)
        try await store.insert(download)
        try await store.insert(failed)
        let model = TransferCenterViewModel(store: store, manager: TransferManagerSpy(), userId: 7)
        await model.load()

        model.directionFilter = .download
        model.statusFilter = .completed

        XCTAssertEqual(model.filteredTasks.map(\.id), ["download-complete"])
        XCTAssertEqual(model.activeCount, 1)
        XCTAssertEqual(model.completedCount, 1)
    }

    // [修改] 暂停任务单独归类，不能继续出现在“进行中”筛选里。
    func testActiveFilterExcludesPausedTasks() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let running = TransferTaskRecord.fixture(id: "running", direction: .upload, status: .running)
        let paused = TransferTaskRecord.fixture(id: "paused", direction: .download, status: .paused)
        try await store.insert(running)
        try await store.insert(paused)
        let model = TransferCenterViewModel(store: store, manager: TransferManagerSpy(), userId: 7)
        await model.load()

        model.statusFilter = .active

        XCTAssertEqual(model.filteredTasks.map(\.id), ["running"])
    }

    func testCancelAndCancelAllDelegateToManager() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let task = TransferTaskRecord.fixture(id: "running", direction: .upload, status: .running)
        try await store.insert(task)
        let manager = TransferManagerSpy()
        let model = TransferCenterViewModel(store: store, manager: manager, userId: 7)
        await model.load()

        await model.cancel(task)
        await model.cancelAll()

        let cancelledIDs = await manager.cancelledIDs
        let cancelAllCount = await manager.cancelAllCount
        XCTAssertEqual(cancelledIDs, ["running"])
        XCTAssertEqual(cancelAllCount, 1)
    }

    // [修改] 完成任务不是可取消任务，即使调用层误触发也不能继续下发取消命令。
    func testCancelIgnoresCompletedTask() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let completed = TransferTaskRecord.fixture(id: "completed", direction: .download, status: .completed)
        try await store.insert(completed)
        let manager = TransferManagerSpy()
        let model = TransferCenterViewModel(store: store, manager: manager, userId: 7)
        await model.load()

        await model.cancel(completed)

        let cancelledIDs = await manager.cancelledIDs
        XCTAssertTrue(cancelledIDs.isEmpty)
    }

    // [修改] 任务文件损坏后的备份结果必须在传输中心明确提示一次。
    func testLoadShowsStoreRecoveryNotice() async throws {
        let fileURL = temporaryTransferStoreURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken-json".utf8).write(to: fileURL)
        let store = FileTransferTaskStore(fileURL: fileURL)
        let model = TransferCenterViewModel(store: store, manager: TransferManagerSpy(), userId: 7)

        await model.load()

        XCTAssertEqual(model.errorMessage, "传输记录损坏，已备份旧文件并重新建立任务列表")
    }

    // [修改] 永久失败任务必须允许用户放弃并转成可清理记录，不能永远卡在传输中心。
    func testFailedTaskCanBeCancelledForLaterCleanup() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let failed = TransferTaskRecord.fixture(id: "failed", direction: .upload, status: .failed)
        let completed = TransferTaskRecord.fixture(id: "completed", direction: .download, status: .completed)
        try await store.insert(failed)
        try await store.insert(completed)
        let manager = TransferManagerSpy()
        let model = TransferCenterViewModel(store: store, manager: manager, userId: 7)
        await model.load()

        XCTAssertTrue(model.canCancel(failed))
        XCTAssertFalse(model.canCancel(completed))
        XCTAssertEqual(model.cancellableCount, 1)
        await model.cancel(failed)

        let cancelledIDs = await manager.cancelledIDs
        XCTAssertEqual(cancelledIDs, ["failed"])
    }

    // [修改] 传输中心只展示当前账号的任务，避免换账号后泄露上一个账号的文件名和进度。
    func testLoadOnlyShowsTasksOwnedByCurrentUser() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let ownTask = TransferTaskRecord.fixture(id: "own", direction: .upload, status: .running, userId: 7, username: "alice")
        let otherTask = TransferTaskRecord.fixture(id: "other", direction: .download, status: .failed, userId: 8, username: "bob")
        try await store.insert(ownTask)
        try await store.insert(otherTask)
        let model = TransferCenterViewModel(store: store, manager: TransferManagerSpy(), userId: 7)

        await model.load()

        XCTAssertEqual(model.tasks, [ownTask])
    }

    // [修改] 传输中心必须同时按服务器和账号过滤。
    func testLoadOnlyShowsTasksOwnedByCurrentServer() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let configuration = try ServerConfiguration(host: "server-a.example")
        let ownTask = TransferTaskRecord.fixture(
            id: "own-server",
            direction: .upload,
            status: .running,
            serverScopeID: configuration.storageScopeID
        )
        let otherTask = TransferTaskRecord.fixture(
            id: "other-server",
            direction: .download,
            status: .failed,
            serverScopeID: try ServerConfiguration(host: "server-b.example").storageScopeID
        )
        try await store.insert(ownTask)
        try await store.insert(otherTask)
        let model = TransferCenterViewModel(
            store: store,
            manager: TransferManagerSpy(),
            userId: 7,
            serverScopeID: configuration.storageScopeID
        )

        await model.load()

        XCTAssertEqual(model.tasks, [ownTask])
    }

    // [修改] 清理记录只能删除当前账号已完成或已取消的任务，其他账号历史必须保留。
    func testClearCompletedOnlyRemovesCurrentUserRecords() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let ownCompleted = TransferTaskRecord.fixture(id: "own-completed", direction: .upload, status: .completed, userId: 7, username: "alice")
        let otherCompleted = TransferTaskRecord.fixture(id: "other-completed", direction: .download, status: .completed, userId: 8, username: "bob")
        try await store.insert(ownCompleted)
        try await store.insert(otherCompleted)
        let manager = TransferManagerSpy()
        let model = TransferCenterViewModel(store: store, manager: manager, userId: 7)

        await model.clearCompleted()

        let remaining = await store.all()
        XCTAssertEqual(remaining, [otherCompleted])
        let cleanupCount = await manager.cleanupCompletedArtifactsCount
        XCTAssertEqual(cleanupCount, 1)
        let cleanedTaskIDs = await manager.cleanedTaskIDs
        XCTAssertEqual(cleanedTaskIDs, [[ownCompleted.id]])
    }

    // [修改] 清理开始后才进入终态的任务不属于本次快照，记录必须留到下一次清理。
    func testClearCompletedDoesNotRemoveTaskThatFinishesDuringCleanup() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryTransferStoreURL())
        let completed = TransferTaskRecord.fixture(id: "already-completed", direction: .upload, status: .completed, userId: 7, username: "alice")
        let running = TransferTaskRecord.fixture(id: "finishes-later", direction: .download, status: .running, userId: 7, username: "alice")
        try await store.insert(completed)
        try await store.insert(running)
        let gate = AsyncCleanupGate()
        let manager = BlockingCleanupTransferManagerSpy(gate: gate)
        let model = TransferCenterViewModel(store: store, manager: manager, userId: 7)
        await model.load()

        let clearing = Task { await model.clearCompleted() }
        await gate.waitUntilEntered()
        try await store.setStatus(id: running.id, status: .completed)
        await gate.release()
        await clearing.value

        let remaining = await store.all()
        XCTAssertEqual(remaining.map(\.id), [running.id])
    }

    // [修改] 上传副本删除失败时不能丢掉任务记录，否则用户再也无法从传输中心重试清理。
    func testClearCompletedKeepsRecordWhenArtifactDeletionFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("sources", isDirectory: true)
        let uploadDirectory = sourceRoot.appendingPathComponent("upload-task", isDirectory: true)
        try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        let uploadSource = uploadDirectory.appendingPathComponent("report.pdf")
        try Data("upload".utf8).write(to: uploadSource)
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let completed = TransferTaskRecord(
            id: "upload-task",
            direction: .upload,
            status: .completed,
            sourcePath: uploadSource.path,
            destinationPath: nil,
            fileName: "report.pdf",
            fileType: "pdf",
            fileSize: 6,
            remoteFileId: 901,
            targetDirectoryId: 12,
            uploadPurpose: "CLOUD_FILE",
            batchId: nil,
            serverScopeID: configuration.storageScopeID,
            userId: 7,
            username: "alice",
            md5: nil,
            transferredBytes: 6,
            errorMessage: nil,
            createdAt: 1,
            updatedAt: 2
        )
        try await store.insert(completed)
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            sourceRootURL: sourceRoot
        )
        let model = TransferCenterViewModel(
            store: store,
            manager: manager,
            userId: 7,
            serverScopeID: configuration.storageScopeID
        )
        await model.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sourceRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceRoot.path) }

        await model.clearCompleted()

        let remaining = await store.all()
        XCTAssertEqual(remaining, [completed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploadDirectory.path))
        XCTAssertEqual(model.errorMessage, "清理传输记录失败")
    }

    private func temporaryTransferStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("transfers.json")
    }
}

private actor TransferManagerSpy: TransferManaging {
    private(set) var retriedIDs: [String] = []
    private(set) var cancelledIDs: [String] = []
    private(set) var cancelAllCount = 0
    private(set) var cleanupCompletedArtifactsCount = 0
    private(set) var cleanedTaskIDs: [Set<String>] = []
    func pause(_ taskId: String) async {}
    func retry(_ taskId: String) async { retriedIDs.append(taskId) }
    func cancel(_ taskId: String) async { cancelledIDs.append(taskId) }
    func cancelAll() async { cancelAllCount += 1 }
    func cleanupCompletedArtifacts(taskIDs: Set<String>) async throws {
        cleanupCompletedArtifactsCount += 1
        cleanedTaskIDs.append(taskIDs)
    }
}

private actor AsyncCleanupGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor BlockingCleanupTransferManagerSpy: TransferManaging {
    let gate: AsyncCleanupGate

    init(gate: AsyncCleanupGate) { self.gate = gate }

    func pause(_ taskId: String) async {}
    func retry(_ taskId: String) async {}
    func cancel(_ taskId: String) async {}
    func cancelAll() async {}
    func cleanupCompletedArtifacts(taskIDs: Set<String>) async throws { await gate.enterAndWait() }
}

private extension TransferTaskRecord {
    static func fixture(
        id: String,
        direction: TransferDirection,
        status: TransferStatus,
        serverScopeID: String? = nil,
        userId: Int64 = 7,
        username: String = "alice"
    ) -> TransferTaskRecord {
        TransferTaskRecord(
            id: id,
            direction: direction,
            status: status,
            sourcePath: direction == .upload ? "/tmp/\(id)" : nil,
            destinationPath: direction == .download ? "/tmp/\(id)" : nil,
            fileName: "\(id).bin",
            fileType: "bin",
            fileSize: 10,
            remoteFileId: direction == .download ? 99 : nil,
            targetDirectoryId: direction == .upload ? 12 : nil,
            uploadPurpose: direction == .upload ? "CLOUD_FILE" : nil,
            batchId: nil,
            serverScopeID: serverScopeID,
            userId: userId,
            username: username,
            md5: nil,
            transferredBytes: status == .completed ? 10 : 4,
            bytesPerSecond: status == .running ? 512 : nil,
            errorMessage: status == .failed ? "失败" : nil,
            createdAt: 1,
            updatedAt: 2
        )
    }
}
