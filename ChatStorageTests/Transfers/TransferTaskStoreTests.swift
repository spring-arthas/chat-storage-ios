import XCTest
@testable import ChatStorage

final class TransferTaskStoreTests: XCTestCase {
    // [修改] 历史文件出现重复任务 ID 时必须保留更新时间最新的一条，不能在启动阶段崩溃。
    func testStoreRestoresLatestRecordWhenPersistedFileContainsDuplicateTaskIDs() async throws {
        let fileURL = temporaryStoreURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var older = TransferTaskRecord.fixture(id: "duplicate-task", status: .paused, transferredBytes: 3)
        older.updatedAt = 100
        var newer = older
        newer.status = .failed
        newer.errorMessage = "最新失败原因"
        newer.updatedAt = 200
        let data = try ProtocolJSON.encoder().encode([newer, older])
        try data.write(to: fileURL, options: .atomic)

        let store = FileTransferTaskStore(fileURL: fileURL)

        let restored = await store.all()
        XCTAssertEqual(restored, [newer])
    }

    // [修改] 损坏的任务文件必须先备份再重建，不能在下一次写入时静默覆盖唯一现场。
    func testStoreBacksUpCorruptedFileAndPublishesRecoveryNotice() async throws {
        let fileURL = temporaryStoreURL()
        let corruptedData = Data("not-json".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try corruptedData.write(to: fileURL, options: .atomic)

        let store = FileTransferTaskStore(fileURL: fileURL)

        let notice = await store.consumeRecoveryNotice()
        let backupURL = try XCTUnwrap(notice?.backupURL)
        XCTAssertEqual(notice?.message, "传输记录损坏，已备份旧文件并重新建立任务列表")
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let secondNotice = await store.consumeRecoveryNotice()
        XCTAssertNil(secondNotice)

        let task = TransferTaskRecord.fixture(id: "new-task", status: .paused, transferredBytes: 1)
        try await store.insert(task)
        let restored = FileTransferTaskStore(fileURL: fileURL)
        let restoredTasks = await restored.all()
        XCTAssertEqual(restoredTasks, [task])
    }

    // [修改] 磁盘写入失败时内存状态也必须回滚，避免 UI 显示一个重启后消失的任务。
    func testFailedStoreInsertDoesNotRetainTaskInMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let nonDirectory = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: nonDirectory)
        let store = FileTransferTaskStore(fileURL: nonDirectory.appendingPathComponent("transfers.json"))
        let task = TransferTaskRecord.fixture(id: "failed-insert", status: .queued, transferredBytes: 0)

        do {
            try await store.insert(task)
            XCTFail("任务清单无法创建时应抛出错误")
        } catch {}

