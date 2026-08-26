import Foundation
import Observation

enum TransferDirectionFilter: String, CaseIterable, Sendable {
    case all
    case upload
    case download
}

enum TransferStatusFilter: String, CaseIterable, Sendable {
    case all
    case active
    case paused
    case completed
    case failed
    case cancelled
}

@MainActor
@Observable
final class TransferCenterViewModel {
    private(set) var tasks: [TransferTaskRecord] = []
    private(set) var errorMessage: String?
    var directionFilter: TransferDirectionFilter = .all
    // [修改] 默认展示全部状态，暂停或完成后仍保留在传输中心；用户仍可通过状态菜单主动筛选。
    var statusFilter: TransferStatusFilter = .all

    private let store: FileTransferTaskStore
    private let manager: (any TransferManaging)?
    private let userId: Int64
    private let serverScopeID: String?

    init(store: FileTransferTaskStore, manager: (any TransferManaging)?, userId: Int64, serverScopeID: String? = nil) {
        self.store = store
        self.manager = manager
        self.userId = userId
        self.serverScopeID = serverScopeID
    }

    var filteredTasks: [TransferTaskRecord] {
        tasks.filter { task in
            directionMatches(task) && statusMatches(task)
        }
    }

    var activeCount: Int { tasks.filter { $0.status.isActive }.count }
    var completedCount: Int { tasks.filter { $0.status == .completed }.count }
    // [修改] 批量取消入口同时覆盖进行中、暂停和失败任务。
    var cancellableCount: Int { tasks.filter(canCancel).count }

    func load() async {
        tasks = ownedTasks(await store.all())
        // [修改] 任务文件恢复告警只在传输中心首次加载时提示一次。
        if let notice = await store.consumeRecoveryNotice() {
            errorMessage = notice.message
        }
        await store.publishCurrent()
    }

    func observe() async {
        for await values in store.taskStream() {
            // [修改] 传输中心按登录用户过滤，避免显示其他账号的文件名、路径和进度。
            tasks = ownedTasks(values)
        }
    }

    func pause(_ task: TransferTaskRecord) async {
        guard owns(task), let manager else { return }
        await manager.pause(task.id)
    }

    func retry(_ task: TransferTaskRecord) async {
        guard owns(task), let manager else { return }
        await manager.retry(task.id)
    }

    // [修改] 失败任务允许用户放弃，转成已取消后即可随“清理已完成”一起删除。
    func canCancel(_ task: TransferTaskRecord) -> Bool {
        owns(task) && (task.status.isActive || task.status == .failed)
    }

    func cancel(_ task: TransferTaskRecord) async {
        guard canCancel(task), let manager else { return }
        await manager.cancel(task.id)
    }

    func cancelAll() async {
        guard let manager else { return }
        await manager.cancelAll()
    }

    func clearCompleted() async {
        // [修改] 保留旧入口语义，只清理状态为「已完成」的任务。
        let completedTaskIDs = Set(ownedTasks(await store.all()).filter {
            $0.status == .completed
        }.map(\.id))
        guard !completedTaskIDs.isEmpty else { return }
        do {
            if let manager {
                try await manager.cleanupCompletedArtifacts(taskIDs: completedTaskIDs)
            }
            try await store.clearCompleted(
                taskIDs: completedTaskIDs,
                userId: userId,
                serverScopeID: serverScopeID
            )
        } catch {
            errorMessage = "清理传输记录失败"
        }
    }

    // [修改] 一次清理当前账号当前服务下的已完成、失败和已取消任务，不碰进行中和暂停任务。
    func clearFinished() async {
        let finishedTaskIDs = Set(ownedTasks(await store.all()).filter {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }.map(\.id))
        guard !finishedTaskIDs.isEmpty else { return }
        do {
            if let manager {
                try await manager.cleanupCompletedArtifacts(taskIDs: finishedTaskIDs)
            }
            try await store.clearFinished(
                taskIDs: finishedTaskIDs,
                userId: userId,
                serverScopeID: serverScopeID
            )
        } catch {
            errorMessage = "清理传输记录失败"
        }
    }

    func clearError() { errorMessage = nil }

    // [修改] 已完成下载从传输中心直接打开/分享，并重新解析持久化目录授权。
    func fileAccess(for task: TransferTaskRecord) -> TransferScopedURLAccess? {
        guard task.direction == .download,
              task.status == .completed,
              let destinationPath = task.destinationPath else { return nil }
        do {
            let access = try TransferDestinationResolver.fileAccess(
                destinationPath: destinationPath,
                destinationRelativePath: task.destinationRelativePath,
                bookmarkData: task.destinationDirectoryBookmark
            )
            if let refreshedBookmark = access.refreshedBookmarkData {
                // [修改] 用户从传输中心打开文件时同样补写过期授权。
                Task { try? await store.setDestinationDirectoryBookmark(id: task.id, bookmarkData: refreshedBookmark) }
            }
            guard FileManager.default.fileExists(atPath: access.url.path) else {
                errorMessage = "下载文件不存在，无法打开"
                return nil
            }
            return access
        } catch {
            errorMessage = "下载目录授权已失效，请重新下载"
            return nil
        }
    }

    private func directionMatches(_ task: TransferTaskRecord) -> Bool {
        switch directionFilter {
        case .all: true
        case .upload: task.direction == .upload
        case .download: task.direction == .download
        }
    }

    private func statusMatches(_ task: TransferTaskRecord) -> Bool {
        switch statusFilter {
        case .all: true
        case .active: task.status.isExecuting
        case .paused: task.status == .paused || task.status == .pausedAuthentication
        case .completed: task.status == .completed
        case .failed: task.status == .failed
        case .cancelled: task.status == .cancelled
        }
    }

    private func ownedTasks(_ values: [TransferTaskRecord]) -> [TransferTaskRecord] {
        values.filter(owns)
    }

    private func owns(_ task: TransferTaskRecord) -> Bool {
        task.userId == userId && (serverScopeID == nil || task.serverScopeID == serverScopeID)
    }
}
