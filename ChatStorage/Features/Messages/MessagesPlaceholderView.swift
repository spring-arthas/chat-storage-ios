import SwiftUI
// [修改] 固定搜索栏背景和角标使用 UIKit 系统语义色，自动适配明暗模式。
import UIKit

struct MessagesPlaceholderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MessagesViewModel
    @Binding private var totalUnreadCount: Int
    private let chatRepository: any ChatRepository
    private let user: AuthenticatedUser
    private let sampleMode: Bool
    private let attachmentUploader: (any ChatAttachmentUploading)?
    private let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    private let messageRouteStore: MessageNotificationRouteStore
    private let notificationCoordinator: MessageNotificationCoordinator
    private let notificationVisibility: MessageNotificationVisibilityState
    private let dynamicComposerRouteStore: DynamicComposerRouteStore
    private let onOpenDynamicComposer: () -> Void
    @State private var showsFriendManagement = false
    @State private var showsFriendRequests = false
    @State private var showsFavorites = false
    @State private var favoriteMessages: [ChatMessage] = []
    @State private var pendingRequestCount = 0
    @State private var path: [ChatFriend] = []

    init(repository: any FriendRepository, chatRepository: any ChatRepository, user: AuthenticatedUser, attachmentUploader: (any ChatAttachmentUploading)?, attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)? = nil, sampleMode: Bool, totalUnreadCount: Binding<Int>, messageRouteStore: MessageNotificationRouteStore = MessageNotificationRouteStore(), notificationCoordinator: MessageNotificationCoordinator? = nil, notificationVisibility: MessageNotificationVisibilityState = MessageNotificationVisibilityState(), dynamicComposerRouteStore: DynamicComposerRouteStore = DynamicComposerRouteStore(), onOpenDynamicComposer: @escaping () -> Void = {}) {
        _model = State(initialValue: MessagesViewModel(
            repository: repository,
            initialFriends: sampleMode ? PreviewFriends.all : []
        ))
        self.sampleMode = sampleMode
        self.chatRepository = chatRepository
        self.user = user
        self.attachmentUploader = attachmentUploader
        self.attachmentPreviewProvider = attachmentPreviewProvider
        self.messageRouteStore = messageRouteStore
        self.notificationCoordinator = notificationCoordinator ?? MessageNotificationCoordinator(
            center: SystemMessageNotificationCenter(),
            routeStore: messageRouteStore,
            previewEnabled: { true }
        )
        self.notificationVisibility = notificationVisibility
        self.dynamicComposerRouteStore = dynamicComposerRouteStore
        self.onOpenDynamicComposer = onOpenDynamicComposer
        _totalUnreadCount = totalUnreadCount
    }

    var body: some View {
        NavigationStack(path: $path) {
            // [修改] 搜索栏放在 List 外，滚动消息列表时始终固定在顶部。
            VStack(spacing: 0) {
                fixedSearchBar
                // [修改] 统一用 List 承载空态与好友列表，保证空态也能下拉刷新。
                List {
                    if model.visibleFriends.isEmpty && !model.isRefreshing {
                        ContentUnavailableView(
                            model.searchText.isEmpty ? "暂无好友" : "没有匹配结果",
                            systemImage: "person.2",
                            description: Text(model.searchText.isEmpty ? "下拉刷新好友列表。" : "请尝试其他关键词。")
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        let pinned = model.visibleFriends.filter(\.isPinned)
                        let recent = model.visibleFriends.filter { !$0.isPinned }
                        if !pinned.isEmpty {
                            Section("置顶") { rows(pinned) }
                        }
                        if !recent.isEmpty {
                            Section(pinned.isEmpty ? "好友" : "最近消息") { rows(recent) }
                        }
                    }
                }
                .accessibilityIdentifier("friends.list")
                .overlay {
                    if model.isRefreshing && model.friends.isEmpty { ProgressView() }
                }
                .refreshable {
                    await model.refresh()
                    await refreshPendingRequestCount()
                }
            }
            .navigationTitle("消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                messagesToolbar
            }
            .navigationDestination(for: ChatFriend.self) { routedFriend in
                let current = model.friends.first(where: { $0.friendId == routedFriend.friendId }) ?? routedFriend
                ChatConversationView(
                    friend: current,
                    friends: model.friends,
                    currentUserId: user.id,
                    repository: chatRepository,
                    attachmentUploader: attachmentUploader,
                    attachmentPreviewProvider: attachmentPreviewProvider,
                    dynamicComposerRouteStore: dynamicComposerRouteStore,
                    onOpenDynamicComposer: onOpenDynamicComposer,
                    isUpdatingPin: model.isUpdatingPin(for: current),
                    onTogglePin: { await model.togglePin(current) },
                    onFriendUpdated: { await model.refresh() }
                )
            }
            .task {
                // [修改] 样例模式跳过真实好友缓存和刷新，但仍读取固定的待处理申请数据。
                if !sampleMode {
                    await model.loadCached()
                    await model.refresh()
                }
                await refreshPendingRequestCount()
            }
            .onChange(of: model.totalUnreadCount, initial: true) { _, value in
                // [修改] 好友列表变化后立即同步消息 Tab 总未读角标。
                totalUnreadCount = value
            }
            .onChange(of: messageRouteStore.pendingFriendId, initial: true) { _, _ in
                openPendingNotificationRouteIfReady()
            }
            .onChange(of: model.friends) { _, _ in
                openPendingNotificationRouteIfReady()
            }
            .task {
                // [修改] 消息/已读本地更新，好友关系事件立即刷新申请红点和好友列表。
                for await event in chatRepository.eventStream() {
                    if case .message(let message) = event, message.senderId != user.id {
                        let friendName = model.friends
                            .first(where: { $0.friendId == message.senderId })?.displayName ?? "新消息"
                        await notificationCoordinator.handle(
                            event,
                            currentUserId: user.id,
                            currentFriendId: path.last?.friendId,
                            isMessagesTabActive: notificationVisibility.isMessagesTabActive,
                            isSceneActive: notificationVisibility.isSceneActive,
                            friendName: friendName
                        )
                    }
                    if model.apply(event, currentUserId: user.id) == .refreshFriendship {
                        await model.refresh()
                        await refreshPendingRequestCount()
                    }
                }
            }
            .alert("操作失败", isPresented: errorIsPresented) {
                Button("知道了") { model.clearError() }
            } message: {
                Text(model.errorMessage ?? "请稍后重试")
            }
            .sheet(isPresented: $showsFriendManagement, onDismiss: { Task { await model.refresh() } }) {
                FriendManagementView(repository: chatRepository)
            }
            .sheet(isPresented: $showsFriendRequests, onDismiss: {
                Task { await model.refresh(); await refreshPendingRequestCount() }
            }) {
                FriendRequestsView(repository: chatRepository, onChanged: {
                    await model.refresh()
                    await refreshPendingRequestCount()
                })
            }
            .sheet(isPresented: $showsFavorites) {
                ChatFavoritesSheet(messages: $favoriteMessages) { message in
                    showsFavorites = false
                    guard let friend = model.friends.first(where: {
                        $0.friendId == (message.senderId == user.id ? message.receiverId : message.senderId)
                    }) else { return }
                    path = [friend]
                } onRemove: { message in
                    let friendId = message.senderId == user.id ? message.receiverId : message.senderId
                    try? await chatRepository.setFavorite(message: message, isFavorite: false, friendId: friendId)
                    favoriteMessages.removeAll { $0.id == message.id }
                }
            }
        }
    }

    private func openPendingNotificationRouteIfReady() {
        guard let friendId = messageRouteStore.pendingFriendId,
              let friend = model.friends.first(where: { $0.friendId == friendId }),
              messageRouteStore.consume(friendId: friendId) != nil else { return }
        path = [friend]
    }

    // [修改] 固定搜索栏不随好友列表滚动，并使用系统分组背景语义色适配明暗模式。
    private var fixedSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索好友或消息", text: $model.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("friends.search")
            if !model.searchText.isEmpty {
                // [修改] 清空图标保持原尺寸，按钮扩展到 44×44 以满足触控命中区。
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // [修改] 好友申请和添加好友保持独立入口，并补齐待处理数量与无障碍语义。
    @ToolbarContentBuilder
    private var messagesToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showsFriendRequests = true
            } label: {
                Image(systemName: "tray.full")
            }
            .accessibilityIdentifier("friends.requests")
            .accessibilityLabel("好友申请")
            .accessibilityValue(pendingRequestCount > 0 ? "\(pendingRequestCount)个待处理" : "无待处理")
            .overlay(alignment: .topTrailing) {
                if pendingRequestCount > 0 {
                    Text(pendingRequestBadgeText)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, pendingRequestCount > 9 ? 5 : 4)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color(uiColor: .systemRed), in: Capsule())
                        .offset(x: 8, y: -8)
                        // [修改] 申请数量由父按钮的 accessibilityValue 播报，隐藏角标文本避免重复。
                        .accessibilityIdentifier("friends.requests.badge")
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task {
                    favoriteMessages = await chatRepository.favoriteMessages()
                    showsFavorites = true
                }
            } label: {
                Image(systemName: "bookmark")
            }
            .accessibilityIdentifier("messages.favorites")
            .accessibilityLabel("稍后处理")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showsFriendManagement = true
            } label: {
                Image(systemName: "person.badge.plus")
            }
            .accessibilityIdentifier("friends.add")
            .accessibilityLabel("查找并添加好友")
        }
    }

    // [修改] 申请角标最多显示 99+，避免三位数撑宽顶部工具栏。
    private var pendingRequestBadgeText: String {
        pendingRequestCount > 99 ? "99+" : "\(pendingRequestCount)"
    }

    private func refreshPendingRequestCount() async {
        pendingRequestCount = (try? await chatRepository.pendingRequests())?.count ?? 0
    }

    @ViewBuilder
    private func rows(_ friends: [ChatFriend]) -> some View {
        ForEach(friends) { friend in
            NavigationLink(value: friend) {
                FriendConversationRow(friend: friend)
            }
            .accessibilityIdentifier("conversation.\(friend.friendId)")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    Task { await model.togglePin(friend) }
                } label: {
                    Label(friend.isPinned ? "取消置顶" : "置顶", systemImage: friend.isPinned ? "pin.slash" : "pin")
                }
                .tint(AppTheme.primaryGreen)
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )
    }
}

