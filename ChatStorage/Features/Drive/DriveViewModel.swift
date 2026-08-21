import Foundation
import Observation

protocol DriveTransferManaging: FileDownloadManaging {
    var completionEvents: AsyncStream<TransferCompletionEvent> { get }
    func upload(sourceURL: URL, targetDirectoryId: Int64, uploadPurpose: String, batchId: String?) async throws -> UploadResult
    func previewFile(remoteFileId: Int64, fileName: String, fileSize: Int64) async throws -> URL
    func thumbnailData(remoteFileId: Int64, fileName: String, fileSize: Int64, maximumBytes: Int64) async throws -> Data
    func downloadUnique(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        suggestedDestinationURL: URL
    ) async throws -> DownloadResult
    func downloadUnique(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        suggestedDestinationURL: URL,
        destinationDirectoryBookmark: Data?
    ) async throws -> DownloadResult
    func removeCachedFile(remoteFileId: Int64) async
}

extension DriveTransferManaging {
    var completionEvents: AsyncStream<TransferCompletionEvent> { AsyncStream { $0.finish() } }
    func thumbnailData(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        maximumBytes: Int64
    ) async throws -> Data {
        let url = try await previewFile(remoteFileId: remoteFileId, fileName: fileName, fileSize: fileSize)
        return try Data(contentsOf: url)
    }

    func downloadUnique(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        suggestedDestinationURL: URL
    ) async throws -> DownloadResult {
        try await download(
            remoteFileId: remoteFileId,
            fileName: fileName,
            fileSize: fileSize,
            destinationURL: suggestedDestinationURL
        )
    }

    func downloadUnique(
        remoteFileId: Int64,
        fileName: String,
        fileSize: Int64,
        suggestedDestinationURL: URL,
        destinationDirectoryBookmark: Data?
    ) async throws -> DownloadResult {
        try await downloadUnique(
            remoteFileId: remoteFileId,
            fileName: fileName,
            fileSize: fileSize,
            suggestedDestinationURL: suggestedDestinationURL
        )
    }

    func removeCachedFile(remoteFileId: Int64) async {}
}

@MainActor
@Observable
final class DriveViewModel {
    private(set) var directoryRoots: [DriveFileEntry] = []
    private(set) var currentDirectory: DriveFileEntry?
    private(set) var path: [DriveFileEntry] = []
    private(set) var files: [DriveFileEntry] = []
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isLoadingNextPage = false
    private(set) var isTransferring = false
    // [修改] 批量下载和删除共享重入锁，避免连续点击重复提交同一批任务。
    private(set) var isBatchOperating = false
    private(set) var errorMessage: String?
    private(set) var currentPage = 0
    private(set) var totalPages = 0
    private(set) var totalCount: Int64 = 0
    private(set) var selectedEntryIDs: Set<Int64> = []
    private(set) var loadingDirectoryIDs: Set<Int64> = []
    var searchText = ""
    var smartCollection: DriveSmartCollection = .all {
        didSet { selectedEntryIDs.removeAll() }
    }
    private let repository: any DriveRepository
    private let transferManager: (any DriveTransferManaging)?
    private let now: () -> Date
    private let pageSize = 20
    private var activeSearch = ""
    private var contentGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var loadingGeneration: UInt64?
    private var nextPageGeneration: UInt64?
    private var directoryTreeGeneration: UInt64 = 0
    private var directorySelectionGeneration: UInt64 = 0
    private var loadedDirectoryIDs: Set<Int64> = []
    private var activeTransferOperations = 0
    private var completionRefreshTask: Task<Void, Never>?

    init(
        repository: any DriveRepository,
        transferManager: (any DriveTransferManaging)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.transferManager = transferManager
        self.now = now
    }

    // [修改] 目录来自递归树，文件来自分页接口，当前目录统一合并展示。
    var entries: [DriveFileEntry] {
        currentDirectories + files
    }