        let retainedTasks = await store.all()
        XCTAssertTrue(retainedTasks.isEmpty)
    }

    // [修改] 上传源文件复制成功但任务清单落盘失败时，应用目录不能遗留无法管理的孤儿副本。
    func testUploadRemovesPersistedSourceWhenTaskRecordCannotBeSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("report.pdf")
        try Data("report".utf8).write(to: sourceURL)
        let nonDirectory = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: nonDirectory)
        let store = FileTransferTaskStore(fileURL: nonDirectory.appendingPathComponent("transfers.json"))
        let sourceRoot = root.appendingPathComponent("sources", isDirectory: true)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: SuccessfulUploadEngine(),
            sourceRootURL: sourceRoot
        )

        do {
            _ = try await manager.upload(sourceURL: sourceURL, targetDirectoryId: 12)
            XCTFail("任务清单无法保存时上传应失败")
        } catch {}

        let remaining = (try? FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(remaining.isEmpty)
        let retainedTasks = await store.all()
        XCTAssertTrue(retainedTasks.isEmpty)
    }

    // 数 GB 相册视频在系统导入期间也必须先出现在传输中心；不能等本地文件复制完才落任务。
    func testPhotoLibraryUploadPersistsPreparingTaskBeforeImportAndThenStartsUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedDirectory = root.appendingPathComponent("staged", isDirectory: true)
        let stagedSource = stagedDirectory.appendingPathComponent("clip.mp4")
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        try Data("video-data".utf8).write(to: stagedSource)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let sourceRoot = root.appendingPathComponent("sources", isDirectory: true)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: SuccessfulUploadEngine(),
            sourceRootURL: sourceRoot
        )

        let preparation = try await manager.beginPhotoLibraryUpload(
            fileName: "视频 1.mp4",
            targetDirectoryId: 12
        )

        let preparingTask = await store.task(id: preparation.taskId)
        let preparing = try XCTUnwrap(preparingTask)
        XCTAssertEqual(preparing.status, .preparing)
        XCTAssertEqual(preparing.fileSize, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparing.sourcePath ?? ""))

        try await manager.finishPhotoLibraryUpload(preparation, sourceURL: stagedSource)

        let completed = await waitForTask(id: preparation.taskId, status: .completed, store: store)
        XCTAssertEqual(completed?.fileName, "视频 1.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedSource.path))
    }

    func testPhotoLibraryVideoUploadUsesAssetIdentifierWithoutCreatingSourceCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let sourceRoot = root.appendingPathComponent("sources", isDirectory: true)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: SuccessfulUploadEngine(),
            photoLibraryUploadEngine: SuccessfulPhotoLibraryUploadEngine(),
            sourceRootURL: sourceRoot
        )

        let preparation = try await manager.beginPhotoLibraryUpload(
            fileName: "本地视频.mp4",
            photoLibraryAssetIdentifier: "photo-local-id",
            targetDirectoryId: 12
        )
        let preparingTask = await store.task(id: preparation.taskId)
        let preparing = try XCTUnwrap(preparingTask)
        XCTAssertEqual(preparing.status, .preparing)
        XCTAssertEqual(preparing.photoLibraryAssetIdentifier, "photo-local-id")
        XCTAssertNil(preparing.sourcePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRoot.path))

        try await manager.startPhotoLibraryVideoUpload(preparation)
        let completed = await waitForTask(id: preparation.taskId, status: .completed, store: store)
        XCTAssertEqual(completed?.fileSize, 32 * 1024 * 1024)
        XCTAssertEqual(completed?.md5, "photo-md5")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRoot.path))
    }

    func testUploadShowsServerVerificationAfterLastByteUntilAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = root.appendingPathComponent("clip.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video-data".utf8).write(to: sourceURL)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let engine = FinalizationHoldingUploadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        let upload = Task { try await manager.upload(sourceURL: sourceURL, targetDirectoryId: 12) }
        await engine.waitUntilFinalProgressWasReported()

        let verifying = await waitForOnlyTask(status: .verifying, store: store)
        XCTAssertEqual(verifying?.progress, 1)
        XCTAssertEqual(verifying?.transferredBytes, verifying?.fileSize)

        await engine.acknowledgeCompletion()
        _ = await upload.result
        let completed = await waitForOnlyTask(status: .completed, store: store)
        XCTAssertEqual(completed?.status, .completed)
    }

    // 相册视频同样必须走独立任务和独立上传连接：前五个并发，剩余任务保留在持久队列等待许可。
    func testPhotoLibraryVideoUploadsRunFiveAtOnceAndQueueRemaining() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let engine = LimitedPhotoLibraryUploadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            photoLibraryUploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            maxConcurrentTransfers: 5
        )

        var preparations: [PhotoLibraryUploadPreparation] = []
        for index in 0..<7 {
            preparations.append(try await manager.beginPhotoLibraryUpload(
                fileName: "视频 \(index).mov",
                photoLibraryAssetIdentifier: "photo-\(index)",
                targetDirectoryId: 12
            ))
        }
        for preparation in preparations {
            try await manager.startPhotoLibraryVideoUpload(preparation)
        }

        await engine.waitForCallCount(5)
        try await Task.sleep(for: .milliseconds(80))
        let maximumConcurrent = await engine.maximumConcurrent
        let startedAssetIdentifiers = await engine.startedAssetIdentifiers
        let records = await store.all()
        let queuedCount = records.filter { $0.status == .queued }.count
        let verifyingCount = records.filter { $0.status == .verifying }.count
        XCTAssertEqual(maximumConcurrent, 5)
        XCTAssertEqual(startedAssetIdentifiers, ["photo-0", "photo-1", "photo-2", "photo-3", "photo-4"])
        XCTAssertEqual(queuedCount, 2)
        XCTAssertEqual(verifyingCount, 5)

        await engine.finishAll()
        for preparation in preparations {
            let completed = await waitForTask(id: preparation.taskId, status: .completed, store: store)
            XCTAssertEqual(completed?.status, .completed)
        }
    }

    // [修改] 系统标记 bookmark 过期后必须重新生成可解析的新数据；未过期时不做多余写入。
    func testStaleDestinationBookmarkIsRefreshedForTheSameDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let unchanged = try TransferDestinationResolver.refreshedBookmarkData(for: directory, isStale: false)
        let refreshed = try XCTUnwrap(
            TransferDestinationResolver.refreshedBookmarkData(for: directory, isStale: true)
        )
        let access = try TransferDestinationResolver.directoryAccess(bookmarkData: refreshed)

        XCTAssertNil(unchanged)
        XCTAssertEqual(access.url.standardizedFileURL, directory.standardizedFileURL)
    }

    // [修改] 外部目录书签恢复后必须重建完整相对路径，两个子目录的同名文件不能被压到根目录。
    func testBookmarkedDestinationPreservesNestedRelativePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bookmark = try TransferDestinationResolver.bookmarkData(for: directory)
        let firstDestination = directory
            .appendingPathComponent("资料", isDirectory: true)
            .appendingPathComponent("第一组", isDirectory: true)
            .appendingPathComponent("同名.jpg")
        let secondDestination = directory
            .appendingPathComponent("资料", isDirectory: true)
            .appendingPathComponent("第二组", isDirectory: true)
            .appendingPathComponent("同名.jpg")

        let firstRelativePath = try TransferDestinationResolver.relativePath(
            destinationURL: firstDestination,
            directoryURL: directory
        )
        let secondRelativePath = try TransferDestinationResolver.relativePath(
            destinationURL: secondDestination,
            directoryURL: directory
        )
        let firstAccess = try TransferDestinationResolver.fileAccess(
            destinationPath: firstDestination.path,
            destinationRelativePath: firstRelativePath,
            bookmarkData: bookmark
        )
        let secondAccess = try TransferDestinationResolver.fileAccess(
            destinationPath: secondDestination.path,
            destinationRelativePath: secondRelativePath,
            bookmarkData: bookmark
        )

        XCTAssertEqual(firstAccess.url.standardizedFileURL, firstDestination.standardizedFileURL)
        XCTAssertEqual(secondAccess.url.standardizedFileURL, secondDestination.standardizedFileURL)
        XCTAssertNotEqual(firstAccess.url.standardizedFileURL, secondAccess.url.standardizedFileURL)
    }

    // [修改] 持久化的相对路径不能是绝对路径，也不能通过 .. 逃出用户授权目录。
    func testBookmarkedDestinationRejectsUnsafeRelativePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bookmark = try TransferDestinationResolver.bookmarkData(for: directory)

        XCTAssertThrowsError(try TransferDestinationResolver.fileAccess(
            destinationPath: directory.appendingPathComponent("report.pdf").path,
            destinationRelativePath: "/tmp/report.pdf",
            bookmarkData: bookmark
        ))
        XCTAssertThrowsError(try TransferDestinationResolver.fileAccess(
            destinationPath: directory.appendingPathComponent("report.pdf").path,
            destinationRelativePath: "../report.pdf",
            bookmarkData: bookmark
        ))
    }

    // [修改] 旧任务没有相对路径字段时继续按单文件名恢复，避免升级后历史下载无法打开。
    func testBookmarkedDestinationKeepsLegacyFileNameFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bookmark = try TransferDestinationResolver.bookmarkData(for: directory)
        let oldDestination = directory
            .appendingPathComponent("旧目录", isDirectory: true)
            .appendingPathComponent("report.pdf")

        let access = try TransferDestinationResolver.fileAccess(
            destinationPath: oldDestination.path,
            destinationRelativePath: nil,
            bookmarkData: bookmark
        )

        XCTAssertEqual(access.url.standardizedFileURL, directory.appendingPathComponent("report.pdf").standardizedFileURL)
    }

    // [修改] 恢复下载解析出新 bookmark 后必须写回任务清单，下一次启动继续使用有效授权。
    func testStorePersistsRefreshedDestinationBookmark() async throws {
        let fileURL = temporaryStoreURL()
        let store = FileTransferTaskStore(fileURL: fileURL)
        let original = Data("old-bookmark".utf8)
        let refreshed = Data("new-bookmark".utf8)
        let task = TransferTaskRecord(
            id: "bookmark-task",
            direction: .download,
            status: .paused,
            sourcePath: nil,
            destinationPath: "/tmp/report.pdf",
            destinationDirectoryBookmark: original,
            fileName: "report.pdf",
            fileType: "pdf",
            fileSize: 10,
            remoteFileId: 99,
            targetDirectoryId: nil,
            uploadPurpose: nil,
            batchId: nil,
            userId: 7,
            username: "alice",
            md5: nil,
            transferredBytes: 4,
            errorMessage: nil,
            createdAt: 1,
            updatedAt: 2
        )
        try await store.insert(task)

        try await store.setDestinationDirectoryBookmark(id: task.id, bookmarkData: refreshed)

        let restored = await FileTransferTaskStore(fileURL: fileURL).task(id: task.id)
        XCTAssertEqual(restored?.destinationDirectoryBookmark, refreshed)
    }

    func testStorePersistsAndRestoresTask() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("transfers.json")
        let store = FileTransferTaskStore(fileURL: fileURL)
        let task = TransferTaskRecord.fixture(id: "persisted-task", status: .paused, transferredBytes: 4)

        try await store.insert(task)

        let restored = FileTransferTaskStore(fileURL: fileURL)
        let tasks = await restored.all()
        XCTAssertEqual(tasks, [task])
    }

    func testManagerCompletesUploadAndPersistsRemoteFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = SuccessfulUploadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("report.pdf")
        try Data("1234567890".utf8).write(to: sourceURL)

        let result = try await manager.upload(
            sourceURL: sourceURL,
            targetDirectoryId: 12,
            uploadPurpose: "CLOUD_FILE",
            batchId: nil
        )

        XCTAssertEqual(result.fileId, 901)
        let tasks = await store.all()
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.transferredBytes, 10)
        XCTAssertEqual(task.remoteFileId, 901)
        let persistedData = try Data(contentsOf: root.appendingPathComponent("transfers.json"))
        XCTAssertFalse(String(decoding: persistedData, as: UTF8.self).contains("secret-token"))
    }

    // [修改] 上传完成事件可被网盘页订阅，用于重试成功后的列表刷新。
    func testManagerBroadcastsUploadCompletionEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: SuccessfulUploadEngine(),
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        let eventTask = Task { await firstTransferCompletion(from: manager.completionEvents) }
        let sourceURL = root.appendingPathComponent("event.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("event".utf8).write(to: sourceURL)

        _ = try await manager.upload(sourceURL: sourceURL, targetDirectoryId: 12)

        let event = await eventTask.value
        XCTAssertEqual(event.direction, .upload)
        XCTAssertEqual(event.remoteFileId, 901)
    }

    func testManagerPersistsComputedMD5AndSuppliesItOnRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = RetryingUploadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("large.bin")
        try Data("1234567890".utf8).write(to: sourceURL)

        do {
            _ = try await manager.upload(sourceURL: sourceURL, targetDirectoryId: 12)
            XCTFail("首次上传应模拟失败")
        } catch {}

        // [修改] 摘要必须在网络传输完成前落盘，失败重试时不再扫描大文件。
        let storedTasks = await store.all()
        let failedTask = try XCTUnwrap(storedTasks.first)
        XCTAssertEqual(failedTask.md5, RetryingUploadEngine.digest)

        await manager.retry(failedTask.id)
        let completedTask = await waitForTask(id: failedTask.id, status: .completed, store: store)
        let knownMD5Values = await engine.knownMD5Values

        XCTAssertEqual(completedTask?.status, .completed)
        XCTAssertEqual(knownMD5Values, [nil, RetryingUploadEngine.digest])
    }

    func testPreviewDownloadUsesCacheWithoutCreatingTransferRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = PreviewDownloadEngine(data: Data("image".utf8))
        let previewRoot = root.appendingPathComponent("previews", isDirectory: true)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            previewRootURL: previewRoot
        )

        let first = try await manager.previewFile(remoteFileId: 77, fileName: "photo.jpg", fileSize: 5)
        let second = try await manager.previewFile(remoteFileId: 77, fileName: "photo.jpg", fileSize: 5)

        // [修改] 缩略图/预览走同一下载引擎和断点文件，但不污染用户可见的传输中心。
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("image".utf8))
        let calls = await engine.calls
        let storedTasks = await store.all()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(storedTasks.isEmpty)
    }

    // [修改] 主动预览缓存超过上限时必须淘汰最久未使用文件，不能无限占用磁盘。
    func testPreviewCacheEvictsLeastRecentlyUsedFileWhenOverLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = PreviewDownloadEngine(data: Data("image".utf8))
        let previewRoot = root.appendingPathComponent("previews", isDirectory: true)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            previewRootURL: previewRoot,
            previewCacheLimitBytes: 12
        )

        let first = try await manager.previewFile(remoteFileId: 77, fileName: "first.jpg", fileSize: 5)
        let second = try await manager.previewFile(remoteFileId: 78, fileName: "second.jpg", fileSize: 5)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: second.path
        )
        _ = try await manager.previewFile(remoteFileId: 77, fileName: "first.jpg", fileSize: 5)
        let third = try await manager.previewFile(remoteFileId: 79, fileName: "third.jpg", fileSize: 5)

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.path))
    }

    // [修改] 损坏远端文件名不能让预览缓存逃出对应远端文件目录。
    func testPreviewDownloadSanitizesTraversalOnlyFileName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = PreviewDownloadEngine(data: Data("file".utf8))
        let previewRoot = root.appendingPathComponent("previews", isDirectory: true)
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            previewRootURL: previewRoot
        )

        let url = try await manager.previewFile(remoteFileId: 77, fileName: "..", fileSize: 4)

        let expectedDirectory = previewRoot
            .appendingPathComponent(configuration.storageScopeID, isDirectory: true)
            .appendingPathComponent("7", isDirectory: true)
            .appendingPathComponent("77", isDirectory: true)
        XCTAssertEqual(url.lastPathComponent, "file-77")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, expectedDirectory.standardizedFileURL)
    }

    // [修改] 真实 TransferManager 缩略图入口只请求 8MB 前缀，不创建传输记录和完整预览文件。
    func testThumbnailDataRequestsEightMegabytePrefixWithoutCreatingTransferArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let rangeEngine = ThumbnailRangePullEngineSpy(data: Data("image-prefix".utf8))
        let previewRoot = root.appendingPathComponent("previews", isDirectory: true)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            rangePullEngine: rangeEngine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            previewRootURL: previewRoot
        )
        let remoteFileSize: Int64 = 50 * 1024 * 1024

        let data = try await manager.thumbnailData(
            remoteFileId: 77,
            fileName: "large.jpg",
            fileSize: remoteFileSize,
            maximumBytes: DriveThumbnailLoader.maximumRemoteImageBytes
        )

        XCTAssertEqual(data, Data("image-prefix".utf8))
        let commands = await rangeEngine.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(command.remoteFileId, 77)
        XCTAssertEqual(command.startOffset, 0)
        XCTAssertEqual(command.length, 8 * 1024 * 1024)
        XCTAssertTrue(command.taskId.hasPrefix("thumbnail-"))
        let storedTasks = await store.all()
        XCTAssertTrue(storedTasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewRoot.path))
    }

    // [修改] 会话刷新后，新传输必须读取最新 transferToken，不能继续使用运行时创建时的旧令牌。
    func testThumbnailDataUsesLatestCredentialStoreIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rangeEngine = ThumbnailRangePullEngineSpy(data: Data("image-prefix".utf8))
        let credentials = TransferCredentialStore(
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "old-token")
        )
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: credentials.current(),
            credentialStore: credentials,
            store: FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json")),
            rangePullEngine: rangeEngine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        credentials.update(
            TransferIdentity(userId: 7, username: "alice", transferToken: "new-token")
        )

        _ = try await manager.thumbnailData(
            remoteFileId: 77,
            fileName: "large.jpg",
            fileSize: 50 * 1024 * 1024,
            maximumBytes: DriveThumbnailLoader.maximumRemoteImageBytes
        )

        let commands = await rangeEngine.commands
        XCTAssertEqual(commands.first?.identity.transferToken, "new-token")
    }

    // [修改] 相同账号和远端文件 ID 在不同服务器必须使用不同预览缓存。
    func testPreviewCacheIsIsolatedByServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = PreviewDownloadEngine(data: Data("image".utf8))
        let previewRoot = root.appendingPathComponent("previews", isDirectory: true)
        let firstConfiguration = try ServerConfiguration(host: "server-a.example")
        let secondConfiguration = try ServerConfiguration(host: "server-b.example")
        let identity = TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token")
        let firstManager = TransferManager(
            configuration: firstConfiguration,
            identity: identity,
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources-a", isDirectory: true),
            previewRootURL: previewRoot
        )
        let secondManager = TransferManager(
            configuration: secondConfiguration,
            identity: identity,
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources-b", isDirectory: true),
            previewRootURL: previewRoot
        )

        let first = try await firstManager.previewFile(remoteFileId: 77, fileName: "photo.jpg", fileSize: 5)
        let second = try await secondManager.previewFile(remoteFileId: 77, fileName: "photo.jpg", fileSize: 5)

        XCTAssertNotEqual(first, second)
        let calls = await engine.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testProgressPublishesSpeedInMemoryBeforeDiskThrottleThreshold() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("transfers.json")
        let store = FileTransferTaskStore(fileURL: fileURL)
        let task = TransferTaskRecord.fixture(id: "speed-task", status: .running, transferredBytes: 0, fileSize: 2_048)
        try await store.insert(task)
        let progressPublished = expectation(description: "小进度也发布给传输中心")
        let observer = Task {
            for await values in store.taskStream() {
                if values.first(where: { $0.id == task.id })?.transferredBytes == 512 {
                    progressPublished.fulfill()
                    return
                }
            }
        }
        await Task.yield()

        // [修改] 1 秒传 512 字节，内存状态应立即显示 512 B/s，但未到 1MB 不必写盘。
        try await store.setProgress(id: task.id, transferredBytes: 512, timestamp: task.updatedAt + 1_000)
        await fulfillment(of: [progressPublished], timeout: 1)
        observer.cancel()

        let inMemory = await store.task(id: task.id)
        let restored = await FileTransferTaskStore(fileURL: fileURL).task(id: task.id)
        XCTAssertEqual(inMemory?.bytesPerSecond ?? 0, 512, accuracy: 0.001)
        XCTAssertEqual(inMemory?.transferredBytes, 512)
        XCTAssertEqual(restored?.transferredBytes, 0)
    }

    // [修改] 服务端元数据返回真实大小后，未知大小任务必须回填总字节并正常计算进度。
    func testProgressBackfillsUnknownFileSizeFromServerMetadata() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryStoreURL())
        let task = TransferTaskRecord.fixture(id: "unknown-size", status: .running, transferredBytes: 0, fileSize: 0)
        try await store.insert(task)

        try await store.setProgress(id: task.id, transferredBytes: 5, totalBytes: 10)

        let updated = await store.task(id: task.id)
        XCTAssertEqual(updated?.fileSize, 10)
        XCTAssertEqual(updated?.transferredBytes, 5)
        XCTAssertEqual(updated?.progress ?? 0, 0.5, accuracy: 0.001)
    }

    // [修改] 远端文件在列表加载后发生变化时，完成记录必须采用实际传输大小并显示 100%。
    func testCompleteReplacesStaleFileSizeWithActualTransferredBytes() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryStoreURL())
        let task = TransferTaskRecord.fixture(id: "changed-size", status: .running, transferredBytes: 4, fileSize: 10)
        try await store.insert(task)

        try await store.complete(id: task.id, remoteFileId: 99, transferredBytes: 6)

        let completed = await store.task(id: task.id)
        XCTAssertEqual(completed?.fileSize, 6)
        XCTAssertEqual(completed?.transferredBytes, 6)
        XCTAssertEqual(completed?.progress ?? 0, 1, accuracy: 0.001)
    }

    // [修改] 用户已暂停或取消后，迟到的完成回调不能覆盖最终状态。
    func testCompleteDoesNotOverwritePausedOrCancelledIntent() async throws {
        let store = FileTransferTaskStore(fileURL: temporaryStoreURL())
        let paused = TransferTaskRecord.fixture(id: "paused-race", status: .running, transferredBytes: 9)
        let cancelled = TransferTaskRecord.fixture(id: "cancelled-race", status: .running, transferredBytes: 9)
        try await store.insert(paused)
        try await store.insert(cancelled)
        try await store.setStatus(id: paused.id, status: .paused)
        try await store.setStatus(id: cancelled.id, status: .cancelled)

        try await store.complete(id: paused.id, remoteFileId: 100, transferredBytes: 10)
        try await store.complete(id: cancelled.id, remoteFileId: 101, transferredBytes: 10)

        let pausedResult = await store.task(id: paused.id)
        let cancelledResult = await store.task(id: cancelled.id)
        XCTAssertEqual(pausedResult?.status, .paused)
        XCTAssertEqual(cancelledResult?.status, .cancelled)
    }

    // [修改] UI 暂停消费时只保留最新任务快照，连续进度不能无限占用内存。
    func testChangesKeepsOnlyNewestSnapshotForSlowSubscriber() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("transfers.json")
        let store = FileTransferTaskStore(fileURL: fileURL)
        let task = TransferTaskRecord.fixture(id: "latest-only", status: .running, transferredBytes: 0, fileSize: 10)
        try await store.insert(task)
        try await store.setProgress(id: task.id, transferredBytes: 1, timestamp: task.updatedAt + 1_000)
        try await store.setProgress(id: task.id, transferredBytes: 2, timestamp: task.updatedAt + 2_000)
        try await store.setProgress(id: task.id, transferredBytes: 3, timestamp: task.updatedAt + 3_000)

        var iterator = store.taskStream().makeAsyncIterator()
        let snapshot = await iterator.next()

        XCTAssertEqual(snapshot?.first(where: { $0.id == task.id })?.transferredBytes, 3)
    }

    // [修改] 两次并发下载同一文件名时，TransferManager 必须原子分配两个不同目标。
    func testConcurrentDownloadsReserveDifferentDestinationURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = CoordinatedDownloadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        let suggestedURL = root.appendingPathComponent("报告.pdf")
        let first = Task {
            try await manager.downloadUnique(remoteFileId: 77, fileName: "报告.pdf", fileSize: 10, suggestedDestinationURL: suggestedURL)
        }
        await engine.waitForCallCount(1)
        let second = Task {
            try await manager.downloadUnique(remoteFileId: 78, fileName: "报告.pdf", fileSize: 10, suggestedDestinationURL: suggestedURL)
        }
        await engine.waitForCallCount(2)

        await engine.finishAll()
        let results = try await [first.value, second.value]

        XCTAssertEqual(Set(results.map { $0.destinationURL.lastPathComponent }), ["报告.pdf", "报告 (1).pdf"])
        let destinations = await engine.destinationURLs
        XCTAssertEqual(Set(destinations.map(\.lastPathComponent)), ["报告.pdf", "报告 (1).pdf"])
    }

    // [修改] 活跃下载的目标保留必须按 iOS 文件系统规则忽略大小写。
    func testConcurrentDownloadsReserveCaseInsensitiveDestinationURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = CoordinatedDownloadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        let first = Task {
            try await manager.downloadUnique(
                remoteFileId: 77,
                fileName: "Report.pdf",
                fileSize: 10,
                suggestedDestinationURL: root.appendingPathComponent("Report.pdf")
            )
        }
        await engine.waitForCallCount(1)
        let second = Task {
            try await manager.downloadUnique(
                remoteFileId: 78,
                fileName: "report.pdf",
                fileSize: 10,
                suggestedDestinationURL: root.appendingPathComponent("report.pdf")
            )
        }
        await engine.waitForCallCount(2)

        await engine.finishAll()
        let results = try await [first.value, second.value]

        XCTAssertEqual(Set(results.map { $0.destinationURL.lastPathComponent }), ["Report.pdf", "report (1).pdf"])
    }

    // [修改] 已保留目标的 `.part` 路径不能再成为另一个活跃下载的正式目标。
    func testConcurrentDownloadsReserveFinalAndPartialPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = CoordinatedDownloadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        let first = Task {
            try await manager.downloadUnique(
                remoteFileId: 77,
                fileName: "archive",
                fileSize: 10,
                suggestedDestinationURL: root.appendingPathComponent("archive")
            )
        }
        await engine.waitForCallCount(1)
        let second = Task {
            try await manager.downloadUnique(
                remoteFileId: 78,
                fileName: "archive.part",
                fileSize: 10,
                suggestedDestinationURL: root.appendingPathComponent("archive.part")
            )
        }
        await engine.waitForCallCount(2)

        await engine.finishAll()
        let results = try await [first.value, second.value]

        XCTAssertEqual(Set(results.map { $0.destinationURL.lastPathComponent }), ["archive", "archive (1).part"])
    }

    // [修改] 所有任务先进入持久队列，实际上传同时最多执行 5 个。
    func testManagerPersistsEveryQueuedUploadAndCapsExecutionAtFive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = LimitedUploadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            maxConcurrentTransfers: 5
        )
        let sourceURLs = try (0..<7).map { index -> URL in
            let url = root.appendingPathComponent("file-\(index).bin")
            try Data("\(index)".utf8).write(to: url)
            return url
        }
        let tasks = sourceURLs.map { sourceURL in
            Task { try await manager.upload(sourceURL: sourceURL, targetDirectoryId: 12) }
        }

        try await waitForStoreCount(7, store: store)
        try await Task.sleep(for: .milliseconds(80))

        let queuedRecords = await store.all()
        let maximumConcurrent = await engine.maximumConcurrent
        XCTAssertEqual(queuedRecords.count, 7)
        XCTAssertEqual(maximumConcurrent, 5)

        await engine.finishAll()
        for task in tasks { _ = try await task.value }
    }

    // [修改] 普通下载也要立即占住目标，避免新建的防重名下载在 part 文件出现前抢同一路径。
    func testActiveDirectDownloadReservesDestinationForUniqueDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = CoordinatedDownloadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        let destination = root.appendingPathComponent("报告.pdf")
        let directDownload = Task {
            try await manager.download(
                remoteFileId: 77,
                fileName: "报告.pdf",
                fileSize: 10,
                destinationURL: destination
            )
        }
        await engine.waitForCallCount(1)
        let uniqueDownload = Task {
            try await manager.downloadUnique(
                remoteFileId: 78,
                fileName: "报告.pdf",
                fileSize: 10,
                suggestedDestinationURL: destination
            )
        }
        await engine.waitForCallCount(2)

        await engine.finishAll()
        let directResult = try await directDownload.value
        let uniqueResult = try await uniqueDownload.value

        XCTAssertEqual(directResult.destinationURL.lastPathComponent, "报告.pdf")
        XCTAssertEqual(uniqueResult.destinationURL.lastPathComponent, "报告 (1).pdf")
    }

    // [修改] 后台恢复中的下载也必须占住原目标，新下载不能在 part 文件创建前抢到同一路径。
    func testRetryReservationForcesNewDownloadToUseDifferentDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let destination = root.appendingPathComponent("报告.pdf")
        let record = TransferTaskRecord(
            id: "retry-download",
            direction: .download,
            status: .paused,
            sourcePath: nil,
            destinationPath: destination.path,
            fileName: "报告.pdf",
            fileType: "pdf",
            fileSize: 10,
            remoteFileId: 77,
            targetDirectoryId: nil,
            uploadPurpose: nil,
            batchId: nil,
            serverScopeID: configuration.storageScopeID,
            userId: 7,
            username: "alice",
            md5: nil,
            transferredBytes: 0,
            errorMessage: nil,
            createdAt: 1,
            updatedAt: 2
        )
        try await store.insert(record)
        let engine = CoordinatedDownloadEngine()
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.retry(record.id)
        await engine.waitForCallCount(1)
        let newDownload = Task {
            try await manager.downloadUnique(
                remoteFileId: 78,
                fileName: "报告.pdf",
                fileSize: 10,
                suggestedDestinationURL: destination
            )
        }
        await engine.waitForCallCount(2)
        await engine.finishAll()

        let result = try await newDownload.value
        XCTAssertEqual(result.destinationURL.lastPathComponent, "报告 (1).pdf")
        let destinations = await engine.destinationURLs
        XCTAssertEqual(Set(destinations.map(\.lastPathComponent)), ["报告.pdf", "报告 (1).pdf"])
    }

    // [修改] SwiftUI 行离屏后取消缩略图任务，底层预览下载也必须停止。
    func testCancellingPreviewFileCancelsUnderlyingDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = CancellableDownloadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            previewRootURL: root.appendingPathComponent("previews", isDirectory: true)
        )
        let preview = Task {
            try await manager.previewFile(remoteFileId: 77, fileName: "photo.jpg", fileSize: 10)
        }
        await engine.waitUntilStarted()

        preview.cancel()
        try await Task.sleep(for: .milliseconds(100))

        let cancellationCount = await engine.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
        await manager.shutdown()
        _ = await preview.result
    }

    func testCancelPersistsCancelledAndCancelAllAffectsEveryActiveTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        try await store.insert(.fixture(id: "queued", status: .queued, transferredBytes: 0))
        try await store.insert(.fixture(id: "running", status: .running, transferredBytes: 3))
        try await store.insert(.fixture(id: "completed", status: .completed, transferredBytes: 10))
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.cancel("queued")
        await manager.cancelAll()

        let queued = await store.task(id: "queued")
        let running = await store.task(id: "running")
        let completed = await store.task(id: "completed")
        XCTAssertEqual(queued?.status, .cancelled)
        XCTAssertEqual(running?.status, .cancelled)
        XCTAssertEqual(completed?.status, .completed)
    }

    // [修改] “全部取消”也必须放弃永久失败任务，和单任务“放弃”形成同一闭环。
    func testCancelAllAlsoCancelsFailedTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        try await store.insert(.fixture(id: "failed", status: .failed, transferredBytes: 3))
        try await store.insert(.fixture(id: "completed", status: .completed, transferredBytes: 10))
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.cancelAll()

        let failed = await store.task(id: "failed")
        let completed = await store.task(id: "completed")
        XCTAssertEqual(failed?.status, .cancelled)
        XCTAssertEqual(completed?.status, .completed)
    }

    func testCancellingRunningJobDoesNotGetOverwrittenAsPaused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = CancellableDownloadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        let destination = root.appendingPathComponent("download.bin")
        let running = Task {
            try await manager.download(remoteFileId: 77, fileName: "download.bin", fileSize: 10, destinationURL: destination)
        }
        await engine.waitUntilStarted()
        let storedTasks = await store.all()
        let taskId = try XCTUnwrap(storedTasks.first?.id)

        await manager.cancel(taskId)
        _ = await running.result

        let stored = await store.task(id: taskId)
        XCTAssertEqual(stored?.status, .cancelled)
    }

    // [修改] 退出登录或切服必须停止活跃 socket，并把任务留在可认证恢复状态。
    func testShutdownStopsRunningJobAndPersistsAuthenticationPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = CancellableDownloadEngine()
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )
        let running = Task {
            try await manager.download(
                remoteFileId: 77,
                fileName: "download.bin",
                fileSize: 10,
                destinationURL: root.appendingPathComponent("download.bin")
            )
        }
        await engine.waitUntilStarted()
        let tasks = await store.all()
        let taskId = try XCTUnwrap(tasks.first?.id)

        await manager.shutdown()
        _ = await running.result

        let stored = await store.task(id: taskId)
        XCTAssertEqual(stored?.status, .pausedAuthentication)
    }

    // [修改] 用户手动暂停是明确意图，退出、切服或锁屏后不能改成自动恢复状态。
    func testShutdownPreservesManualPauseAndRescheduleDoesNotRestartIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let task = TransferTaskRecord.fixture(id: "manual-pause", status: .paused, transferredBytes: 4)
        try await store.insert(task)
        let engine = RecoveryUploadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.shutdown()
        await manager.reschedulePending()
        try await Task.sleep(for: .milliseconds(50))

        let stored = await store.task(id: task.id)
        let resumedTaskIDs = await engine.taskIDs
        XCTAssertEqual(stored?.status, .paused)
        XCTAssertTrue(resumedTaskIDs.isEmpty)
    }

    // [修改] 清理已完成和失败记录前先删除应用上传副本和失败下载留下的 part 文件。
    func testCleanupCompletedArtifactsRemovesUploadCopyAndDownloadPart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("sources", isDirectory: true)
        let uploadDirectory = sourceRoot.appendingPathComponent("upload-task", isDirectory: true)
        try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        let uploadSource = uploadDirectory.appendingPathComponent("report.pdf")
        try Data("upload".utf8).write(to: uploadSource)
        let destination = root.appendingPathComponent("download.bin")
        let partURL = destination.appendingPathExtension("part")
        try Data("partial".utf8).write(to: partURL)
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        try await store.insert(TransferTaskRecord(
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
        ))
        try await store.insert(TransferTaskRecord(
            id: "download-task",
            direction: .download,
            status: .failed,
            sourcePath: nil,
            destinationPath: destination.path,
            fileName: "download.bin",
            fileType: "bin",
            fileSize: 10,
            remoteFileId: 77,
            targetDirectoryId: nil,
            uploadPurpose: nil,
            batchId: nil,
            serverScopeID: configuration.storageScopeID,
            userId: 7,
            username: "alice",
            md5: nil,
            transferredBytes: 4,
            errorMessage: nil,
            createdAt: 1,
            updatedAt: 2
        ))
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            sourceRootURL: sourceRoot
        )

        let taskIDs: Set<String> = ["upload-task", "download-task"]
        try await manager.cleanupCompletedArtifacts(taskIDs: taskIDs)
        try await store.clearFinished(
            taskIDs: taskIDs,
            userId: 7,
            serverScopeID: configuration.storageScopeID
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: uploadDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        let remaining = await store.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReschedulePendingRetriesPersistedRunningUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let source = root.appendingPathComponent("resume.bin")
        try Data("1234567890".utf8).write(to: source)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let task = TransferTaskRecord(
            id: "resume-upload",
            direction: .upload,
            status: .running,
            sourcePath: source.path,
            destinationPath: nil,
            fileName: source.lastPathComponent,
            fileType: "bin",
            fileSize: 10,
            remoteFileId: nil,
            targetDirectoryId: 12,
            uploadPurpose: "CLOUD_FILE",
            batchId: nil,
            serverScopeID: configuration.storageScopeID,
            userId: 7,
            username: "alice",
            md5: "digest",
            transferredBytes: 4,
            bytesPerSecond: nil,
            errorMessage: nil,
            createdAt: 1,
            updatedAt: 2
        )
        try await store.insert(task)
        let engine = RecoveryUploadEngine()
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.reschedulePending()
        let completed = await waitForTask(id: task.id, status: .completed, store: store)

        XCTAssertEqual(completed?.status, .completed)
        let resumedTaskIDs = await engine.taskIDs
        XCTAssertEqual(resumedTaskIDs, ["resume-upload"])
    }

    // [修改] 失效的外部目录授权必须让恢复任务进入失败态，不能一直停在排队中。
    func testReschedulePendingMarksDownloadFailedWhenBookmarkCannotBeResolved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let destination = root.appendingPathComponent("download.bin")
        let task = TransferTaskRecord(
            id: "invalid-bookmark-download",
            direction: .download,
            status: .queued,
            sourcePath: nil,
            destinationPath: destination.path,
            destinationDirectoryBookmark: Data("not-a-bookmark".utf8),
            fileName: "download.bin",
            fileType: "bin",
            fileSize: 5,
            remoteFileId: 77,
            targetDirectoryId: nil,
            uploadPurpose: nil,
            batchId: nil,
            serverScopeID: configuration.storageScopeID,
            userId: 7,
            username: "alice",
            md5: nil,
            transferredBytes: 0,
            errorMessage: nil,
            createdAt: 1,
            updatedAt: 2
        )
        try await store.insert(task)
        let engine = PreviewDownloadEngine(data: Data("download".utf8))
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.reschedulePending()
        let failed = await waitForTask(id: task.id, status: .failed, store: store)
        let calls = await engine.calls

        XCTAssertEqual(failed?.status, .failed)
        XCTAssertFalse(failed?.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(calls.isEmpty)
    }

    // [修改] 旧记录缺少上传源文件时也必须落失败态，不能永远卡在等待队列。
    func testReschedulePendingMarksUploadFailedWhenPersistedFieldsAreMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = try ServerConfiguration(host: "127.0.0.1")
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let task = TransferTaskRecord(
            id: "invalid-upload",
            direction: .upload,
            status: .queued,
            sourcePath: nil,
            destinationPath: nil,
            fileName: "missing.bin",
            fileType: "bin",
            fileSize: 5,
            remoteFileId: nil,
            targetDirectoryId: 12,
            uploadPurpose: "CLOUD_FILE",
            batchId: nil,
            serverScopeID: configuration.storageScopeID,
            userId: 7,
            username: "alice",
            md5: nil,
            transferredBytes: 0,
            errorMessage: nil,
            createdAt: 1,
            updatedAt: 2
        )
        try await store.insert(task)
        let engine = RecoveryUploadEngine()
        let manager = TransferManager(
            configuration: configuration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.reschedulePending()
        let failed = await waitForTask(id: task.id, status: .failed, store: store)
        let taskIDs = await engine.taskIDs

        XCTAssertEqual(failed?.status, .failed)
        XCTAssertFalse(failed?.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(taskIDs.isEmpty)
    }

    // [修改] 换账号后只能恢复当前账号的断点任务，不能拿新账号凭据继续旧账号文件。
    func testReschedulePendingIgnoresTasksOwnedByAnotherUser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ownSource = root.appendingPathComponent("own.bin")
        let otherSource = root.appendingPathComponent("other.bin")
        try Data("1234567890".utf8).write(to: ownSource)
        try Data("abcdefghij".utf8).write(to: otherSource)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        try await store.insert(.fixture(
            id: "own-upload",
            status: .running,
            transferredBytes: 4,
            sourcePath: ownSource.path,
            userId: 7,
            username: "alice"
        ))
        try await store.insert(.fixture(
            id: "other-upload",
            status: .running,
            transferredBytes: 4,
            sourcePath: otherSource.path,
            userId: 8,
            username: "bob"
        ))
        let engine = RecoveryUploadEngine()
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.reschedulePending()
        _ = await waitForTask(id: "own-upload", status: .completed, store: store)

        let otherTask = await store.task(id: "other-upload")
        let resumedTaskIDs = await engine.taskIDs
        XCTAssertEqual(otherTask?.status, .running)
        XCTAssertEqual(resumedTaskIDs, ["own-upload"])
    }

    // [修改] 相同 userId 的其他服务器任务不能拿当前服务器 token 自动恢复。
    func testReschedulePendingIgnoresTasksOwnedByAnotherServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("other-server.bin")
        try Data("1234567890".utf8).write(to: source)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let firstConfiguration = try ServerConfiguration(host: "server-a.example")
        let secondConfiguration = try ServerConfiguration(host: "server-b.example")
        try await store.insert(.fixture(
            id: "other-server-upload",
            status: .running,
            transferredBytes: 4,
            sourcePath: source.path,
            serverScopeID: firstConfiguration.storageScopeID
        ))
        let engine = RecoveryUploadEngine()
        let manager = TransferManager(
            configuration: secondConfiguration,
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.reschedulePending()

        let task = await store.task(id: "other-server-upload")
        let resumedTaskIDs = await engine.taskIDs
        XCTAssertEqual(task?.status, .running)
        XCTAssertTrue(resumedTaskIDs.isEmpty)
    }

    // [修改] 开启“仅 Wi-Fi”后，新建任务先落盘排队，蜂窝网络下不能启动上传引擎。
    func testWifiOnlyPolicyQueuesNewUploadUntilWifiBecomesAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("new-upload.bin")
        try Data("1234567890".utf8).write(to: source)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = RecoveryUploadEngine()
        let gate = TransferNetworkGate(wifiOnly: true, isOnWiFi: false)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            networkGate: gate
        )

        let uploading = Task { try await manager.upload(sourceURL: source, targetDirectoryId: 12) }
        try await waitForStoreCount(1, store: store)
        try await Task.sleep(for: .milliseconds(50))

        let blockedTaskIDs = await engine.taskIDs
        let queuedStatus = await store.all().first?.status
        XCTAssertTrue(blockedTaskIDs.isEmpty)
        XCTAssertEqual(queuedStatus, .queued)

        await gate.updatePath(isOnWiFi: true)
        _ = try await uploading.value

        let startedTaskIDs = await engine.taskIDs
        XCTAssertEqual(startedTaskIDs.count, 1)
    }

    // [修改] 应用恢复的未完成任务也必须经过 Wi-Fi 门禁，不能绕过设置直接重连。
    func testWifiOnlyPolicyQueuesRescheduledTaskUntilWifiBecomesAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("resume-upload.bin")
        try Data("1234567890".utf8).write(to: source)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let record = TransferTaskRecord.fixture(
            id: "wifi-resume",
            status: .running,
            transferredBytes: 4,
            sourcePath: source.path
        )
        try await store.insert(record)
        let engine = RecoveryUploadEngine()
        let gate = TransferNetworkGate(wifiOnly: true, isOnWiFi: false)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            networkGate: gate
        )

        await manager.reschedulePending()
        try await Task.sleep(for: .milliseconds(50))
        let blockedTaskIDs = await engine.taskIDs
        XCTAssertTrue(blockedTaskIDs.isEmpty)

        await gate.updatePath(isOnWiFi: true)
        let completed = await waitForTask(id: record.id, status: .completed, store: store)

        XCTAssertEqual(completed?.status, .completed)
        let resumedTaskIDs = await engine.taskIDs
        XCTAssertEqual(resumedTaskIDs, [record.id])
    }

    // [修改] 用户关闭 Wi-Fi 限制时必须立即唤醒已排队任务，无需重启页面或 App。
    func testDisablingWifiOnlyPolicyImmediatelyReleasesWaitingUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("release-upload.bin")
        try Data("1234567890".utf8).write(to: source)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = RecoveryUploadEngine()
        let gate = TransferNetworkGate(wifiOnly: true, isOnWiFi: false)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            uploadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            networkGate: gate
        )

        let uploading = Task { try await manager.upload(sourceURL: source, targetDirectoryId: 12) }
        try await waitForStoreCount(1, store: store)
        try await Task.sleep(for: .milliseconds(50))
        let blockedTaskIDs = await engine.taskIDs
        XCTAssertTrue(blockedTaskIDs.isEmpty)

        await manager.setWifiOnlyTransfers(false)
        _ = try await uploading.value

        let startedTaskIDs = await engine.taskIDs
        XCTAssertEqual(startedTaskIDs.count, 1)
    }

    // [修改] 传输已经启动后再开启 Wi-Fi 限制，只影响后续任务，不能中断当前 socket。
    func testEnablingWifiOnlyPolicyDoesNotCancelRunningTransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        let engine = CancellableDownloadEngine()
        let gate = TransferNetworkGate(wifiOnly: false, isOnWiFi: false)
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            downloadEngine: engine,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true),
            networkGate: gate
        )
        let running = Task {
            try await manager.download(
                remoteFileId: 77,
                fileName: "running.bin",
                fileSize: 10,
                destinationURL: root.appendingPathComponent("running.bin")
            )
        }
        await engine.waitUntilStarted()
        let persistedTasks = await store.all()
        let taskId = try XCTUnwrap(persistedTasks.first?.id)

        await manager.setWifiOnlyTransfers(true)
        try await Task.sleep(for: .milliseconds(50))

        let cancellationCountBeforePause = await engine.cancellationCount
        let statusBeforePause = await store.task(id: taskId)?.status
        XCTAssertEqual(cancellationCountBeforePause, 0)
        XCTAssertEqual(statusBeforePause, .running)

        await manager.pause(taskId)
        _ = await running.result
    }

    // [修改] “全部取消”和单任务操作都只能改当前账号的任务。
    func testCancelOperationsIgnoreTasksOwnedByAnotherUser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTransferTaskStore(fileURL: root.appendingPathComponent("transfers.json"))
        try await store.insert(.fixture(id: "own-running", status: .running, transferredBytes: 3, userId: 7, username: "alice"))
        try await store.insert(.fixture(id: "other-running", status: .running, transferredBytes: 3, userId: 8, username: "bob"))
        let manager = TransferManager(
            configuration: try ServerConfiguration(host: "127.0.0.1"),
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "secret-token"),
            store: store,
            sourceRootURL: root.appendingPathComponent("sources", isDirectory: true)
        )

        await manager.cancel("other-running")
        await manager.cancelAll()

        let ownTask = await store.task(id: "own-running")
        let otherTask = await store.task(id: "other-running")
        XCTAssertEqual(ownTask?.status, .cancelled)
        XCTAssertEqual(otherTask?.status, .running)
    }

    private func waitForTask(
        id: String,
        status: TransferStatus,
        store: FileTransferTaskStore
    ) async -> TransferTaskRecord? {
        for _ in 0..<100 {
            let task = await store.task(id: id)
            if task?.status == status { return task }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await store.task(id: id)
    }

    private func waitForOnlyTask(status: TransferStatus, store: FileTransferTaskStore) async -> TransferTaskRecord? {
        for _ in 0..<100 {
            if let task = await store.all().first, task.status == status { return task }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await store.all().first
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("transfers.json")
    }

    private func waitForStoreCount(_ count: Int, store: FileTransferTaskStore) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await store.all().count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("传输任务没有全部持久化")
    }
}

