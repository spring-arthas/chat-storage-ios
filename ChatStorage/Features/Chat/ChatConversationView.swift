import PhotosUI
import AVKit
import CoreTransferable
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ChatConversationView: View {
    let friend: ChatFriend
    let friends: [ChatFriend]
    let isUpdatingPin: Bool
    let onTogglePin: () async -> Void
    let onFriendUpdated: () async -> Void
    let dynamicComposerRouteStore: DynamicComposerRouteStore
    let onOpenDynamicComposer: () -> Void

    @State private var selectedBackgroundPhoto: PhotosPickerItem?
    @State private var selectedChatPhotos: [PhotosPickerItem] = []
    @State private var selectedChatVideos: [PhotosPickerItem] = []
    @State private var backgroundData: Data?
    @State private var showsEmojiPicker = false
    @State private var selectedEmojiCategoryIndex = 0
    @State private var recentEmojis = ChatEmojiStore().recent
    // [修改] 附件来源面板与系统选择器必须串行展示，避免 Menu/Sheet 关闭时吞掉文件选择请求。
    @State private var attachmentPickerPresentation = ChatAttachmentPickerPresentationState()
    @State private var attachmentPreview: ChatAttachmentPreview?
    @State private var previewingAttachmentId: Int64?
    @State private var attachmentErrorMessage: String?
    @State private var showsClearHistoryConfirmation = false
    @State private var forwardingMessage: ChatMessage?
    @State private var reactingMessage: ChatMessage?
    @State private var showsMessageSearch = false
    // [修改] 相册、视频和文件入口共用一个 FIFO 准备队列，后选的小文件不能反超先选的大文件。
    @State private var attachmentPreparationQueue = ChatAttachmentPreparationQueue<ChatAttachmentPreparationBatch>()
    @State private var model: ChatConversationViewModel
    // [修改] 记录用户是否停留在会话底部附近，收到消息时不打断历史阅读。
    @State private var isNearConversationBottom = true
    // [修改] 统一管理输入框焦点，协调系统键盘和表情面板切换。
    @FocusState private var isComposerFocused: Bool
    private let repository: any ChatRepository
    private let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    private let backgroundStore = ChatBackgroundStore.shared
    // [修改] 使用稳定锚点滚动到底部，避免依赖某一条消息是否存在。
    private static let bottomAnchorID = "chat.conversation.bottom"

    init(friend: ChatFriend, friends: [ChatFriend] = [], currentUserId: Int64, repository: any ChatRepository, attachmentUploader: (any ChatAttachmentUploading)? = nil, attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)? = nil, dynamicComposerRouteStore: DynamicComposerRouteStore = DynamicComposerRouteStore(), onOpenDynamicComposer: @escaping () -> Void = {}, isUpdatingPin: Bool, onTogglePin: @escaping () async -> Void, onFriendUpdated: @escaping () async -> Void) {
        self.friend = friend
        self.friends = friends
        self.isUpdatingPin = isUpdatingPin
        self.onTogglePin = onTogglePin
        self.onFriendUpdated = onFriendUpdated
        self.repository = repository
        self.attachmentPreviewProvider = attachmentPreviewProvider
        self.dynamicComposerRouteStore = dynamicComposerRouteStore
        self.onOpenDynamicComposer = onOpenDynamicComposer
        _model = State(initialValue: ChatConversationViewModel(friendId: friend.friendId, currentUserId: currentUserId, repository: repository, attachmentUploader: attachmentUploader))
    }

    var body: some View {
        // [修改] 让消息、输入焦点和键盘事件都能滚动到同一个底部锚点。
        ScrollViewReader { proxy in
            ZStack {
                ChatBackgroundView(imageData: backgroundData)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        Text("今天")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        if model.isLoading && model.messages.isEmpty { ProgressView().tint(.white) }
                        // [修改] 历史消息入口放在消息列表顶部，避免出现在最新消息下方。
                        if model.hasOlderMessages && !model.messages.isEmpty {
                            Button("加载更早消息") { Task { await model.loadOlder() } }
                                .font(.caption).foregroundStyle(.white)
                        }
                        ForEach(model.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                        // [修改] 始终保留底部滚动目标，空会话也能安全定位。
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                // [修改] 用系统滚动几何判断距底部是否不超过 80 点，不读取键盘高度。
                .onScrollGeometryChange(
                    for: Bool.self,
                    of: { geometry in
                        geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) <= 80
                    },
                    action: { _, isNearBottom in
                        isNearConversationBottom = isNearBottom
                    }
                )
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await model.load() }
            }
            .accessibilityIdentifier("chat.conversation.screen")
            .navigationBarTitleDisplayMode(.inline)
            // [修改] 聊天页隐藏根标签栏，返回消息页后交给系统恢复。
            .toolbar(.hidden, for: .tabBar)
            // [修改] 退出聊天页时刷新好友列表，让未读数字在返回后及时归零。
            .onDisappear { Task { await onFriendUpdated() } }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    NavigationLink {
                        FriendDetailView(friend: friend, repository: repository, onAliasUpdated: onFriendUpdated)
                    } label: {
                        HStack(spacing: 9) {
                            FriendAvatarView(friend: friend, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(friend.displayName).font(.headline)
                                Text(friend.isOnline ? "在线" : "离线").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.friend.avatar")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await onTogglePin() } } label: {
                            Label(friend.isPinned ? "取消置顶" : "置顶聊天", systemImage: friend.isPinned ? "pin.slash" : "pin")
                        }.disabled(isUpdatingPin)
                        Button {
                            showsMessageSearch = true
                        } label: {
                            Label("查找聊天内容", systemImage: "magnifyingglass")
                        }
                        PhotosPicker(selection: $selectedBackgroundPhoto, matching: .images) {
                            Label("更换聊天背景", systemImage: "photo")
                        }
                        if backgroundData != nil {
                            Button(role: .destructive) {
                                Task { try? await backgroundStore.remove(friendId: friend.friendId); backgroundData = nil }
                            } label: { Label("恢复默认背景", systemImage: "arrow.uturn.backward") }
                        }
                        Button(role: .destructive) {
                            showsClearHistoryConfirmation = true
                        } label: {
                            Label("清空本地聊天记录", systemImage: "trash")
                        }
                    } label: {
                        // [修改] 使用实心设置图标和独立圆形底板，避免原竖向省略号在导航栏里看不清。
                        Image(systemName: AppSystemSymbols.chatSettings)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.documentBlue)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: Circle())
                    }
                    .accessibilityIdentifier("chat.more")
                    .accessibilityLabel("聊天设置")
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            // [修改] 自己发送始终滚底；收到消息只在用户原本接近底部时跟随。
            .onChange(of: model.messages.last?.id) { _, _ in
                guard let latest = model.messages.last else { return }
                guard latest.isMine || isNearConversationBottom else { return }
                scrollToBottom(using: proxy, animated: true)
            }
            // [修改] 输入框聚焦时关闭表情面板，并按键盘后的可视区域滚到底部。
            .onChange(of: isComposerFocused) { _, isFocused in
                guard isFocused else { return }
                showsEmojiPicker = false
                scrollToBottom(using: proxy, animated: true)
            }
            // [修改] 表情面板展开会压缩聊天区域，展开后重新定位到底部。
            .onChange(of: showsEmojiPicker) { _, isPresented in
                guard isPresented else { return }
                scrollToBottom(using: proxy, animated: true)
            }
            // [修改] 键盘完成 Safe Area 调整后再滚一次，不手算键盘高度。
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                scrollToBottom(using: proxy, animated: true)
            }
            .task {
                backgroundData = try? await backgroundStore.load(friendId: friend.friendId)
                await model.load()
            }
            .task { await model.observeIncoming() }
            .task(id: selectedBackgroundPhoto) {
                guard let selectedBackgroundPhoto,
                      let data = try? await selectedBackgroundPhoto.loadTransferable(type: Data.self) else { return }
                try? await backgroundStore.save(data, friendId: friend.friendId)
                backgroundData = data
            }
            .onChange(of: selectedChatPhotos) { _, items in
                guard !items.isEmpty else { return }
                // [修改] 立即释放选择绑定，旧任务完成时不会误清掉用户刚选的新一批。
                selectedChatPhotos = []
                enqueueAttachmentPreparation(.photos(items))
            }
            .onChange(of: selectedChatVideos) { _, items in
                guard !items.isEmpty else { return }
                selectedChatVideos = []
                enqueueAttachmentPreparation(.videos(items))
            }
            .sheet(
                isPresented: attachmentSourcePickerBinding,
                onDismiss: { attachmentPickerPresentation.sourcePickerDidDismiss() }
            ) {
                ChatAttachmentSourcePicker { destination in
                    attachmentPickerPresentation.select(destination)
                }
            }
            .photosPicker(
                isPresented: attachmentDestinationBinding(.photos),
                selection: $selectedChatPhotos,
                maxSelectionCount: ChatAttachmentSelectionRules.maximumPhotoCount,
                matching: .images
            )
            .photosPicker(
                isPresented: attachmentDestinationBinding(.videos),
                selection: $selectedChatVideos,
                matching: .videos
            )
            .fileImporter(isPresented: attachmentDestinationBinding(.files), allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    enqueueAttachmentPreparation(.files(urls))
                case .failure(let error):
                    if !(error is CancellationError) {
                        attachmentErrorMessage = "文件选择失败，请重试"
                    }
                }
            }
            .sheet(item: $attachmentPreview) { ChatAttachmentPreviewView(preview: $0) }
            .sheet(item: $forwardingMessage) { message in
                ChatForwardMessageSheet(
                    message: message,
                    friends: friends,
                    onForward: { target in
                        forwardingMessage = nil
                        Task { await model.forward(messageID: message.id, to: target.friendId, sourceName: friend.displayName) }
                    }
                )
            }
            .sheet(item: $reactingMessage) { message in
                ChatReactionSheet(message: message) { emoji in
                    reactingMessage = nil
                    Task { await model.sendReaction(messageID: message.id, emoji: emoji) }
                }
            }
            .sheet(isPresented: $showsMessageSearch) {
                ChatMessageSearchView(
                    friend: friend,
                    repository: repository,
                    dynamicComposerRouteStore: dynamicComposerRouteStore,
                    onOpenDynamicComposer: onOpenDynamicComposer
                )
            }
            .alert("聊天操作失败", isPresented: errorIsPresented) {
                Button("知道了") { clearErrors() }
            } message: { Text(attachmentErrorMessage ?? model.errorMessage ?? "请稍后重试") }
            .confirmationDialog(
                "清空本地聊天记录？",
                isPresented: $showsClearHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    Task { await model.clearLocalConversation() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只清除这台 iPhone 上的记录，之后重新同步服务器历史时仍会再次显示。")
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.isMine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                if message.retracted {
                    Text(message.isMine ? "你撤回了一条消息" : "\(friend.displayName)撤回了一条消息")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    if let quote = message.quote {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quote.senderName)
                                .font(.caption2.bold())
                            Text(quote.content)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                    if let mixed = message.mixedContent {
                        ForEach(mixed.attachments) { attachment in
                            Button {
                                Task { await open(attachment) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: attachment.isImage ? "photo.fill" : attachment.isVideo ? "video.fill" : "doc.fill")
                                        .foregroundStyle(AppTheme.documentBlue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(attachment.fileName).lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: attachment.fileSize, countStyle: .file))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if previewingAttachmentId == attachment.fileId {
                                        ProgressView().controlSize(.small)
                                    } else if !attachment.canOpenRemotePreview {
                                        Image(systemName: "clock")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: attachment.isVideo ? "play.circle.fill" : "arrow.down.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(previewingAttachmentId != nil || !attachment.canOpenRemotePreview)
                            .accessibilityIdentifier("chat.attachment.\(attachment.fileId)")
                        }
                        if !mixed.text.isEmpty { Text(mixed.text) }
                    } else {
                        Text(message.content)
                    }
                    if let forwardFrom = message.forwardFrom?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !forwardFrom.isEmpty {
                        Label("转发自 \(forwardFrom)", systemImage: "arrowshape.turn.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !message.reactions.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(message.reactions.keys.sorted(), id: \.self) { emoji in
                                let count = message.reactions[emoji]?.count ?? 0
                        Text("\(emoji) \(count)")
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.8), in: Capsule())
                                    .accessibilityIdentifier("chat.message.\(message.id).reaction.\(emoji)")
                            }
                        }
                    }
                    if message.isMine, let statusText = message.statusText {
                        HStack(spacing: 6) {
                            Text(statusText).font(.caption2).foregroundStyle(.secondary)
                            if message.sendStatus == .failed {
                                Button("重试") { Task { await model.retry(messageID: message.id) } }
                                    .font(.caption2.bold())
                                    .foregroundStyle(AppTheme.documentBlue)
                                    .disabled(model.isSending)
                                    .accessibilityIdentifier("chat.retry.\(message.id)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(message.isMine ? AppTheme.lightGreen.opacity(0.95) : .white.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.black)
            if !message.isMine { Spacer(minLength: 48) }
        }
        // [修改] 消息气泡保留自身标识的同时公开附件和表情子元素，真机可直接点击视频附件。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.message.\(message.id)")
        .contextMenu {
            if !message.retracted {
                Button {
                    UIPasteboard.general.string = message.conversationSummary
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button {
                    model.selectQuote(message, senderName: message.isMine ? "我" : friend.displayName)
                    isComposerFocused = true
                } label: {
                    Label("引用", systemImage: "quote.bubble")
                }
                Button {
                    forwardingMessage = message
                } label: {
                    Label("转发", systemImage: "arrowshape.turn.up.right")
                }
                Button {
                    shareToDynamics(message)
                } label: {
                    Label("分享到动态", systemImage: "quote.bubble")
                }
                Button {
                    Task { await model.toggleFavorite(messageID: message.id) }
                } label: {
                    // [修改] 保留原本地收藏语义，只把用户侧命名升级为“稍后处理”。
                    Label(message.isFavorite ? "移出稍后处理" : "稍后处理", systemImage: message.isFavorite ? "bookmark.fill" : "bookmark")
                }
                Button {
                    reactingMessage = message
                } label: {
                    Label("表情回应", systemImage: "face.smiling")
                }
                if message.isMine && message.sendStatus == .failed {
                    Button {
                        Task { await model.retry(messageID: message.id) }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                Task { await model.deleteLocal(messageID: message.id) }
            } label: {
                Label("本地删除", systemImage: "trash")
            }
            if message.isMine && message.messageId > 0 && !message.retracted {
                Button(role: .destructive) {
                    Task { await model.retract(messageID: message.id) }
                } label: {
                    Label("撤回", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            // [修改] 用分隔线明确输入区边界，背景统一改为系统 regularMaterial。
            Divider()
            if showsEmojiPicker {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if !recentEmojis.isEmpty {
                                emojiCategoryButton(
                                    title: "最近",
                                    systemImage: "clock",
                                    index: -1
                                )
                            }
                            ForEach(Array(ChatEmojiCatalog.categories.enumerated()), id: \.offset) { index, category in
                                emojiCategoryButton(
                                    title: category.title,
                                    systemImage: category.systemImage,
                                    index: index
                                )
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    Divider()
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 4)],
                            spacing: 4
                        ) {
                            ForEach(visibleEmojis, id: \.self) { emoji in
                                Button(emoji) { selectEmoji(emoji) }
                                    .font(.system(size: 26))
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .contentShape(Rectangle())
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("chat.emoji.\(emoji)")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .frame(height: 176)
                }
                .accessibilityIdentifier("chat.emoji.panel")
                Divider()
            }
            if let quote = model.quotedMessage {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(AppTheme.documentBlue)
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("引用 · \(quote.senderName)")
                            .font(.caption.bold())
                            .foregroundStyle(AppTheme.documentBlue)
                        Text(quote.content)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        model.cancelQuote()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消引用")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            HStack(spacing: 10) {
                // [修改] 照片、视频和文件使用三个独立入口；相册侧天然不能混选图片和视频。
                Button {
                    attachmentPickerPresentation.showSourcePicker()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("chat.attachment.add")
                    .accessibilityLabel("添加照片、视频或文件")
                // [修改] 使用系统单行聊天输入框，让键盘 Return 稳定触发发送，不再被多行换行吞掉。
                TextField("消息", text: $model.draft)
                    .focused($isComposerFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        // [修改] 键盘 Return 与发送按钮走同一发送方法。
                        guard !isDraftEmpty, !model.isSending else { return }
                        Task { await model.send() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("chat.composer.input")
                Button("表情", systemImage: showsEmojiPicker ? "keyboard" : "face.smiling") {
                    // [修改] 系统键盘和表情面板互斥，切回键盘时恢复输入焦点。
                    if showsEmojiPicker {
                        showsEmojiPicker = false
                        isComposerFocused = true
                    } else {
                        isComposerFocused = false
                        showsEmojiPicker = true
                    }
                }
                .labelStyle(.iconOnly)
                // [修改] 表情按钮提供至少 44×44 点点击区域。
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                Button("发送", systemImage: "arrow.up") {
                    Task { await model.send() }
                }
                .labelStyle(.iconOnly)
                // [修改] 发送按钮提供 44×44 点点击区域，空草稿时保持禁用，不展示语音入口。
                .frame(width: 44, height: 44)
                .background(isDraftEmpty ? Color.secondary.opacity(0.35) : AppTheme.primaryGreen, in: Circle())
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .disabled(model.isSending || isDraftEmpty)
                .accessibilityIdentifier("chat.composer.send")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .background(.regularMaterial)
    }

    // [修改] 纯空白草稿不触发文本发送；输入区不再展示任何语音入口或麦克风图标。
    private var isDraftEmpty: Bool {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleEmojis: [String] {
        if selectedEmojiCategoryIndex == -1, !recentEmojis.isEmpty {
            return recentEmojis
        }
        let safeIndex = min(max(selectedEmojiCategoryIndex, 0), ChatEmojiCatalog.categories.count - 1)
        return ChatEmojiCatalog.categories[safeIndex].emojis
    }

    private func selectEmoji(_ emoji: String) {
        model.insertEmoji(emoji)
        let store = ChatEmojiStore()
        store.storeRecent(emoji)
        recentEmojis = store.recent
    }

    private func emojiCategoryButton(title: String, systemImage: String, index: Int) -> some View {
        Button {
            selectedEmojiCategoryIndex = index
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(selectedEmojiCategoryIndex == index ? AppTheme.documentBlue : .secondary)
            .frame(minWidth: 48, minHeight: 42)
            .background(
                selectedEmojiCategoryIndex == index
                    ? AppTheme.documentBlue.opacity(0.12)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.emoji.category.\(title)")
    }

    private var attachmentSourcePickerBinding: Binding<Bool> {
        Binding(
            get: { attachmentPickerPresentation.isSourcePickerPresented },
            set: { attachmentPickerPresentation.setSourcePickerPresented($0) }
        )
    }

    private func attachmentDestinationBinding(_ destination: ChatAttachmentPickerDestination) -> Binding<Bool> {
        Binding(
            get: { attachmentPickerPresentation.presentedDestination == destination },
            set: { attachmentPickerPresentation.setDestinationPresented($0, destination: destination) }
        )
    }

    // [修改] 下一主线程周期滚动，等待消息、键盘或表情面板先完成布局。
    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil || attachmentErrorMessage != nil },
            set: { if !$0 { clearErrors() } }
        )
    }

    private func enqueueAttachmentPreparation(_ batch: ChatAttachmentPreparationBatch) {
        guard attachmentPreparationQueue.enqueue(batch) else { return }
        Task { await drainAttachmentPreparationQueue() }
    }

    private func drainAttachmentPreparationQueue() async {
        while let batch = attachmentPreparationQueue.dequeue() {
            switch batch {
            case .photos(let items):
                await sendPickedPhotos(items)
            case .videos(let items):
                await sendPickedVideos(items)
            case .files(let urls):
                await sendImportedAttachments(urls)
            }
        }
    }

    private func sendPickedPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        var failedCount = 0
        for (index, item) in items.prefix(ChatAttachmentSelectionRules.maximumPhotoCount).enumerated() {
            var transferredURL: URL?
            do {
                guard let picked = try await item.loadTransferable(type: ChatPickedImageFile.self) else {
                    failedCount += 1
                    continue
                }
                transferredURL = picked.url
                let fileExtension = preferredExtension(for: item, fallback: picked.url.pathExtension.isEmpty ? "jpg" : picked.url.pathExtension)
                urls.append(try await ChatAttachmentStaging.renameTransferredFile(
                    picked.url,
                    preferredFileName: "照片 \(index + 1).\(fileExtension)"
                ))
            } catch {
                if let transferredURL { ChatAttachmentStaging.removeIfManaged(transferredURL) }
                failedCount += 1
            }
        }
        await sendValidatedAttachments(urls, source: .photoLibraryImages)
        if failedCount > 0 {
            attachmentErrorMessage = "\(failedCount) 张照片读取失败，其他照片已继续发送"
        }
    }

    private func sendPickedVideos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        var failedCount = 0
        for (index, item) in items.enumerated() {
            var transferredURL: URL?
            do {
                guard let picked = try await item.loadTransferable(type: ChatPickedVideoFile.self) else {
                    failedCount += 1
                    continue
                }
                transferredURL = picked.url
                let fileExtension = preferredExtension(for: item, fallback: picked.url.pathExtension.isEmpty ? "mov" : picked.url.pathExtension)
                urls.append(try await ChatAttachmentStaging.renameTransferredFile(
                    picked.url,
                    preferredFileName: "视频 \(index + 1).\(fileExtension)"
                ))
            } catch {
                if let transferredURL { ChatAttachmentStaging.removeIfManaged(transferredURL) }
                failedCount += 1
            }
        }
        await sendValidatedAttachments(urls, source: .photoLibraryVideos)
        if failedCount > 0 {
            attachmentErrorMessage = "\(failedCount) 个视频读取失败，其他视频已继续发送"
        }
    }

    private func sendImportedAttachments(_ urls: [URL]) async {
        var staged: [URL] = []
        do {
            let validated = try ChatAttachmentSelectionRules.validate(urls, source: .files)
            for url in validated {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                staged.append(try await ChatAttachmentStaging.copyImportedFile(
                    url,
                    preferredFileName: url.lastPathComponent
                ))
            }
            await model.sendAttachments(staged)
        } catch {
            staged.forEach(ChatAttachmentStaging.removeIfManaged)
            attachmentErrorMessage = (error as? LocalizedError)?.errorDescription ?? "文件读取失败，请重试"
        }
    }

    private func sendValidatedAttachments(
        _ urls: [URL],
        source: ChatAttachmentSelectionSource
    ) async {
        guard !urls.isEmpty else {
            attachmentErrorMessage = "没有读取到可发送的附件"
            return
        }
        do {
            let validated = try ChatAttachmentSelectionRules.validate(urls, source: source)
            await model.sendAttachments(validated)
        } catch {
            urls.forEach(ChatAttachmentStaging.removeIfManaged)
            attachmentErrorMessage = (error as? LocalizedError)?.errorDescription ?? "附件选择不符合要求"
        }
    }

    private func preferredExtension(for item: PhotosPickerItem, fallback: String) -> String {
        item.supportedContentTypes.compactMap(\.preferredFilenameExtension).first ?? fallback
    }

    private func open(_ attachment: ChatAttachment) async {
        guard attachment.canOpenRemotePreview else { return }
        guard let attachmentPreviewProvider else {
            attachmentErrorMessage = "当前账号没有可用的附件下载凭据"
            return
        }
        guard previewingAttachmentId == nil else { return }
        previewingAttachmentId = attachment.fileId
        attachmentErrorMessage = nil
        defer { previewingAttachmentId = nil }
        do {
            attachmentPreview = try await attachmentPreviewProvider.preview(for: attachment)
        } catch {
            attachmentErrorMessage = (error as? LocalizedError)?.errorDescription ?? "附件打开失败"
        }
    }

    private func clearErrors() {
        attachmentErrorMessage = nil
        model.clearError()
    }

    private func shareToDynamics(_ message: ChatMessage) {
        let media = message.mixedContent?.attachments.map { attachment in
            DynamicMedia(
                kind: attachment.isImage ? .image : attachment.isVideo ? .video : .file,
                fileId: attachment.fileId,
                fileName: attachment.fileName,
                fileSize: attachment.fileSize,
                mimeType: attachment.mimeType
            )
        } ?? []
        let reference = DynamicReference(
            sourceType: .chatMessage,
            sourceId: message.id,
            title: message.isMine ? "我发送的消息" : friend.displayName,
            subtitle: message.conversationSummary,
            media: media
        )
        // [修改] 附件保留真实 fileId，只生成引用草稿，不重复上传文件。
        dynamicComposerRouteStore.present(DynamicComposerDraft(reference: reference))
        onOpenDynamicComposer()
    }
}

private enum ChatAttachmentPreparationBatch {
    case photos([PhotosPickerItem])
    case videos([PhotosPickerItem])
    case files([URL])
}

enum ChatAttachmentPickerDestination: CaseIterable, Equatable {
    case photos
    case videos
    case files
}

// [修改] 先完整关闭附件来源 Sheet，再展示 PhotosPicker 或文件选择器，禁止两个系统弹层重叠。
struct ChatAttachmentPickerPresentationState: Equatable {
    private(set) var isSourcePickerPresented = false
    private(set) var presentedDestination: ChatAttachmentPickerDestination?
    private var pendingDestination: ChatAttachmentPickerDestination?

    mutating func showSourcePicker() {
        guard presentedDestination == nil else { return }
        pendingDestination = nil
        isSourcePickerPresented = true
    }

    mutating func setSourcePickerPresented(_ isPresented: Bool) {
        if isPresented {
            showSourcePicker()
        } else {
            isSourcePickerPresented = false
        }
    }

    mutating func select(_ destination: ChatAttachmentPickerDestination) {
        pendingDestination = destination
        isSourcePickerPresented = false
    }

    mutating func sourcePickerDidDismiss() {
        guard presentedDestination == nil, let pendingDestination else { return }
        self.pendingDestination = nil
        presentedDestination = pendingDestination
    }

    mutating func setDestinationPresented(
        _ isPresented: Bool,
        destination: ChatAttachmentPickerDestination
    ) {
        if isPresented {
            guard !isSourcePickerPresented else { return }
            pendingDestination = nil
            presentedDestination = destination
        } else if presentedDestination == destination {
            presentedDestination = nil
        }
    }
}

private struct ChatAttachmentSourcePicker: View {
    let onSelect: (ChatAttachmentPickerDestination) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(.photos)
                } label: {
                    Label("从相册选择照片（最多9张）", systemImage: "photo.on.rectangle.angled")
                }
                .accessibilityIdentifier("chat.attachment.photos")

                Button {
                    onSelect(.videos)
                } label: {
                    Label("从相册选择视频", systemImage: "video.fill")
                }
                .accessibilityIdentifier("chat.attachment.videos")

                Button {
                    onSelect(.files)
                } label: {
                    Label("从文件选择", systemImage: "folder.fill")
                }
                .accessibilityIdentifier("chat.attachment.files")
            }
            .navigationTitle("选择附件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

// [修改] 转发只允许选择一位现有好友，每次确认生成一条独立聊天消息。
private struct ChatForwardMessageSheet: View {
    let message: ChatMessage
    let friends: [ChatFriend]
    let onForward: (ChatFriend) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(friends) { friend in
                Button {
                    onForward(friend)
                } label: {
                    HStack(spacing: 12) {
                        FriendAvatarView(friend: friend, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(friend.displayName).font(.headline)
                            Text(message.conversationSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.forward.friend.\(friend.friendId)")
            }
            .overlay {
                if friends.isEmpty {
                    ContentUnavailableView("没有可转发的好友", systemImage: "person.2.slash")
                }
            }
            .navigationTitle("转发给好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// [修改] 回应面板与 Android 使用同一组表情；重复选择由服务端切换为取消回应。
private struct ChatReactionSheet: View {
    let message: ChatMessage
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let emojis = ["😀", "😂", "❤️", "👍", "🎉", "🙏", "😎", "🤔"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        NavigationStack {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onPick(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(
                                message.reactions[emoji] == nil
                                    ? Color(uiColor: .secondarySystemGroupedBackground)
                                    : AppTheme.lightGreen,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.reaction.\(emoji)")
                }
            }
            .padding(20)
            .navigationTitle("表情回应")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(300)])
    }
}

// [修改] enqueue 在主线程同步登记顺序，耗时准备过程即使 await 也只能按 FIFO 逐批执行。
@MainActor
final class ChatAttachmentPreparationQueue<Element> {
    private var elements: [Element] = []
    private var isDraining = false

    @discardableResult
    func enqueue(_ element: Element) -> Bool {
        elements.append(element)
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    func dequeue() -> Element? {
        guard !elements.isEmpty else {
            isDraining = false
            return nil
        }
        return elements.removeFirst()
    }
}

// [修改] PhotosPicker 使用文件传输表示，避免多个大视频全部读进内存后再写盘。
private struct ChatPickedImageFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(url: try ChatAttachmentStaging.copyTransferredFile(received.file, fallbackExtension: "jpg"))
        }
    }
}

private struct ChatPickedVideoFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            Self(url: try ChatAttachmentStaging.copyTransferredFile(received.file, fallbackExtension: "mov"))
        }
    }
}

enum ChatAttachmentStaging {
    static let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChatStorage/OutgoingAttachments", isDirectory: true)
    // [修改] 文件名探测和实际复制/移动必须处于同一临界区，避免并发同名资源选中同一路径。
    private static let destinationLock = NSLock()

    static func copyTransferredFile(_ sourceURL: URL, fallbackExtension: String) throws -> URL {
        let fileExtension = sourceURL.pathExtension.isEmpty ? fallbackExtension : sourceURL.pathExtension
        return try copy(
            sourceURL,
            preferredFileName: "媒体-\(UUID().uuidString).\(fileExtension)"
        )
    }

    // [修改] PhotosPicker 已复制到应用暂存目录，后台移动改名即可，避免大照片和视频再次整文件复制。
    static func renameTransferredFile(_ sourceURL: URL, preferredFileName: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try withExclusiveDestination {
                let directory = directoryURL
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let safeName = TransferFileName.safeLocalName(preferredFileName, fallback: "attachment")
                let destination = uniqueDestination(for: safeName, in: directory)
                guard sourceURL.standardizedFileURL != destination.standardizedFileURL else { return sourceURL }
                try FileManager.default.moveItem(at: sourceURL, to: destination)
                return destination
            }
        }.value
    }

    // [修改] 安全域文件的大文件复制放到后台任务，避免阻塞 SwiftUI 主线程。
    static func copyImportedFile(_ sourceURL: URL, preferredFileName: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try copy(sourceURL, preferredFileName: preferredFileName)
        }.value
    }

    static func copy(_ sourceURL: URL, preferredFileName: String) throws -> URL {
        try withExclusiveDestination {
            let directory = directoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeName = TransferFileName.safeLocalName(preferredFileName, fallback: "attachment")
            let destination = uniqueDestination(for: safeName, in: directory)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        }
    }

    // [修改] 只删除应用自己管理的附件暂存文件，绝不触碰用户从“文件”App 选择的原文件。
    static func removeIfManaged(_ url: URL) {
        let managedRoot = directoryURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(managedRoot + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func uniqueDestination(for fileName: String, in directory: URL) -> URL {
        let source = fileName as NSString
        let stem = source.deletingPathExtension
        let fileExtension = source.pathExtension
        var candidate = fileName
        var index = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = fileExtension.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(fileExtension)"
            index += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    private static func withExclusiveDestination<T>(_ operation: () throws -> T) rethrows -> T {
        destinationLock.lock()
        defer { destinationLock.unlock() }
        return try operation()
    }
}

private struct ChatAttachmentPreviewView: View {
    let preview: ChatAttachmentPreview

    var body: some View {
        NavigationStack {
            Group {
                switch preview.kind {
                case .video:
                    ChatVideoPlayerView(preview: preview)
                case .image:
                    if let image = UIImage(contentsOfFile: preview.url.path) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    } else {
                        ContentUnavailableView("图片无法打开", systemImage: "photo.badge.exclamationmark")
                    }
                case .file:
                    QuickLookPreview(url: preview.url)
                }
            }
            .navigationTitle(preview.attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if preview.kind != .video {
                    ToolbarItem(placement: .topBarTrailing) { ShareLink(item: preview.url) }
                }
            }
        }
    }
}

// [修改] 聊天视频复用网盘的播放状态机，补齐 URL 续签、停止、单次拖动、失败重试和全屏横竖屏。
private struct ChatVideoPlayerView: View {
    let preview: ChatAttachmentPreview
    @State private var videoController: DriveVideoPlaybackController
    @State private var showsFullscreenVideo = false

    init(preview: ChatAttachmentPreview) {
        self.preview = preview
        if let playback = preview.playback,
           let refreshPlayback = preview.refreshPlayback {
            _videoController = State(initialValue: DriveVideoPlaybackController(
                playback: playback,
                refreshPlayback: refreshPlayback
            ))
        } else {
            _videoController = State(initialValue: DriveVideoPlaybackController(url: preview.url))
        }
    }

    var body: some View {
        Group {
            if let player = videoController.player {
                videoContent(player: player, fullscreen: false)
            } else {
                ProgressView("加载视频")
            }
        }
        .task {
            await videoController.start(autoplay: true)
        }
        .onDisappear {
            showsFullscreenVideo = false
            AppOrientationController.setVideoFullscreen(false)
            videoController.invalidate()
        }
        .onChange(of: showsFullscreenVideo) { _, isFullscreen in
            AppOrientationController.setVideoFullscreen(isFullscreen)
        }
        .fullScreenCover(isPresented: $showsFullscreenVideo) {
            if let player = videoController.player {
                videoContent(player: player, fullscreen: true)
                    .background(Color.black.ignoresSafeArea())
                    .statusBarHidden(true)
                    .overlay(alignment: .topLeading) {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityLabel("聊天视频全屏播放")
                            .accessibilityIdentifier("chat.video.fullscreen-view")
                    }
            }
        }
    }

    @ViewBuilder
    private func videoContent(player: AVPlayer, fullscreen: Bool) -> some View {
        VStack(spacing: 0) {
            if fullscreen {
                DriveFullscreenVideoSurface(
                    player: player,
                    presentationSize: videoController.presentationSizeState.size
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !showsFullscreenVideo {
                SecureVideoSurface(player: player)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
            } else {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
            }
            videoControls(fullscreen: fullscreen)
        }
        .background(Color.black)
        .overlay { videoStatusOverlay }
    }

    private func videoControls(fullscreen: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(Self.formattedTime(videoController.playbackState.currentTime))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { videoController.playbackState.currentTime },
                        set: { videoController.updateScrubbing(to: $0) }
                    ),
                    in: 0...videoController.playbackState.sliderUpperBound,
                    onEditingChanged: { editing in
                        if editing {
                            videoController.beginScrubbing()
                        } else {
                            Task { await videoController.endScrubbing() }
                        }
                    }
                )
                .disabled(videoController.playbackState.duration <= 0)
                .tint(AppTheme.primaryGreen)
                .accessibilityLabel("播放进度")
                .accessibilityIdentifier("chat.video.progress")

                Text(Self.formattedTime(videoController.playbackState.duration))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42, alignment: .leading)
            }

            HStack(spacing: 18) {
                Button { Task { await videoController.togglePlayback() } } label: {
                    Image(systemName: videoController.playbackState.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 32)
                }
                .accessibilityLabel(videoController.playbackState.isPlaying ? "暂停" : "播放")
                .accessibilityIdentifier("chat.video.play-pause")

                Button { Task { await videoController.stop() } } label: {
                    Image(systemName: "stop.fill").frame(width: 36, height: 32)
                }
                .accessibilityLabel("停止")
                .accessibilityIdentifier("chat.video.stop")

                Spacer()

                if videoController.phase == .waiting {
                    ProgressView().tint(.white).accessibilityLabel("视频缓冲中")
                }

                Button { showsFullscreenVideo = !fullscreen } label: {
                    Image(systemName: fullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 36, height: 32)
                }
                .accessibilityLabel(fullscreen ? "退出全屏" : "全屏播放")
                .accessibilityIdentifier(fullscreen ? "chat.video.exit-fullscreen" : "chat.video.fullscreen")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.94))
    }

    @ViewBuilder
    private var videoStatusOverlay: some View {
        switch videoController.phase {
        case .loading:
            ProgressView("加载视频").tint(.white).foregroundStyle(.white)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("重新加载") { Task { await videoController.retry() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat.video.retry")
            }
            .padding(20)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        case .ended:
            Label("播放结束", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.58), in: Capsule())
        case .idle, .ready, .waiting:
            EmptyView()
        }
    }

    private static func formattedTime(_ value: TimeInterval) -> String {
        let seconds = max(Int(value.rounded(.down)), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
