import Foundation
import Observation

@MainActor
@Observable
final class ProfileSettingsViewModel {
    private(set) var notificationStatus: NotificationPermissionStatus = .notDetermined
    private(set) var storageUsage: LocalStorageUsage = .zero
    private(set) var isLoading = false
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
            await refreshStorageUsage()
        } catch {
            errorMessage = "下载缓存清理失败"
        }
    }

    func clearChatBackgrounds() async {
        do {
            try await storageManager.clearChatBackgrounds()
            await refreshStorageUsage()
        } catch {
            errorMessage = "聊天背景清理失败"
        }
    }

    func clearError() { errorMessage = nil }

    private func refreshStorageUsage() async {
        do {
            storageUsage = try await storageManager.usage()
        } catch {
            errorMessage = "存储空间统计失败"
        }
    }
}
