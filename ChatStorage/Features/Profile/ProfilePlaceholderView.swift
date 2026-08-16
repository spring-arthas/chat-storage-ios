import PhotosUI
import SwiftUI
import UIKit

struct ProfilePlaceholderView: View {
    let user: AuthenticatedUser
    let authRepository: any AuthRepository
    let configuration: ServerConfiguration
    let preferences: ProfilePreferencesController
    let appLockController: AppLockController
    let transferStore: FileTransferTaskStore
    let transferManager: TransferManager?
    let userId: Int64
    let serverScopeID: String
    let onSaveConfiguration: (ServerConfiguration) async throws -> Void
    let onLogout: () async -> Void
    let onUserUpdated: (AuthenticatedUser) -> Void

    @State private var model = ProfileSettingsViewModel()
    @State private var transferModel: TransferCenterViewModel
    @State private var showsServerSettings = false
    @State private var showsLogoutConfirmation = false
    @State private var selectedAvatarPhoto: PhotosPickerItem?
    @State private var avatarData: String?
    @State private var isUpdatingAvatar = false
    @State private var avatarErrorMessage: String?

    init(
        user: AuthenticatedUser,
        authRepository: any AuthRepository,
        configuration: ServerConfiguration,
        preferences: ProfilePreferencesController,
        appLockController: AppLockController,
        transferStore: FileTransferTaskStore,
        transferManager: TransferManager?,
        userId: Int64,
        serverScopeID: String,
        onSaveConfiguration: @escaping (ServerConfiguration) async throws -> Void,
        onLogout: @escaping () async -> Void,
        onUserUpdated: @escaping (AuthenticatedUser) -> Void
    ) {
        self.user = user
        self.authRepository = authRepository
        self.configuration = configuration
        self.preferences = preferences
        self.appLockController = appLockController
        self.transferStore = transferStore
        self.transferManager = transferManager
        self.userId = userId
        self.serverScopeID = serverScopeID
        self.onSaveConfiguration = onSaveConfiguration
        self.onLogout = onLogout
        self.onUserUpdated = onUserUpdated
        _transferModel = State(initialValue: TransferCenterViewModel(
            store: transferStore,
            manager: transferManager,
            userId: userId,
            serverScopeID: serverScopeID
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                settingsSection
                transferCleanupSection
                logoutSection
            }
            // [修改] 去掉 List 默认的大块顶部滚动边距，让个人信息卡紧跟导航栏。
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(.compact)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            .task { await transferModel.load() }
            .task { await transferModel.observe() }
            .task { if avatarData == nil { avatarData = user.avatar } }
            .task(id: selectedAvatarPhoto) {
                guard let selectedAvatarPhoto, !isUpdatingAvatar else { return }
                guard let data = try? await selectedAvatarPhoto.loadTransferable(type: Data.self) else {
                    avatarErrorMessage = "无法读取所选图片"
                    return
                }
                await updateAvatar(data)
            }
            .sheet(isPresented: $showsServerSettings) {
                ServerSettingsView(configuration: configuration, onSave: onSaveConfiguration)
            }
            .confirmationDialog("确定退出当前账号？", isPresented: $showsLogoutConfirmation) {
                Button("退出登录", role: .destructive) { Task { await onLogout() } }
                Button("取消", role: .cancel) {}
            }
            .alert("设置操作失败", isPresented: errorIsPresented) {
                Button("知道了") {
                    model.clearError()
                    transferModel.clearError()
                }
            } message: {
                Text(model.errorMessage ?? transferModel.errorMessage ?? "请稍后重试")
            }
            .alert("头像更新失败", isPresented: Binding(
                get: { avatarErrorMessage != nil },
                set: { if !$0 { avatarErrorMessage = nil } }
            )) {
                Button("知道了") { avatarErrorMessage = nil }
            } message: {
                Text(avatarErrorMessage ?? "请稍后重试")
            }
        }
    }