    var visibleEntries: [DriveFileEntry] {
        let collectionEntries = entries.filter(matchesSmartCollection)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return collectionEntries }
        // [修改] 文件名搜索仍由服务端分页完成；目录是树数据，因此只在本地匹配目录名称。
        let matchedDirectories = collectionEntries.filter {
            !$0.isFile && $0.name.localizedCaseInsensitiveContains(query)
        }
        return matchedDirectories + collectionEntries.filter(\.isFile)
    }

    private func matchesSmartCollection(_ entry: DriveFileEntry) -> Bool {
        switch smartCollection {
        case .all:
            return true
        case .recent:
            guard entry.isFile, let rawTimestamp = entry.modifiedAt ?? entry.createdAt else { return false }
            let seconds = rawTimestamp > 10_000_000_000
                ? TimeInterval(rawTimestamp) / 1_000
                : TimeInterval(rawTimestamp)
            let age = now().timeIntervalSince(Date(timeIntervalSince1970: seconds))
            return age >= 0 && age <= 7 * 24 * 60 * 60
        case .images:
            return entry.isFile && DriveFileOpenRules.isImage(entry)
        case .videos:
            return entry.isFile && DriveFileOpenRules.isVideo(entry)
        case .largeFiles:
            return entry.isFile && (entry.size ?? 0) >= 100 * 1_024 * 1_024
        }
    }

    var hasNextPage: Bool {
        currentPage < totalPages || Int64(files.count) < totalCount
    }

    var selectedEntries: [DriveFileEntry] {
        entries.filter { selectedEntryIDs.contains($0.id) }
    }

    func load() async {
        guard !isLoading else { return }
        let generation = beginContentLoad()
        errorMessage = nil
        defer { finishContentLoad(generation) }
        do {
            guard try await refreshTree(preserving: currentDirectory?.id, generation: generation) else { return }
            if let directoryId = currentDirectory?.id {
                try await fetchDirectoryChildrenIfNeeded(id: directoryId, treeGeneration: directoryTreeGeneration)
            }
            try await reloadFirstPage(generation: generation)
        } catch {
            guard contentGeneration == generation, !Self.isCancellation(error) else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "网盘加载失败"
        }
    }

    // [修改] 下拉刷新只拉当前目录的直接子目录和文件第一页，避免重复重建根目录树导致路径恢复报错。
    func refreshCurrentDirectory() async {
        guard let directoryId = currentDirectory?.id,
              !isLoading,
              !isRefreshing,
              !isLoadingNextPage else { return }
        let generation = contentGeneration
        let search = activeSearch
        // [修改] 独立刷新令牌避免旧请求结束时清掉新目录正在展示的刷新动画。
        refreshGeneration &+= 1
        let refreshToken = refreshGeneration
        isRefreshing = true
        errorMessage = nil
        defer { finishRefresh(refreshToken) }

        do {
            // [修改] 两份数据都成功后再一次性落状态，任一请求失败时保留刷新前列表。
            async let childrenRequest = repository.directoryChildren(id: directoryId)
            async let pageRequest = repository.listFiles(
                directoryId: directoryId,
                page: 1,
                pageSize: pageSize,
                search: search
            )
            let (children, page) = try await (childrenRequest, pageRequest)
            guard isCurrentRefresh(
                refreshToken,
                contentGeneration: generation,
                directoryId: directoryId,
                search: search
            ) else { return }

            let refreshedRoots = Self.replacingChildren(
                in: directoryRoots,
                directoryId: directoryId,
                children: children
            )
            guard let refreshedPath = Self.path(to: directoryId, in: refreshedRoots) else { return }

            directoryTreeGeneration &+= 1
            directoryRoots = refreshedRoots
            loadedDirectoryIDs.insert(directoryId)
            path = refreshedPath
            currentDirectory = refreshedPath.last
            files = Self.deduplicating(page.records.filter(\.isFile))
            applyPagination(page)
        } catch {
            guard isCurrentRefresh(
                refreshToken,
                contentGeneration: generation,
                directoryId: directoryId,
                search: search
            ),
                  !Self.isCancellation(error) else { return }
            // [修改] 协议结构异常在刷新场景使用明确文案，服务端业务错误仍保留原始提示。
            if case DriveRepositoryError.invalidResponse = error {
                errorMessage = "网盘刷新失败"
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "网盘刷新失败"
            }
        }
    }

    func open(_ directory: DriveFileEntry) async {
        guard !directory.isFile else { return }
        await selectDirectory(id: directory.id)
    }

    func selectDirectory(id: Int64) async {
        directorySelectionGeneration &+= 1
        let selectionGeneration = directorySelectionGeneration
        guard let initialPath = Self.path(to: id, in: directoryRoots) else { return }
        if let directory = initialPath.last, directory.hasChildren, directory.children.isEmpty {
            await loadDirectoryChildren(id: id)
        }
        // [修改] 用户随后选择了其他目录时，较晚返回的旧懒加载结果不能反向覆盖当前目录。
        guard directorySelectionGeneration == selectionGeneration else { return }
        guard let resolvedPath = Self.path(to: id, in: directoryRoots) else { return }
        path = resolvedPath
        currentDirectory = resolvedPath.last
        searchText = ""
        activeSearch = ""
        selectedEntryIDs.removeAll()
        await loadCurrent()
    }

    // [修改] 目录选择器展开节点时按需请求下一层，并递归替换目录树中的对应节点。
    func loadDirectoryChildren(id: Int64) async {
        do {
            try await fetchDirectoryChildrenIfNeeded(id: id, treeGeneration: directoryTreeGeneration)
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "子目录加载失败"
        }
    }

    func goBack() async {
        guard path.count > 1 else { return }
        await selectDirectory(id: path[path.count - 2].id)
    }

    func performSearch() async {
        activeSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedEntryIDs.removeAll()
        await loadCurrent()
    }

    func loadNextPage() async {
        // [修改] 第一页原子刷新期间禁止翻页，避免第二页响应追加到新的第一页快照。
        guard let directoryId = currentDirectory?.id,
              hasNextPage,
              !isLoading,
              !isRefreshing,
              !isLoadingNextPage else { return }
        let generation = contentGeneration
        let search = activeSearch
        let requestedPage = max(currentPage + 1, 1)
        isLoadingNextPage = true
        nextPageGeneration = generation
        defer {
            if nextPageGeneration == generation {
                nextPageGeneration = nil
                isLoadingNextPage = false
            }
        }
        do {
            let page = try await repository.listFiles(
                directoryId: directoryId,
                page: requestedPage,
                pageSize: pageSize,
                search: search
            )
            // [修改] 切目录或换搜索条件后，上一上下文的分页响应直接丢弃。
            guard isCurrentContent(generation: generation, directoryId: directoryId, search: search) else { return }
            files = Self.deduplicating(files + page.records.filter(\.isFile))
            applyPagination(page)
        } catch {
            guard isCurrentContent(generation: generation, directoryId: directoryId, search: search),
                  !Self.isCancellation(error) else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "更多文件加载失败"
        }
    }

    func createDirectory(name: String) async {
        guard let id = currentDirectory?.id else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            errorMessage = "文件夹名称不能为空"
            return
        }
        // [修改] macOS 新建目录输入上限为 10 个字，iOS 状态层同步拦截超长请求。
        guard value.count <= 10 else {
            errorMessage = "文件夹名称最多 10 个字"
            return
        }
        do { try await repository.createDirectory(parentId: id, name: value); await refreshAfterMutation() }
        catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? "新建文件夹失败" }
    }

    @discardableResult
    func rename(_ entry: DriveFileEntry, name: String) async -> Bool {
        // [修改] 根目录属于账号级入口，禁止客户端发起结构性修改。
        guard entry.isFile || !isRootDirectory(entry.id) else {
            errorMessage = "根目录不能重命名"
            return false
        }
        let editedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // [修改] 文件重命名只允许填写主文件名，禁止替换扩展名导致文件类型和播放入口失效。
        if entry.isFile, DriveFileNameRules.containsRegisteredExtension(editedName) {
            errorMessage = "文件名称不能包含扩展名"
            return false
        }
        // [修改] 文件未填写扩展名时自动保留原扩展名；目录仍按原输入重命名。
        let value = entry.isFile
            ? DriveFileNameRules.applyingPreservedExtension(to: editedName, originalFileName: entry.name)
            : editedName
        guard !value.isEmpty else {
            errorMessage = "名称不能为空"
            return false
        }
        do {
            if entry.isFile { try await repository.renameFile(id: entry.id, name: value) }
            else { try await repository.renameDirectory(id: entry.id, name: value) }
            if entry.isFile { await transferManager?.removeCachedFile(remoteFileId: entry.id) }
            await refreshAfterMutation()
            return true
        } catch {
            guard !Self.isCancellation(error) else { return false }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "重命名失败"
            return false
        }
    }

    @discardableResult
    func delete(_ entry: DriveFileEntry) async -> Bool {
        guard entry.isFile || !isRootDirectory(entry.id) else {
            errorMessage = "根目录不能删除"
            return false
        }
        do {
            // [修改] net-server 会拒绝删除仍含有效文件的目录，目录删除前先递归清空全部分页文件。
            try await deleteEntryRecursively(entry)
            selectedEntryIDs.remove(entry.id)
            await refreshAfterMutation()
            return true
        } catch {
            guard !Self.isCancellation(error) else { return false }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "删除失败"
            return false
        }
    }

    func moveDirectory(_ directory: DriveFileEntry, targetParentId: Int64) async {
        guard !directory.isFile else { return }
        guard !isRootDirectory(directory.id) else {
            errorMessage = "根目录不能移动"
            return
        }
        guard !invalidMoveTargetIDs(for: directory).contains(targetParentId) else {
            errorMessage = "不能移动到自身或子文件夹"
            return
        }
        do {
            try await repository.moveDirectory(id: directory.id, targetParentId: targetParentId)
            await refreshAfterMutation()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "移动文件夹失败"
        }
    }

    // [修改] 移动弹窗可能持有懒加载前的旧节点，排除目标必须回到当前目录树重新收集自身和全部子孙。
    func invalidMoveTargetIDs(for directory: DriveFileEntry) -> Set<Int64> {
        let latestDirectory = Self.path(to: directory.id, in: directoryRoots)?.last ?? directory
        var result = Set<Int64>()
        Self.collectDirectoryIDs(in: [latestDirectory], into: &result)
        return result
    }

    func loadDetail(for entry: DriveFileEntry) async -> DriveFileEntry? {
        guard entry.isFile else { return entry }
        do { return try await repository.fileDetail(id: entry.id) }
        catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "文件详情加载失败"
            // [修改] 详情接口失败时保留列表已有元数据，避免详情页直接空白。
            return entry
        }
    }

    func preview(_ entry: DriveFileEntry, reportsError: Bool = true) async -> URL? {
        guard entry.isFile, let transferManager else {
            // [修改] 自动缩略图失败时只回退图标，用户主动预览时才显示错误。
            if reportsError { errorMessage = "当前账号没有可用的文件传输凭据" }
            return nil
        }
        do {
            // [修改] 预览使用缓存下载，不创建传输中心记录。
            return try await transferManager.previewFile(
                remoteFileId: entry.id,
                fileName: entry.name,
                fileSize: entry.size ?? 0
            )
        } catch {
            if reportsError {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "文件预览加载失败"
            }
            return nil
        }
    }

    func toggleSelection(_ entry: DriveFileEntry) {
        if selectedEntryIDs.contains(entry.id) { selectedEntryIDs.remove(entry.id) }
        else { selectedEntryIDs.insert(entry.id) }
    }

    func selectAll() {
        selectedEntryIDs = Set(visibleEntries.map(\.id))
    }

    func clearSelection() {
        selectedEntryIDs.removeAll()
    }

    @discardableResult
    func deleteSelected() async -> [DriveFileEntry] {
        guard !isBatchOperating else { return [] }
        let targets = selectedEntries
        guard !targets.isEmpty else { return [] }
        let targetIDs = Set(targets.map(\.id))
        isBatchOperating = true
        defer { isBatchOperating = false }
        var failedIDs = Set<Int64>()
        var cancelledIDs = Set<Int64>()
        var failedNames: [String] = []
        var deletedEntries: [DriveFileEntry] = []
        for entry in targets {
            do {
                // [修改] 每个选中目录作为一个失败单元；任一子文件失败时不再删除父目录，并保留该目录供重试。
                try await deleteEntryRecursively(entry)
                deletedEntries.append(entry)
            } catch {
                if Self.isCancellation(error) {
                    cancelledIDs.insert(entry.id)
                } else {
                    failedIDs.insert(entry.id)
                    failedNames.append(entry.name)
                }
            }
        }
        // [修改] 只结算本次快照，操作期间后来选中的其他项目必须保留；失败和取消项继续选中。
        selectedEntryIDs.subtract(targetIDs)
        selectedEntryIDs.formUnion(failedIDs.union(cancelledIDs))
        await refreshAfterMutation()
        if !failedNames.isEmpty {
            // [修改] 批量删除不中断后续项目，并明确保留失败项供用户重试。
            errorMessage = "\(failedNames.count) 个项目删除失败：\(failedNames.joined(separator: "、"))"
        }
        return deletedEntries
    }

    // [修改] 网盘导入和下载统一进入持久化传输中心。
    func upload(sourceURL: URL) async {
        await upload(sourceURLs: [sourceURL])
    }

    // [修改] 多选文件并发提交，所有记录先落盘，实际执行并发由 TransferManager 控制。
    func upload(sourceURLs: [URL]) async {
        guard !sourceURLs.isEmpty else { return }
        guard let directoryId = currentDirectory?.id else {
            // [修改] 空态选完文件后明确提示，不再静默失败。
            errorMessage = "网盘目录尚未加载，请稍后再试"
            return
        }
        guard !isRootDirectory(directoryId) else {
            errorMessage = "根目录不能直接上传，请先进入子文件夹"
            return
        }
        guard let transferManager else {
            errorMessage = "当前账号没有可用的文件传输凭据"
            return
        }
        beginTransferOperation()
        defer { endTransferOperation() }
        let outcomes = await withTaskGroup(of: UploadOutcome.self, returning: [UploadOutcome].self) { group in
            for sourceURL in sourceURLs {
                group.addTask {
                    let scoped = sourceURL.startAccessingSecurityScopedResource()
                    defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
                    do {
                        _ = try await transferManager.upload(
                            sourceURL: sourceURL,
                            targetDirectoryId: directoryId,
                            uploadPurpose: "CLOUD_FILE",
                            batchId: nil
                        )
                        return UploadOutcome(succeeded: true, isCancelled: false, errorMessage: nil)
                    } catch {
                        return UploadOutcome(
                            succeeded: false,
                            isCancelled: Self.isCancellation(error),
                            errorMessage: (error as? LocalizedError)?.errorDescription
                        )
                    }
                }
            }
            var values: [UploadOutcome] = []
            for await outcome in group { values.append(outcome) }
            return values
        }
        if outcomes.contains(where: \.succeeded) {
            await refreshAfterMutation()
        }
        let failures = outcomes.filter { !$0.succeeded && !$0.isCancelled }
        if failures.count == 1 {
            errorMessage = failures[0].errorMessage ?? "文件上传失败"
        } else if !failures.isEmpty {
            errorMessage = "\(failures.count) 个文件上传失败，可在传输中心重试"
        }
    }

    func downloadSelected(to destinationDirectory: URL, destinationDirectoryBookmark: Data? = nil) async -> [URL] {
        guard !isBatchOperating else { return [] }
        guard let transferManager else {
            errorMessage = "当前账号没有可用的文件传输凭据"
            return []
        }
        let targets = selectedEntries
        guard !targets.isEmpty else { return [] }
        let targetIDs = Set(targets.map(\.id))
        isBatchOperating = true
        defer { isBatchOperating = false }
        beginTransferOperation()
        defer { endTransferOperation() }
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            errorMessage = "下载目录创建失败"
            return []
        }

        // [修改] 文件和目录共享根目录占位集合，避免同名文件、目录或 `.part` 任务互相覆盖。
        var occupiedNameKeys = Self.occupiedNameKeys(in: destinationDirectory)
        var preparedTargets: [PreparedDownloadTarget] = []
        var plannedFiles: [PlannedFileDownload] = []
        var preparationFailedIDs = Set<Int64>()
        var preparationCancelledIDs = Set<Int64>()

        for entry in targets {
            do {
                if entry.isFile {
                    let destination = Self.uniqueDestinationURL(
                        fileName: entry.name,
                        directory: destinationDirectory,
                        occupiedNameKeys: &occupiedNameKeys
                    )
                    preparedTargets.append(.init(ownerID: entry.id, directoryURL: nil))
                    plannedFiles.append(.init(ownerID: entry.id, entry: entry, destinationURL: destination))
                } else {
                    let snapshot = try await recursiveDirectorySnapshot(
                        entry,
                        ancestorIDs: []
                    )
                    let rootURL = Self.uniqueDirectoryURL(
                        directoryName: entry.name,
                        parentDirectory: destinationDirectory,
                        occupiedNameKeys: &occupiedNameKeys
                    )
                    var directoryPlans: [PlannedFileDownload] = []
                    try Self.materializeDownloadPlans(
                        snapshot,
                        at: rootURL,
                        ownerID: entry.id,
                        into: &directoryPlans
                    )
                    preparedTargets.append(.init(ownerID: entry.id, directoryURL: rootURL))
                    plannedFiles.append(contentsOf: directoryPlans)
                }
            } catch {
                if Self.isCancellation(error) {
                    preparationCancelledIDs.insert(entry.id)
                } else {
                    preparationFailedIDs.insert(entry.id)
                }
            }
        }

        let outcomes = await withTaskGroup(of: DownloadOutcome.self, returning: [DownloadOutcome].self) { group in
            for plan in plannedFiles {
                group.addTask {
                    do {
                        let result = try await transferManager.downloadUnique(
                            remoteFileId: plan.entry.id,
                            fileName: plan.entry.name,
                            fileSize: plan.entry.size ?? 0,
                            suggestedDestinationURL: plan.destinationURL,
                            destinationDirectoryBookmark: destinationDirectoryBookmark
                        )
                        return DownloadOutcome(
                            ownerID: plan.ownerID,
                            remoteFileID: plan.entry.id,
                            destinationURL: result.destinationURL,
                            isCancelled: false
                        )
                    } catch {
                        return DownloadOutcome(
                            ownerID: plan.ownerID,
                            remoteFileID: plan.entry.id,
                            destinationURL: nil,
                            isCancelled: Self.isCancellation(error)
                        )
                    }
                }
            }
            var values: [DownloadOutcome] = []
            for await outcome in group { values.append(outcome) }
            return values
        }

        let failedTransferIDs = Set(
            outcomes
                .filter { !$0.isCancelled && $0.destinationURL == nil }
                .map(\.ownerID)
        )
        let incompleteTransferIDs = Set(outcomes.filter { $0.destinationURL == nil }.map(\.ownerID))
        let incompleteIDs = preparationFailedIDs
            .union(preparationCancelledIDs)
            .union(incompleteTransferIDs)
        // [修改] 完成时只更新本次快照；取消和失败项目保留，期间新增的选择不被旧结果覆盖。
        selectedEntryIDs.subtract(targetIDs)
        selectedEntryIDs.formUnion(incompleteIDs)
        if !preparationFailedIDs.isEmpty, failedTransferIDs.isEmpty {
            errorMessage = "\(preparationFailedIDs.count) 个项目准备下载失败，请在当前页面重试"
        } else if preparationFailedIDs.isEmpty, !failedTransferIDs.isEmpty {
            errorMessage = "\(failedTransferIDs.count) 个项目下载失败，可在传输中心重试"
        } else if !preparationFailedIDs.isEmpty, !failedTransferIDs.isEmpty {
            errorMessage = "\(preparationFailedIDs.count) 个项目准备下载失败，请在当前页面重试；\(failedTransferIDs.count) 个项目传输失败，可在传输中心重试"
        }

        // [修改] 目录只有全部子文件完成后才作为一个完成结果返回；取消项不报错，也不伪装成成功。
        return preparedTargets.compactMap { target in
            guard !incompleteIDs.contains(target.ownerID) else { return nil }
            if let directoryURL = target.directoryURL { return directoryURL }
            return outcomes.first {
                $0.ownerID == target.ownerID && $0.remoteFileID == target.ownerID
            }?.destinationURL
        }
    }

    func download(_ entry: DriveFileEntry, destinationURL: URL, destinationDirectoryBookmark: Data? = nil) async -> URL? {
        guard entry.isFile, let transferManager else {
            errorMessage = "当前账号没有可用的文件传输凭据"
            return nil
        }
        beginTransferOperation()
        defer { endTransferOperation() }
        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try await transferManager.downloadUnique(
                remoteFileId: entry.id,
                fileName: entry.name,
                fileSize: entry.size ?? 0,
                suggestedDestinationURL: destinationURL,
                destinationDirectoryBookmark: destinationDirectoryBookmark
            )
            return result.destinationURL
        } catch {
            guard !Self.isCancellation(error) else { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "文件下载失败"
            return nil
        }
    }

    func clearError() { errorMessage = nil }

    // [修改] 视图层遇到本地下载目录授权失效时复用网盘错误提示，而不是静默回退。
    func reportError(_ message: String) {
        errorMessage = message
    }

    // [修改] 多个上传完成事件在 300ms 内合并成一次目录刷新，重试上传同样生效。
    func scheduleRefreshAfterTransferCompletion() {
        completionRefreshTask?.cancel()
        completionRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            await self.refreshAfterMutation()
        }
    }

    private func loadCurrent() async {
        guard currentDirectory != nil else { return }
        let generation = beginContentLoad()
        errorMessage = nil
        defer { finishContentLoad(generation) }
        do {
            try await reloadFirstPage(generation: generation)
        } catch {
            guard contentGeneration == generation, !Self.isCancellation(error) else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "网盘加载失败"
        }
    }

    private var currentDirectories: [DriveFileEntry] {
        (currentDirectory?.children ?? []).filter { !$0.isFile }
    }

    private func refreshTree(preserving directoryId: Int64?, generation: UInt64) async throws -> Bool {
        let preservedPathIDs = path.map(\.id)
        var refreshedRoots = try await repository.roots()
        guard contentGeneration == generation else { return false }
        directoryTreeGeneration &+= 1
        let treeGeneration = directoryTreeGeneration
        var refreshedLoadedDirectoryIDs = Self.preloadedDirectoryIDs(in: refreshedRoots)
        let preferredId = directoryId ?? refreshedRoots.first?.id

        // [修改] 根接口返回浅树时，沿刷新前的目录路径逐层恢复祖先，深层刷新不能跳回根目录。
        if let preferredId,
           Self.path(to: preferredId, in: refreshedRoots) == nil,
           preservedPathIDs.last == preferredId,
           preservedPathIDs.count > 1 {
            for index in 0..<(preservedPathIDs.count - 1) {
                let parentID = preservedPathIDs[index]
                let childID = preservedPathIDs[index + 1]
                if Self.path(to: childID, in: refreshedRoots) != nil { continue }
                guard let parent = Self.path(to: parentID, in: refreshedRoots)?.last,
                      parent.hasChildren,
                      parent.children.isEmpty else { break }
                let children = try await repository.directoryChildren(id: parentID)
                guard contentGeneration == generation,
                      directoryTreeGeneration == treeGeneration else { return false }
                refreshedRoots = Self.replacingChildren(
                    in: refreshedRoots,
                    directoryId: parentID,
                    children: children
                )
                refreshedLoadedDirectoryIDs.insert(parentID)
            }
        }

        guard contentGeneration == generation,
              directoryTreeGeneration == treeGeneration else { return false }
        directoryRoots = refreshedRoots
        loadedDirectoryIDs = refreshedLoadedDirectoryIDs
        if let preferredId, let resolvedPath = Self.path(to: preferredId, in: refreshedRoots) {
            path = resolvedPath
            currentDirectory = resolvedPath.last
        } else if let root = refreshedRoots.first {
            path = [root]
            currentDirectory = root
        } else {
            path = []
            currentDirectory = nil
            files = []
        }
        return true
    }

    private func reloadFirstPage(generation: UInt64) async throws {
        guard contentGeneration == generation else { return }
        guard let directoryId = currentDirectory?.id else {
            files = []
            currentPage = 0
            totalPages = 0
            totalCount = 0
            return
        }
        let search = activeSearch
        let page = try await repository.listFiles(
            directoryId: directoryId,
            page: 1,
            pageSize: pageSize,
            search: search
        )
        // [修改] 请求返回时再次核对版本、目录和搜索条件，旧响应不能写进新页面。
        guard isCurrentContent(generation: generation, directoryId: directoryId, search: search) else { return }
        files = Self.deduplicating(page.records.filter(\.isFile))
        applyPagination(page)
    }

    private func applyPagination(_ page: DrivePage) {
        currentPage = page.currentPage
        totalPages = page.totalPages
        totalCount = page.totalCount
    }

    private func refreshAfterMutation() async {
        let currentId = currentDirectory?.id
        let generation = beginContentLoad()
        defer { finishContentLoad(generation) }
        do {
            guard try await refreshTree(preserving: currentId, generation: generation) else { return }
            if let directoryId = currentDirectory?.id {
                try await fetchDirectoryChildrenIfNeeded(id: directoryId, treeGeneration: directoryTreeGeneration)
            }
            try await reloadFirstPage(generation: generation)
        } catch {
            guard contentGeneration == generation, !Self.isCancellation(error) else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "网盘刷新失败"
        }
    }

    private func beginContentLoad() -> UInt64 {
        // [修改] 切目录、搜索或重新加载时立即撤销旧刷新状态，旧响应仍由令牌和内容版本双重拦截。
        refreshGeneration &+= 1
        isRefreshing = false
        contentGeneration &+= 1
        loadingGeneration = contentGeneration
        nextPageGeneration = nil
        isLoading = true
        isLoadingNextPage = false
        return contentGeneration
    }

    private func finishContentLoad(_ generation: UInt64) {
        guard loadingGeneration == generation else { return }
        loadingGeneration = nil
        isLoading = false
    }

    private func isCurrentContent(generation: UInt64, directoryId: Int64, search: String) -> Bool {
        contentGeneration == generation
            && currentDirectory?.id == directoryId
            && activeSearch == search
    }

    private func isCurrentRefresh(
        _ refreshToken: UInt64,
        contentGeneration: UInt64,
        directoryId: Int64,
        search: String
    ) -> Bool {
        refreshGeneration == refreshToken
            && isCurrentContent(generation: contentGeneration, directoryId: directoryId, search: search)
    }

    private func finishRefresh(_ refreshToken: UInt64) {
        guard refreshGeneration == refreshToken else { return }
        isRefreshing = false
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? RequestResponseError) == .cancelled
    }

    private func beginTransferOperation() {
        activeTransferOperations += 1
        isTransferring = true
    }

    private func endTransferOperation() {
        activeTransferOperations = max(0, activeTransferOperations - 1)
        isTransferring = activeTransferOperations > 0
    }

    // [修改] 下载和删除共用同一份远端目录快照，确保递归层级和分页语义完全一致。
    private func recursiveDirectorySnapshot(
        _ directory: DriveFileEntry,
        ancestorIDs: Set<Int64>
    ) async throws -> RecursiveDirectorySnapshot {
        guard !directory.isFile,
              directory.id > 0,
              !ancestorIDs.contains(directory.id) else {
            throw DriveRepositoryError.invalidResponse
        }
        let nextAncestorIDs = ancestorIDs.union([directory.id])
        let files = try await allFiles(in: directory.id)
        let childDirectories = try await repository.directoryChildren(id: directory.id)
        var childSnapshots: [RecursiveDirectorySnapshot] = []
        for child in childDirectories {
            guard !child.isFile, child.parentId == directory.id else {
                throw DriveRepositoryError.invalidResponse
            }
            childSnapshots.append(
                try await recursiveDirectorySnapshot(child, ancestorIDs: nextAncestorIDs)
            )
        }
        return RecursiveDirectorySnapshot(directory: directory, files: files, children: childSnapshots)
    }

    // [修改] 目录操作必须把服务端分页全部读完，不能只处理第一页的 20 个文件。
    private func allFiles(in directoryID: Int64) async throws -> [DriveFileEntry] {
        var requestedPage = 1
        var result: [DriveFileEntry] = []
        var seenFileIDs = Set<Int64>()
        while true {
            let page = try await repository.listFiles(
                directoryId: directoryID,
                page: requestedPage,
                pageSize: pageSize,
                search: ""
            )
            for entry in page.records {
                guard entry.isFile, entry.parentId == directoryID, seenFileIDs.insert(entry.id).inserted else {
                    throw DriveRepositoryError.invalidResponse
                }
                result.append(entry)
            }
            let hasMorePages = requestedPage < page.totalPages
            let hasMoreRecords = Int64(result.count) < page.totalCount
            guard hasMorePages || hasMoreRecords else { return result }
            guard !page.records.isEmpty else { throw DriveRepositoryError.invalidResponse }
            requestedPage += 1
        }
    }

    private func deleteEntryRecursively(_ entry: DriveFileEntry) async throws {
        if entry.isFile {
            try await repository.deleteFile(id: entry.id)
            await transferManager?.removeCachedFile(remoteFileId: entry.id)
            return
        }

        let snapshot = try await recursiveDirectorySnapshot(entry, ancestorIDs: [])
        // [修改] 先删除整棵目录树的全部文件，任何一步失败都禁止继续删除父目录。
        for file in snapshot.flattenedFiles {
            try await repository.deleteFile(id: file.id)
            await transferManager?.removeCachedFile(remoteFileId: file.id)
        }
        try await repository.deleteDirectory(id: entry.id)
    }

    private static func path(to id: Int64, in roots: [DriveFileEntry]) -> [DriveFileEntry]? {
        for root in roots {
            if root.id == id { return [root] }
            if let childPath = path(to: id, in: root.children) { return [root] + childPath }
        }
        return nil
    }

    private func fetchDirectoryChildrenIfNeeded(id: Int64, treeGeneration: UInt64) async throws {
        guard let directory = Self.path(to: id, in: directoryRoots)?.last,
              directory.hasChildren,
              directory.children.isEmpty,
              !loadedDirectoryIDs.contains(id),
              !loadingDirectoryIDs.contains(id) else { return }
        loadingDirectoryIDs.insert(id)
        defer { loadingDirectoryIDs.remove(id) }
        let children = try await repository.directoryChildren(id: id)
        guard self.directoryTreeGeneration == treeGeneration else { return }
        directoryRoots = Self.replacingChildren(in: directoryRoots, directoryId: id, children: children)
        loadedDirectoryIDs.insert(id)
        if let currentID = currentDirectory?.id,
           let refreshedPath = Self.path(to: currentID, in: directoryRoots) {
            path = refreshedPath
            currentDirectory = refreshedPath.last
        }
    }

    private func isRootDirectory(_ id: Int64) -> Bool {
        directoryRoots.contains { $0.id == id }
    }

    private static func replacingChildren(
        in entries: [DriveFileEntry],
        directoryId: Int64,
        children: [DriveFileEntry]
    ) -> [DriveFileEntry] {
        entries.map { entry in
            if entry.id == directoryId { return entry.replacingChildren(children) }
            let updatedChildren = replacingChildren(in: entry.children, directoryId: directoryId, children: children)
            return updatedChildren == entry.children ? entry : entry.replacingChildren(updatedChildren)
        }
    }

    private static func preloadedDirectoryIDs(in entries: [DriveFileEntry]) -> Set<Int64> {
        var result = Set<Int64>()
        for entry in entries where !entry.isFile {
            if !entry.children.isEmpty { result.insert(entry.id) }
            result.formUnion(preloadedDirectoryIDs(in: entry.children))
        }
        return result
    }

    private static func deduplicating(_ values: [DriveFileEntry]) -> [DriveFileEntry] {
        var seen = Set<Int64>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private static func collectDirectoryIDs(in entries: [DriveFileEntry], into result: inout Set<Int64>) {
        for entry in entries where !entry.isFile {
            result.insert(entry.id)
            collectDirectoryIDs(in: entry.children, into: &result)
        }
    }

    private static func uniqueDestinationURL(
        fileName: String,
        directory: URL,
        occupiedNameKeys: inout Set<String>
    ) -> URL {
        // [修改] 批量下载先把服务端名称收敛为单个本地文件名，确保始终落在用户选择目录内。
        let safeFileName = TransferFileName.safeLocalName(fileName, fallback: "download")
        let source = safeFileName as NSString
        let stem = source.deletingPathExtension
        let fileExtension = source.pathExtension
        var candidate = safeFileName
        var index = 1
        // [修改] 完整文件和 .part 断点文件都占用名称，避免覆盖可继续的下载任务。
        func isOccupied(_ name: String) -> Bool {
            let destination = directory.appendingPathComponent(name)
            return occupiedNameKeys.contains(TransferFileName.collisionKey(name))
                || occupiedNameKeys.contains(TransferFileName.collisionKey("\(name).part"))
                || FileManager.default.fileExists(atPath: destination.path)
                || FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path)
        }
        while isOccupied(candidate) {
            candidate = fileExtension.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(fileExtension)"
            index += 1
        }
        occupiedNameKeys.insert(TransferFileName.collisionKey(candidate))
        occupiedNameKeys.insert(TransferFileName.collisionKey("\(candidate).part"))
        return directory.appendingPathComponent(candidate)
    }

    private static func occupiedNameKeys(in directory: URL) -> Set<String> {
        Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .map(TransferFileName.collisionKey)
        )
    }

    private static func uniqueDirectoryURL(
        directoryName: String,
        parentDirectory: URL,
        occupiedNameKeys: inout Set<String>
    ) -> URL {
        let safeName = TransferFileName.safeLocalName(directoryName, fallback: "download")
        var candidate = safeName
        var index = 1
        while occupiedNameKeys.contains(TransferFileName.collisionKey(candidate))
            || FileManager.default.fileExists(atPath: parentDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(safeName) (\(index))"
            index += 1
        }
        occupiedNameKeys.insert(TransferFileName.collisionKey(candidate))
        return parentDirectory.appendingPathComponent(candidate, isDirectory: true)
    }

    private static func materializeDownloadPlans(
        _ snapshot: RecursiveDirectorySnapshot,
        at directoryURL: URL,
        ownerID: Int64,
        into plans: inout [PlannedFileDownload]
    ) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var occupiedNameKeys = occupiedNameKeys(in: directoryURL)
        for file in snapshot.files {
            let destination = uniqueDestinationURL(
                fileName: file.name,
                directory: directoryURL,
                occupiedNameKeys: &occupiedNameKeys
            )
            plans.append(.init(ownerID: ownerID, entry: file, destinationURL: destination))
        }
        for child in snapshot.children {
            let childURL = uniqueDirectoryURL(
                directoryName: child.directory.name,
                parentDirectory: directoryURL,
                occupiedNameKeys: &occupiedNameKeys
            )
            try materializeDownloadPlans(child, at: childURL, ownerID: ownerID, into: &plans)
        }
    }
}