private struct ChatFavoritesSheet: View {
    @Binding var messages: [ChatMessage]
    let onOpen: (ChatMessage) -> Void
    let onRemove: (ChatMessage) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(messages) { message in
                Button {
                    onOpen(message)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.conversationSummary)
                                .font(.headline)
                                .lineLimit(2)
                            if let forwardFrom = message.forwardFrom?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !forwardFrom.isEmpty {
                                Text("转发自 \(forwardFrom)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            Task { await onRemove(message) }
                        } label: {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(AppTheme.documentBlue)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移出稍后处理")
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if messages.isEmpty {
                    ContentUnavailableView("还没有稍后处理的消息", systemImage: "bookmark")
                }
            }
            .navigationTitle("稍后处理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct FriendConversationRow: View {
    let friend: ChatFriend

    var body: some View {
        HStack(spacing: 13) {
            FriendAvatarView(friend: friend, size: 46)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(friend.displayName).font(.headline)
                    if friend.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                }
                Text(friend.latestMessage ?? (friend.isOnline ? "在线" : "开始聊天"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if friend.unreadCount > 0 {
                Text(friend.unreadCount > 99 ? "99+" : "\(friend.unreadCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, friend.unreadCount > 99 ? 7 : 6)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(AppTheme.primaryGreen, in: Capsule())
                    .accessibilityIdentifier("conversation.\(friend.friendId).unread")
            }
        }
        .padding(.vertical, 4)
    }
}
