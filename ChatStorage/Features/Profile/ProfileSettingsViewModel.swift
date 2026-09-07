import Foundation
import Observation

@MainActor
@Observable
final class ProfileSettingsViewModel {
    private(set) var notificationStatus: NotificationPermissionStatus = .notDetermined
    private(set) var storageUsage: LocalStorageUsage = .zero
    private(set) var isLoading = false
    private(set) var isClearingStorage = false
    private(set) var lastCleanupReleasedBytes: Int64?
    private(set) var errorMessage: String?

    private let notificationProvider: any NotificationPermissionProviding
    private let storageManager: any LocalStorageManaging

    init(
        notificationProvider: any NotificationPermissionProviding = SystemNotificationPermissionProvider(),
        storageManager: any LocalStorageManaging = LocalStorageManager()
    ) {
        self.notificationProvider = notificationProvider
        self.storageManager = storageManager
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        notificationStatus = await notificationProvider.status()
        await refreshStorageUsage()
    }

    func requestNotificationPermission() async {
        do {
            notificationStatus = try await notificationProvider.requestAuthorization()
        } catch {
            errorMessage = "通知权限申请失败"
        }
    }

    func clearDownloads() async {
        do {
            try await storageManager.clearDownloads()
            lastCleanupReleasedBytes = nil
            await refreshStorageUsage()
        } catch {
            errorMessage = "下载缓存清理失败"
        }
    }

    func clearChatBackgrounds() async {
        do {
            try await storageManager.clearChatBackgrounds()
            lastCleanupReleasedBytes = nil
            await refreshStorageUsage()
        } catch {
            errorMessage = "聊天背景清理失败"
        }
    }

    func clearReclaimableStorage() async {
        await clearReclaimableStorage(cleaningFinishedTransfers: {})
    }

    // [修改] 清理前后均扫描真实目录；已结束传输残留和缓存的释放量会合并展示。
    func clearReclaimableStorage(
        cleaningFinishedTransfers: @escaping @MainActor () async -> Void
    ) async {
        guard !isClearingStorage else { return }
        isClearingStorage = true
        errorMessage = nil
        defer { isClearingStorage = false }
        do {
            let beforeUsage = try await storageManager.usage()
            storageUsage = beforeUsage
            await cleaningFinishedTransfers()
            try await storageManager.clearReclaimableStorage()
            let usage = try await storageManager.usage()
            storageUsage = usage
            lastCleanupReleasedBytes = max(0, beforeUsage.totalBytes - usage.totalBytes)
        } catch {
            errorMessage = "本地存储清理失败"
        }
    }

    func clearCleanupResult() { lastCleanupReleasedBytes = nil }
    func clearError() { errorMessage = nil }

    private func refreshStorageUsage() async {
        do {
            storageUsage = try await storageManager.usage()
        } catch {
            errorMessage = "存储空间统计失败"
        }
    }
}