    private var profileSection: some View {
        let displayName = user.nickname ?? user.username
        let currentAvatarData = avatarData
        return Section {
            HStack(spacing: 16) {
                PhotosPicker(selection: $selectedAvatarPhoto, matching: .images) {
                    // [修改] 头像按钮只捕获 Sendable 的快照值，避免 PhotosPicker 的 Sendable 闭包读取 MainActor 属性。
                    ProfileAvatarView(avatarData: currentAvatarData, displayName: displayName)
                }
                .disabled(isUpdatingAvatar)
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.nickname ?? user.username).font(.title3.bold())
                    Text("@\(user.username)").foregroundStyle(.secondary)
                    if let email = user.email, !email.isEmpty {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                    if isUpdatingAvatar {
                        Text("头像更新中…").font(.caption).foregroundStyle(AppTheme.primaryGreen)
                    }
                }
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("profile.header")
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var settingsSection: some View {
        Section("设置") {
            Button { showsServerSettings = true } label: {
                SettingsRow(title: "服务器", detail: "\(configuration.host):\(configuration.controlPort)", systemImage: "network")
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("profile.server")
            NavigationLink {
                NotificationSettingsView(model: model, preferences: preferences)
            } label: {
                SettingsRow(title: "通知", detail: model.notificationStatus.title, systemImage: "bell.fill")
            }
            NavigationLink {
                StorageSettingsView(model: model)
            } label: {
                SettingsRow(title: "存储空间", detail: formatted(model.storageUsage.totalBytes), systemImage: "internaldrive.fill")
            }
            NavigationLink {
                AppearanceSettingsView(preferences: preferences)
            } label: {
                SettingsRow(title: "外观", detail: preferences.appearance.title, systemImage: "paintpalette.fill")
            }
            NavigationLink {
                TransferSettingsView(
                    preferences: preferences,
                    transferManager: transferManager
                )
            } label: {
                SettingsRow(
                    title: "文件传输",
                    detail: preferences.wifiOnlyTransfers ? "仅 Wi-Fi 自动传输" : "允许当前可用网络",
                    systemImage: "arrow.up.arrow.down.circle.fill"
                )
            }
            .accessibilityIdentifier("profile.transfer-settings")
            NavigationLink {
                TransferCenterView(
                    store: transferStore,
                    manager: transferManager,
                    userId: userId,
                    serverScopeID: serverScopeID
                )
            } label: {
                SettingsRow(
                    title: "传输中心",
                    detail: "查看上传、下载和失败任务",
                    systemImage: "tray.full.fill"
                )
            }
            .accessibilityIdentifier("profile.transfer-center")
            NavigationLink {
                PrivacySettingsView(controller: appLockController)
            } label: {
                SettingsRow(title: "隐私与安全", detail: preferences.appLockEnabled ? "Face ID 已开启" : "未开启应用锁", systemImage: "lock.shield.fill")
            }
        }
    }

    private var transferCleanupSection: some View {
        Section("传输记录") {
            Button {
                Task { await transferModel.clearCompleted() }
            } label: {
                SettingsRow(
                    title: "清理已完成传输",
                    detail: "保留失败和未完成任务",
                    systemImage: "trash.slash.fill"
                )
            }
            .foregroundStyle(.primary)
            .disabled(!transferModel.tasks.contains { $0.status == .completed || $0.status == .cancelled })
            .accessibilityIdentifier("profile.clear-completed-transfers")
        }
    }

    // [修改] 头像解码、缩放和 JPEG 编码移出 MainActor，选择大图时不再卡住“我的”页面。
    private func updateAvatar(_ sourceData: Data) async {
        isUpdatingAvatar = true
        defer { isUpdatingAvatar = false }
        do {
            let data = try await ProfileAvatarImageProcessor.prepareJPEG(from: sourceData)
            let updated = try await authRepository.updateAvatar(
                avatarData: data.base64EncodedString(),
                avatarName: "avatar.jpg"
            )
            avatarData = updated.avatar
            onUserUpdated(updated)
        } catch {
            avatarErrorMessage = (error as? LocalizedError)?.errorDescription ?? "头像更新失败"
        }
    }

    private var logoutSection: some View {
        Section {
            Button("退出登录", role: .destructive) { showsLogoutConfirmation = true }
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil || transferModel.errorMessage != nil },
            set: {
                if !$0 {
                    model.clearError()
                    transferModel.clearError()
                }
            }
        )
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct TransferSettingsView: View {
    let preferences: ProfilePreferencesController
    let transferManager: TransferManager?

    var body: some View {
        Form {
            Section("自动传输") {
                Toggle("仅 Wi-Fi 自动传输", isOn: Binding(
                    get: { preferences.wifiOnlyTransfers },
                    set: { enabled in
                        preferences.setWifiOnlyTransfers(enabled)
                        Task { await transferManager?.setWifiOnlyTransfers(enabled) }
                    }
                ))
                .accessibilityIdentifier("profile.transfer.wifi-only")
                Text(preferences.wifiOnlyTransfers
                    ? "移动网络不会启动新任务，正在传输的任务会继续完成。"
                    : "新建和恢复任务可以使用当前可用网络。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("上传、下载进度会持久化；网络符合设置后，未完成任务会自动继续。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("文件传输")
    }
}

enum ProfileAvatarImageProcessor {
    enum ProcessingError: LocalizedError {
        case invalidImage
        case jpegEncodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: "无法读取所选图片"
            case .jpegEncodingFailed: "图片压缩失败"
            }
        }
    }

    // [修改] 与 Android 保持同一头像上限：最长边 1024px，JPEG 质量 0.85。
    static func prepareJPEG(from sourceData: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard let image = UIImage(data: sourceData) else {
                    throw ProcessingError.invalidImage
                }
                let maximumDimension: CGFloat = 1024
                let longest = max(image.size.width, image.size.height)
                let resized: UIImage
                if longest > maximumDimension {
                    let scale = maximumDimension / longest
                    let target = CGSize(
                        width: max(1, image.size.width * scale),
                        height: max(1, image.size.height * scale)
                    )
                    let format = UIGraphicsImageRendererFormat()
                    // [修改] 固定 1x 输出，否则 3x 设备会把 1024pt 再编码成 3072 像素。
                    format.scale = 1
                    resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                        image.draw(in: CGRect(origin: .zero, size: target))
                    }
                } else {
                    resized = image
                }
                guard let jpegData = resized.jpegData(compressionQuality: 0.85) else {
                    throw ProcessingError.jpegEncodingFailed
                }
                return jpegData
            }
        }.value
    }
}

// [修改] 头像渲染拆成值语义子视图，PhotosPicker 的 Sendable 闭包不再捕获 ProfilePlaceholderView。
private struct ProfileAvatarView: View {
    let avatarData: String?
    let displayName: String

    var body: some View {
        Group {
            if let data = avatarData.flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(AppTheme.primaryGreen.gradient)
                    Text(String(displayName.prefix(1)))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(5)
                .background(Circle().fill(AppTheme.primaryGreen))
        }
    }
}

private struct SettingsRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct NotificationSettingsView: View {
    let model: ProfileSettingsViewModel
    let preferences: ProfilePreferencesController

    var body: some View {
        Form {
            Section("系统权限") {
                LabeledContent("当前状态", value: model.notificationStatus.title)
                if model.notificationStatus == .notDetermined || model.notificationStatus == .denied {
                    Button("申请通知权限") { Task { await model.requestNotificationPermission() } }
                }
            }
            Section("消息内容") {
                Toggle("通知中显示消息预览", isOn: Binding(
                    get: { preferences.notificationPreviewEnabled },
                    set: { enabled in preferences.setNotificationPreviewEnabled(enabled) }
                ))
            }
            Section {
                Text("后台消息还需要服务端 APNs 注册接口和 Apple 推送凭据；未配置时，App 回到前台会继续同步遗漏消息。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("通知")
    }
}

private struct StorageSettingsView: View {
    let model: ProfileSettingsViewModel

    var body: some View {
        Form {
            Section("本地占用") {
                LabeledContent("下载与预览缓存", value: formatted(model.storageUsage.downloadBytes))
                LabeledContent("聊天背景", value: formatted(model.storageUsage.backgroundBytes))
                LabeledContent("断点传输文件", value: formatted(model.storageUsage.transferBytes))
                LabeledContent("合计", value: formatted(model.storageUsage.totalBytes))
            }
            Section("清理") {
                Button("清理下载与预览缓存", role: .destructive) { Task { await model.clearDownloads() } }
                    .disabled(model.storageUsage.downloadBytes == 0)
                Button("清理全部聊天背景", role: .destructive) { Task { await model.clearChatBackgrounds() } }
                    .disabled(model.storageUsage.backgroundBytes == 0)
            }
            Section {
                Text("断点传输文件由传输中心管理，未完成任务不会在这里被删除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("存储空间")
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct AppearanceSettingsView: View {
    let preferences: ProfilePreferencesController

    var body: some View {
        Form {
            Picker("显示模式", selection: Binding(
                get: { preferences.appearance },
                set: { appearance in preferences.setAppearance(appearance) }
            )) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.inline)
        }
        .navigationTitle("外观")
    }
}

private struct PrivacySettingsView: View {
    let controller: AppLockController

    var body: some View {
        Form {
            Section("应用锁") {
                Toggle("Face ID 应用锁", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { enabled in Task { await controller.setEnabled(enabled) } }
                ))
                .disabled(controller.isChanging)
                Text("开启后，App 进入后台再次回来时需要 Face ID 解锁。服务器密码不会保存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("隐私与安全")
        .alert("Face ID 操作失败", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.clearError() } }
        )) {
            Button("知道了") { controller.clearError() }
        } message: {
            Text(controller.errorMessage ?? "请稍后重试")
        }
    }
}