private func firstTransferCompletion(from stream: AsyncStream<TransferCompletionEvent>) async -> TransferCompletionEvent {
    for await event in stream { return event }
    fatalError("传输完成流意外结束")
}

private struct SuccessfulUploadEngine: FileUploading {
    func upload(
        command: UploadCommand,
        sourceURL: URL,
        onMD5Computed: @escaping @Sendable (String) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        try await onMD5Computed("e807f1fcf82d132f9bb018ca6738a19f")
        await onProgress(TransferProgress(transferredBytes: 5, totalBytes: 10))
        await onProgress(TransferProgress(transferredBytes: 10, totalBytes: 10))
        return UploadResult(fileId: 901, uploadedBytes: 10)
    }
}

private struct SuccessfulPhotoLibraryUploadEngine: PhotoLibraryUploading {
    func uploadPhotoLibraryVideo(
        command: UploadCommand,
        assetLocalIdentifier: String,
        fileName: String,
        fileType: String,
        knownFileSize: Int64?,
        onMetadataComputed: @escaping @Sendable (PhotoLibraryUploadMetadata) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        try await onMetadataComputed(.init(fileSize: 32 * 1024 * 1024, md5: "photo-md5"))
        await onProgress(.init(transferredBytes: 32 * 1024 * 1024, totalBytes: 32 * 1024 * 1024))
        return .init(fileId: 902, uploadedBytes: 32 * 1024 * 1024)
    }
}