private struct DownloadOutcome: Sendable {
    let ownerID: Int64
    let remoteFileID: Int64
    let destinationURL: URL?
    let isCancelled: Bool
}

private struct PlannedFileDownload: Sendable {
    let ownerID: Int64
    let entry: DriveFileEntry
    let destinationURL: URL
}

private struct PreparedDownloadTarget: Sendable {
    let ownerID: Int64
    let directoryURL: URL?
}

private struct RecursiveDirectorySnapshot: Sendable {
    let directory: DriveFileEntry
    let files: [DriveFileEntry]
    let children: [RecursiveDirectorySnapshot]

    var flattenedFiles: [DriveFileEntry] {
        files + children.flatMap(\.flattenedFiles)
    }
}

private struct UploadOutcome: Sendable {
    let succeeded: Bool
    let isCancelled: Bool
    let errorMessage: String?
}

extension TransferManager: DriveTransferManaging {}

private extension DriveFileEntry {
    func replacingChildren(_ children: [DriveFileEntry]) -> DriveFileEntry {
        DriveFileEntry(
            id: id,
            parentId: parentId,
            name: name,
            path: path,
            parentDirectoryName: parentDirectoryName,
            size: size,
            fileType: fileType,
            isFile: isFile,
            // [修改] 子目录接口已明确返回结果时，以实际子节点为准，空数组必须成为叶子。
            hasChildren: !children.isEmpty,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            md5: md5,
            children: children
        )
    }
}