private actor FinalizationHoldingUploadEngine: FileUploading {
    private var hasReportedFinalProgress = false
    private var finalProgressWaiter: CheckedContinuation<Void, Never>?
    private var completionWaiter: CheckedContinuation<Void, Never>?

    func upload(
        command: UploadCommand,
        sourceURL: URL,
        onMD5Computed: @escaping @Sendable (String) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        try await onMD5Computed("e807f1fcf82d132f9bb018ca6738a19f")
        await onProgress(.init(transferredBytes: 10, totalBytes: 10))
        hasReportedFinalProgress = true
        finalProgressWaiter?.resume()
        finalProgressWaiter = nil
        await withCheckedContinuation { completionWaiter = $0 }
        return .init(fileId: 903, uploadedBytes: 10)
    }

    func waitUntilFinalProgressWasReported() async {
        guard !hasReportedFinalProgress else { return }
        await withCheckedContinuation { finalProgressWaiter = $0 }
    }

    func acknowledgeCompletion() {
        completionWaiter?.resume()
        completionWaiter = nil
    }
}

private actor CoordinatedDownloadEngine: FileDownloading {
    private(set) var destinationURLs: [URL] = []
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false

    func download(
        command: DownloadCommand,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> DownloadResult {
        destinationURLs.append(destinationURL)
        resumeSatisfiedCallCountWaiters()
        if !isFinished {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        return DownloadResult(downloadedBytes: command.expectedFileSize, destinationURL: destinationURL)
    }

    func waitForCallCount(_ count: Int) async {
        guard destinationURLs.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func finishAll() {
        isFinished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeSatisfiedCallCountWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if destinationURLs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callCountWaiters = remaining
    }
}

private actor LimitedUploadEngine: FileUploading {
    private var currentConcurrent = 0
    private(set) var maximumConcurrent = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false

    func upload(
        command: UploadCommand,
        sourceURL: URL,
        onMD5Computed: @escaping @Sendable (String) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        currentConcurrent += 1
        maximumConcurrent = max(maximumConcurrent, currentConcurrent)
        try await onMD5Computed("digest-\(command.taskId)")
        if !isFinished { await withCheckedContinuation { waiters.append($0) } }
        currentConcurrent -= 1
        let size = Int64((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        await onProgress(.init(transferredBytes: size, totalBytes: size))
        return UploadResult(fileId: Int64.random(in: 1...10_000), uploadedBytes: size)
    }

    func finishAll() {
        isFinished = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private actor LimitedPhotoLibraryUploadEngine: PhotoLibraryUploading {
    private var currentConcurrent = 0
    private(set) var maximumConcurrent = 0
    private(set) var startedAssetIdentifiers: [String] = []
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false

    func uploadPhotoLibraryVideo(
        command: UploadCommand,
        assetLocalIdentifier: String,
        fileName: String,
        fileType: String,
        knownFileSize: Int64?,
        onMetadataComputed: @escaping @Sendable (PhotoLibraryUploadMetadata) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        currentConcurrent += 1
        maximumConcurrent = max(maximumConcurrent, currentConcurrent)
        startedAssetIdentifiers.append(assetLocalIdentifier)
        resumeSatisfiedCallCountWaiters()
        try await onMetadataComputed(.init(fileSize: 1_024, md5: "digest-\(command.taskId)"))
        await onProgress(.init(transferredBytes: 1_024, totalBytes: 1_024))
        if !isFinished {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        currentConcurrent -= 1
        return .init(fileId: Int64.random(in: 1...10_000), uploadedBytes: 1_024)
    }

    func waitForCallCount(_ count: Int) async {
        guard currentConcurrent < count else { return }
        await withCheckedContinuation { callCountWaiters.append((count, $0)) }
    }

    func finishAll() {
        isFinished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeSatisfiedCallCountWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if currentConcurrent >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callCountWaiters = remaining
    }
}

private actor RetryingUploadEngine: FileUploading {
    static let digest = "e807f1fcf82d132f9bb018ca6738a19f"
    private(set) var knownMD5Values: [String?] = []
    private var attempts = 0

    func upload(
        command: UploadCommand,
        sourceURL: URL,
        onMD5Computed: @escaping @Sendable (String) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        attempts += 1
        knownMD5Values.append(command.knownMD5)
        try await onMD5Computed(Self.digest)
        if attempts == 1 { throw FileTransferError.server("模拟网络中断") }
        await onProgress(TransferProgress(transferredBytes: 10, totalBytes: 10))
        return UploadResult(fileId: 902, uploadedBytes: 10)
    }
}

private actor PreviewDownloadEngine: FileDownloading {
    struct Call: Equatable, Sendable {
        let taskId: String
        let remoteFileId: Int64
        let destinationURL: URL
    }

    private let data: Data
    private(set) var calls: [Call] = []

    init(data: Data) { self.data = data }

    func download(
        command: DownloadCommand,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> DownloadResult {
        calls.append(.init(taskId: command.taskId, remoteFileId: command.remoteFileId, destinationURL: destinationURL))
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destinationURL)
        await onProgress(.init(transferredBytes: Int64(data.count), totalBytes: Int64(data.count)))
        return DownloadResult(downloadedBytes: Int64(data.count), destinationURL: destinationURL)
    }
}

private actor ThumbnailRangePullEngineSpy: FileRangePulling {
    private let data: Data
    private(set) var commands: [RangePullCommand] = []

    init(data: Data) { self.data = data }

    func pull(command: RangePullCommand) async throws -> RangePullResult {
        commands.append(command)
        let fileSize: Int64 = 50 * 1024 * 1024
        let nextOffset = command.startOffset + Int64(data.count)
        return RangePullResult(
            data: data,
            fileSize: fileSize,
            startOffset: command.startOffset,
            nextOffset: nextOffset,
            isEOF: nextOffset >= fileSize
        )
    }
}

private actor CancellableDownloadEngine: FileDownloading {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellationCount = 0

    func download(
        command: DownloadCommand,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> DownloadResult {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(30))
            return DownloadResult(downloadedBytes: command.expectedFileSize, destinationURL: destinationURL)
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor RecoveryUploadEngine: FileUploading {
    private(set) var taskIDs: [String] = []

    func upload(
        command: UploadCommand,
        sourceURL: URL,
        onMD5Computed: @escaping @Sendable (String) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        taskIDs.append(command.taskId)
        try await onMD5Computed(command.knownMD5 ?? "digest")
        await onProgress(.init(transferredBytes: 10, totalBytes: 10))
        return UploadResult(fileId: 903, uploadedBytes: 10)
    }
}

private extension TransferTaskRecord {
    static func fixture(
        id: String,
        status: TransferStatus,
        transferredBytes: Int64,
        fileSize: Int64 = 10,
        sourcePath: String = "/tmp/report.pdf",
        serverScopeID: String = try! ServerConfiguration(host: "127.0.0.1").storageScopeID,
        userId: Int64 = 7,
        username: String = "alice"
    ) -> TransferTaskRecord {
        TransferTaskRecord(
            id: id,
            direction: .upload,
            status: status,
            sourcePath: sourcePath,
            destinationPath: nil,
            fileName: "report.pdf",
            fileType: "pdf",
            fileSize: fileSize,
            remoteFileId: nil,
            targetDirectoryId: 12,
            uploadPurpose: "CLOUD_FILE",
            batchId: nil,
            serverScopeID: serverScopeID,
            userId: userId,
            username: username,
            md5: nil,
            transferredBytes: transferredBytes,
            bytesPerSecond: nil,
            errorMessage: nil,
            createdAt: 1,
            updatedAt: 2
        )
    }
}
