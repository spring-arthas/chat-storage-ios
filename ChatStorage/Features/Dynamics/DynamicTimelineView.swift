import AVFoundation
import QuickLook
import SwiftUI
import UIKit

// [修改] 动态主页面同时保留“关注”和“我的”两套分页状态，切换时间线时不会丢失已加载内容。
@MainActor
struct DynamicTimelineView: View {
    @State private var selectedScope: DynamicTimelineScope = .following
    @State private var followingModel: DynamicTimelineViewModel
    @State private var mineModel: DynamicTimelineViewModel
    @State private var showsComposer = false
    @State private var selectedPost: DynamicPost?
    @State private var deletionCandidate: DynamicPost?
    @State private var mediaGallery: DynamicMediaGalleryState?
    @State private var previewingMediaID: Int64?
    @State private var mediaErrorMessage: String?

    private let repository: any DynamicRepository
    private let composerRouteStore: DynamicComposerRouteStore
    private let attachmentUploader: (any ChatAttachmentUploading)?
    private let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    private let currentUser: AuthenticatedUser

    init(
        repository: any DynamicRepository,
        composerRouteStore: DynamicComposerRouteStore,
        attachmentUploader: (any ChatAttachmentUploading)?,
        attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?,
        currentUser: AuthenticatedUser
    ) {
        self.repository = repository
        self.composerRouteStore = composerRouteStore
        self.attachmentUploader = attachmentUploader
        self.attachmentPreviewProvider = attachmentPreviewProvider
        self.currentUser = currentUser
        _followingModel = State(initialValue: DynamicTimelineViewModel(repository: repository, scope: .following))
        _mineModel = State(initialValue: DynamicTimelineViewModel(repository: repository, scope: .mine))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dynamicHeader
                if let message = mediaErrorMessage ?? activeModel.errorMessage {
                    DynamicErrorBanner(message: message) {
                        mediaErrorMessage = nil
                        activeModel.clearError()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                timelineContent
            }
            .background(Color(.systemBackground))
            .navigationDestination(isPresented: detailIsPresented) {
                if let selectedPost {
                    DynamicDetailView(
                        repository: repository,
                        post: selectedPost,
                        attachmentPreviewProvider: attachmentPreviewProvider,
                        onDeleted: refreshBothTimelines
                    )
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: selectedScope) {
            await activeModel.loadInitial()
            await presentPersistedComposerIfNeeded()
        }
        // [修改] 聊天或网盘切到动态 Tab 时自动消费一次性草稿并打开同一个发布器。
        .onChange(of: composerRouteStore.pendingDraft != nil, initial: true) { _, hasDraft in
            if hasDraft { showsComposer = true }
        }
        .fullScreenCover(isPresented: $showsComposer) {
            DynamicComposerView(
                repository: repository,
                attachmentUploader: attachmentUploader,
                attachmentPreviewProvider: attachmentPreviewProvider,
                routeStore: composerRouteStore,
                currentUser: currentUser,
                onPublished: refreshBothTimelines
            )
        }
        .sheet(item: $mediaGallery) { gallery in
            DynamicMediaGalleryView(state: gallery, previewProvider: attachmentPreviewProvider)
        }
        .confirmationDialog(
            "删除这条动态？",
            isPresented: deletionIsPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteCandidate() }
            Button("取消", role: .cancel) { deletionCandidate = nil }
        } message: {
            Text("删除后好友将无法再看到这条动态。")
        }
    }

    private var activeModel: DynamicTimelineViewModel {
        selectedScope == .following ? followingModel : mineModel
    }

    // [修改] 重新进入动态页时自动恢复未完成发布，避免草稿只存在磁盘而用户找不到。
    private func presentPersistedComposerIfNeeded() async {
        guard !showsComposer, let draft = await composerRouteStore.draftStore.load() else { return }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.mediaItems.isEmpty
                || draft.reference != nil else { return }
        showsComposer = true
    }

    private var detailIsPresented: Binding<Bool> {
        Binding(
            get: { selectedPost != nil },
            set: { if !$0 { selectedPost = nil } }
        )
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        )
    }

    // [修改] 动态主页使用自定义顶部栏承载通知和发布入口，隐藏系统导航标题避免双标题。
    private var dynamicHeader: some View {
        HStack {
            Menu {
                Button {
                    Task { await activeModel.refresh() }
                } label: {
                    Label("刷新动态", systemImage: "arrow.clockwise")
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                    Circle()
                        .fill(AppTheme.primaryGreen)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: -3, y: 4)
                }
            }
            .accessibilityLabel("动态通知与刷新")
            .accessibilityIdentifier("dynamic.notifications")

            Spacer()

            Text("动态")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            Button {
                showsComposer = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(AppTheme.primaryGreen, in: Circle())
            }
            .accessibilityLabel("发布动态")
            .accessibilityIdentifier("dynamic.compose")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var timelineContent: some View {
        DynamicTimelineList(
            model: activeModel,
            currentUser: currentUser,
            selectedScope: selectedScope,
            attachmentPreviewProvider: attachmentPreviewProvider,
            previewingMediaID: previewingMediaID,
            onSelectScope: { scope in
                withAnimation(.snappy(duration: 0.2)) { selectedScope = scope }
            },
            onCompose: { showsComposer = true },
            onOpenDetail: { selectedPost = $0 },
            onOpenMedia: openMedia,
            onDelete: { deletionCandidate = $0 }
        )
        .id(selectedScope)
    }

    private func openMedia(_ media: DynamicMedia, in collection: [DynamicMedia]) {
        mediaErrorMessage = nil
        mediaGallery = DynamicMediaGalleryState(media: collection, selectedMediaID: media.fileId)
    }

    private func deleteCandidate() {
        guard let candidate = deletionCandidate else { return }
        deletionCandidate = nil
        Task {
            if selectedScope == .following {
                await followingModel.delete(postID: candidate.id)
                if followingModel.errorMessage == nil { await mineModel.refresh() }
            } else {
                await mineModel.delete(postID: candidate.id)
                if mineModel.errorMessage == nil { await followingModel.refresh() }
            }
        }
    }

    private func refreshBothTimelines() {
        Task {
            await followingModel.refresh()
            await mineModel.refresh()
        }
    }
}

// [修改] 加载、空态、分页和下拉刷新都留在时间线区域内，不用全屏阻塞用户。
@MainActor
private struct DynamicTimelineList: View {
    let model: DynamicTimelineViewModel
    let currentUser: AuthenticatedUser
    let selectedScope: DynamicTimelineScope
    let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    let previewingMediaID: Int64?
    let onSelectScope: (DynamicTimelineScope) -> Void
    let onCompose: () -> Void
    let onOpenDetail: (DynamicPost) -> Void
    let onOpenMedia: (DynamicMedia, [DynamicMedia]) -> Void
    let onDelete: (DynamicPost) -> Void

    var body: some View {
        ScrollView {
            // [修改] 主页头部新增头像栏和分享卡后，首条动态可能暂时位于首屏下方；使用 VStack 让动态卡的无障碍入口立即可用。
            VStack(spacing: 0) {
                DynamicStoryRail(
                    items: DynamicTimelineStoryBuilder.make(currentUser: currentUser, posts: model.posts),
                    onSelectMine: { onSelectScope(.mine) },
                    onOpenPost: { postID in
                        if let post = model.posts.first(where: { $0.id == postID }) {
                            onOpenDetail(post)
                        }
                    }
                )

                DynamicHomeScopeSelector(selectedScope: selectedScope, onSelect: onSelectScope)

                DynamicDailyShareCard(action: onCompose)

                if model.isLoading, model.posts.isEmpty {
                    ProgressView("正在加载动态")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if model.posts.isEmpty {
                    ContentUnavailableView(
                        model.errorMessage == nil ? "还没有动态" : "动态暂时加载失败",
                        systemImage: model.errorMessage == nil ? "bubble.left.and.text.bubble.right" : "wifi.exclamationmark",
                        description: Text(model.scope == .mine ? "发布第一条动态，记录现在。" : "好友发布的新内容会出现在这里。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ForEach(model.posts) { post in
                        DynamicPostCard(
                            post: post,
                            attachmentPreviewProvider: attachmentPreviewProvider,
                            previewingMediaID: previewingMediaID,
                            onOpenDetail: { onOpenDetail(post) },
                            onReply: { onOpenDetail(post) },
                            onRepost: { Task { await model.toggleRepost(postID: post.id) } },
                            onLike: { Task { await model.toggleLike(postID: post.id) } },
                            onOpenMedia: onOpenMedia,
                            onDelete: post.isMine ? { onDelete(post) } : nil
                        )
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                        .padding(.horizontal, 16)
                        // [修改] 卡片之间保留明确的呼吸间距，避免媒体高度变化后相邻动态视觉重合。
                        .padding(.vertical, 10)
                    }
                }

                if model.hasMore, !model.posts.isEmpty {
                    ProgressView()
                        .padding(20)
                        .task(id: model.nextBeforeId) { await model.loadNextPage() }
                }
                // [修改] 为底部 TabView 留出可滚动安全区，最后一条动态不会被系统标签栏遮住。
            }
            .padding(.bottom, 88)
        }
        .refreshable { await model.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("dynamic.timeline.\(model.scope.rawValue.lowercased())")
    }
}

struct DynamicTimelineStory: Equatable, Identifiable, Sendable {
    let author: DynamicAuthor
    let latestPostID: Int64?
    let isCurrentUser: Bool

    var id: Int64 { author.id }
}

enum DynamicTimelineStoryBuilder {
    static func make(currentUser: AuthenticatedUser, posts: [DynamicPost]) -> [DynamicTimelineStory] {
        let currentAuthor = DynamicAuthor(
            id: currentUser.id,
            username: currentUser.username,
            nickname: currentUser.nickname ?? currentUser.username,
            avatar: currentUser.avatar
        )
        var identifiers: Set<Int64> = [currentUser.id]
        var items = [DynamicTimelineStory(author: currentAuthor, latestPostID: nil, isCurrentUser: true)]

        for post in posts where identifiers.insert(post.author.id).inserted {
            items.append(DynamicTimelineStory(author: post.author, latestPostID: post.id, isCurrentUser: false))
        }
        return items
    }
}

// [修改] 头像栏只展示当前时间线中出现过的作者，点击作者头像打开该作者最近一条动态。
@MainActor
private struct DynamicStoryRail: View {
    let items: [DynamicTimelineStory]
    let onSelectMine: () -> Void
    let onOpenPost: (Int64) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    Button {
                        if item.isCurrentUser {
                            onSelectMine()
                        } else if let latestPostID = item.latestPostID {
                            onOpenPost(latestPostID)
                        }
                    } label: {
                        VStack(spacing: 7) {
                            ZStack {
                                DynamicAvatarView(author: item.author, size: 62)
                                    .padding(4)
                                    .background(
                                        item.isCurrentUser ? AppTheme.primaryGreen : Color(.separator),
                                        in: Circle()
                                    )
                                    .padding(2)
                                    .background(Color(.systemBackground), in: Circle())
                            }
                            Text(item.isCurrentUser ? "我的动态" : (DynamicText.nonBlank(item.author.nickname) ?? "用户"))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(width: 72)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isCurrentUser && item.latestPostID == nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("dynamic.story-rail")
    }
}

// [修改] 主页分段改成参考图的胶囊样式，但仍保留当前代码已有的“关注/我的”业务含义。
@MainActor
private struct DynamicHomeScopeSelector: View {
    let selectedScope: DynamicTimelineScope
    let onSelect: (DynamicTimelineScope) -> Void

    var body: some View {
        HStack(spacing: 4) {
            button(title: "关注", scope: .following, identifier: "dynamic.scope.following")
            button(title: "我的", scope: .mine, identifier: "dynamic.scope.mine")
        }
        .padding(4)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func button(title: String, scope: DynamicTimelineScope, identifier: String) -> some View {
        Button { onSelect(scope) } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selectedScope == scope ? .white : AppTheme.primaryGreen)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(selectedScope == scope ? AppTheme.primaryGreen : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selectedScope == scope ? .isSelected : [])
    }
}

// [修改] 今日分享卡与顶部加号共用发布入口，让用户在主页上能直接发现新增动态功能。
@MainActor
private struct DynamicDailyShareCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryGreen)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.primaryGreen.opacity(0.12), in: Circle())

                Text("今日分享")
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryGreen)
                Text("记录生活中的小确幸")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .background(AppTheme.primaryGreen.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.primaryGreen.opacity(0.14), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityLabel("今日分享，发布动态")
        .accessibilityIdentifier("dynamic.share-prompt")
    }
}

// [修改] 卡片按头像、作者、正文、媒体网格、引用和互动栏排列，保持 Twitter 式高信息密度。
@MainActor
struct DynamicPostCard: View {
    let post: DynamicPost
    let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    let previewingMediaID: Int64?
    let onOpenDetail: (() -> Void)?
    let onReply: () -> Void
    let onRepost: () -> Void
    let onLike: () -> Void
    let onOpenMedia: (DynamicMedia, [DynamicMedia]) -> Void
    let onDelete: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DynamicAvatarView(author: post.author, size: 44)

            VStack(alignment: .leading, spacing: 9) {
                header
                content

                if !post.media.isEmpty {
                    DynamicMediaGrid(
                        media: post.media,
                        previewProvider: attachmentPreviewProvider,
                        loadingMediaID: previewingMediaID,
                        onOpen: { media in onOpenMedia(media, post.media) }
                    )
                }

                if let reference = post.reference {
                    DynamicReferenceCard(
                        reference: reference,
                        onOpenMedia: { media in onOpenMedia(media, reference.media) }
                    )
                }

                if let original = post.originalPost?.value {
                    DynamicEmbeddedPostCard(
                        post: original,
                        previewProvider: attachmentPreviewProvider,
                        loadingMediaID: previewingMediaID,
                        onOpenMedia: { media in onOpenMedia(media, original.media) }
                    )
                }

                DynamicInteractionBar(
                    post: post,
                    onReply: onReply,
                    onRepost: onRepost,
                    onLike: onLike
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color(.systemBackground))
        // [修改] 将动态卡片声明为独立无障碍容器，避免卡片标识传播并覆盖点赞、评论等子按钮标识。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dynamic.post.\(post.id)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Group {
                if let onOpenDetail {
                    Button(action: onOpenDetail) { authorText }
                        .buttonStyle(.plain)
                } else {
                    authorText
                }
            }
            Spacer(minLength: 6)
            if let onDelete {
                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label("删除动态", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("更多操作")
                .accessibilityIdentifier("dynamic.more.\(post.id)")
            }
        }
    }

    private var authorText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(DynamicText.nonBlank(post.author.nickname) ?? DynamicText.nonBlank(post.author.username) ?? "用户")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("@\(DynamicText.nonBlank(post.author.username) ?? "user")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(DynamicDateText.relative(post.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(post.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .lineLimit(isExpanded ? nil : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenDetail?() }

                if post.content.count > 150 || post.content.filter({ $0 == "\n" }).count > 4 {
                    Button(isExpanded ? "收起" : "展开") {
                        withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryGreen)
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

@MainActor
private struct DynamicEmbeddedPostCard: View {
    let post: DynamicPost
    let previewProvider: (any ChatAttachmentPreviewProviding)?
    let loadingMediaID: Int64?
    let onOpenMedia: (DynamicMedia) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                DynamicAvatarView(author: post.author, size: 24)
                Text(DynamicText.nonBlank(post.author.nickname) ?? DynamicText.nonBlank(post.author.username) ?? "用户")
                    .font(.caption.weight(.semibold))
                Text("@\(DynamicText.nonBlank(post.author.username) ?? "user")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !post.content.isEmpty {
                Text(post.content)
                    .font(.subheadline)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !post.media.isEmpty {
                DynamicMediaGrid(
                    media: post.media,
                    previewProvider: previewProvider,
                    loadingMediaID: loadingMediaID,
                    onOpen: onOpenMedia
                )
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.55), lineWidth: 0.7)
        }
    }
}

@MainActor
private struct DynamicInteractionBar: View {
    let post: DynamicPost
    let onReply: () -> Void
    let onRepost: () -> Void
    let onLike: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            interactionButton(
                title: "回复",
                count: post.replyCount,
                symbol: "bubble.left",
                color: AppTheme.documentBlue,
                identifier: "dynamic.reply.\(post.id)",
                action: onReply
            )
            interactionButton(
                title: post.reposted ? "取消转发" : "转发",
                count: post.repostCount,
                symbol: "arrow.2.squarepath",
                color: post.reposted ? AppTheme.primaryGreen : .secondary,
                identifier: "dynamic.repost.\(post.id)",
                action: onRepost
            )
            interactionButton(
                title: post.liked ? "取消点赞" : "点赞",
                count: post.likeCount,
                symbol: post.liked ? "heart.fill" : "heart",
                color: post.liked ? AppTheme.mediaCoral : .secondary,
                identifier: "dynamic.like.\(post.id)",
                action: onLike
            )
            ShareLink(item: DynamicShareText.make(for: post)) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                    Text("分享").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("dynamic.share.\(post.id)")
        }
        .font(.subheadline)
        .padding(.top, 1)
    }

    private func interactionButton(
        title: String,
        count: Int,
        symbol: String,
        color: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if count > 0 { Text("\(count)").font(.caption.monospacedDigit()) }
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(title)，\(count)" : title)
        .accessibilityIdentifier(identifier)
    }
}

// [修改] 动态列表统一把图片原图和视频首帧转换为缩略图，避免视频只显示类型占位图。
enum DynamicMediaThumbnailRenderer {
    static func thumbnailData(for preview: ChatAttachmentPreview) async throws -> Data? {
        switch preview.kind {
        case .image:
            return try Data(contentsOf: preview.url)
        case .video:
            return try await videoThumbnailData(from: preview.url)
        case .file:
            return nil
        }
    }

    private static func videoThumbnailData(from url: URL) async throws -> Data? {
        let pinnedMediaAsset = PinnedMediaAsset(url: url)
        let asset = pinnedMediaAsset?.asset ?? AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        let generatorBox = DynamicThumbnailImageGeneratorBox(generator)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        let data = try await withTaskCancellationHandler {
            for second in [0.0, 1.0, 2.0] {
                try Task.checkCancellation()
                do {
                    let result = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
                    try Task.checkCancellation()
                    return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.82)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            return nil
        } onCancel: {
            generatorBox.value.cancelAllCGImageGeneration()
        }
        withExtendedLifetime(pinnedMediaAsset) {}
        return data
    }
}

private final class DynamicThumbnailImageGeneratorBox: @unchecked Sendable {
    let value: AVAssetImageGenerator

    init(_ value: AVAssetImageGenerator) {
        self.value = value
    }
}

// [修改] 动态媒体最多9项：所有多媒体布局都根据实际卡片宽度计算，避免固定高度在不同 iPhone 上失真。
enum DynamicMediaGridLayout {
    static let maxMediaCount = 9
    static let defaultSpacing: CGFloat = 4
    static let singleMediaAspectRatio: CGFloat = 1.5
    static let singleMediaMaximumHeight: CGFloat = 360

    static func visibleMedia(from media: [DynamicMedia]) -> [DynamicMedia] {
        Array(media.prefix(maxMediaCount))
    }

    // [修改] 5～9项统一三列等宽，行数按实际媒体数计算，避免固定高度截断最后一行。
    static func rows(for count: Int) -> Int {
        let normalizedCount = min(max(count, 0), maxMediaCount)
        return normalizedCount == 0 ? 0 : (normalizedCount + 2) / 3
    }

    // [修改] 明确返回每一行的媒体数量，避免最后一行由 LazyVGrid 自行推断导致布局错位。
    static func rowItemCounts(for count: Int) -> [Int] {
        let normalizedCount = min(max(count, 0), maxMediaCount)
        guard normalizedCount > 0 else { return [] }
        return (0..<rows(for: normalizedCount)).map { row in
            min(3, normalizedCount - row * 3)
        }
    }

    // [修改] 网格高度使用容器实际宽度，兼容不同 iPhone 屏幕和横竖屏尺寸。
    static func height(for count: Int, width: CGFloat, spacing: CGFloat) -> CGFloat {
        let normalizedCount = min(max(count, 0), maxMediaCount)
        guard normalizedCount > 0, width > 0 else { return 0 }

        switch normalizedCount {
        case 1:
            return min(width / singleMediaAspectRatio, singleMediaMaximumHeight)
        case 2, 3:
            return max(0, (width - spacing) / 2)
        case 4:
            return width
        default:
            let cellWidth = max(0, (width - spacing * 2) / 3)
            let rowCount = CGFloat(rows(for: normalizedCount))
            return cellWidth * rowCount + spacing * max(0, rowCount - 1)
        }
    }
}

// [修改] 媒体数量按 1、2、3、4、5～9 项切换布局，所有格子由同一 Layout 给出确定边界。
@MainActor
struct DynamicMediaGrid: View {
    let media: [DynamicMedia]
    let previewProvider: (any ChatAttachmentPreviewProviding)?
    let loadingMediaID: Int64?
    let onOpen: (DynamicMedia) -> Void

    private var items: [DynamicMedia] { DynamicMediaGridLayout.visibleMedia(from: media) }

    var body: some View {
        DynamicMediaMosaicLayout(spacing: DynamicMediaGridLayout.defaultSpacing) {
            ForEach(items) { item in
                cell(item)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.separator).opacity(0.45), lineWidth: 0.6)
        }
        .accessibilityIdentifier("dynamic.media.grid")
    }

    private func cell(_ item: DynamicMedia) -> some View {
        DynamicMediaCell(
            media: item,
            previewProvider: previewProvider,
            isOpening: loadingMediaID == item.fileId,
            onOpen: { onOpen(item) }
        )
    }
}

// [修改] 统一计算1～9项媒体的边界：2项等宽方格，3项左大右上下两格，4项2×2，5～9项三列网格。
private struct DynamicMediaMosaicLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        return CGSize(width: width, height: DynamicMediaGridLayout.height(for: subviews.count, width: width, spacing: spacing))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let width = max(0, bounds.width)
        let count = min(subviews.count, DynamicMediaGridLayout.maxMediaCount)
        guard count > 0, width > 0 else { return }

        switch count {
        case 1:
            place(subviews[0], in: CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height))
        case 2:
            let cellWidth = max(0, (width - spacing) / 2)
            place(subviews[0], in: CGRect(x: bounds.minX, y: bounds.minY, width: cellWidth, height: cellWidth))
            place(subviews[1], in: CGRect(x: bounds.minX + cellWidth + spacing, y: bounds.minY, width: cellWidth, height: cellWidth))
        case 3:
            placeThreeItemMosaic(subviews, width: width, bounds: bounds)
        case 4:
            placeFourItemGrid(subviews, width: width, bounds: bounds)
        default:
            placeThreeColumnGrid(subviews, count: count, width: width, bounds: bounds)
        }
    }

    private func placeThreeItemMosaic(_ subviews: Subviews, width: CGFloat, bounds: CGRect) {
        let cellWidth = max(0, (width - spacing) / 2)
        place(subviews[0], in: CGRect(x: bounds.minX, y: bounds.minY, width: cellWidth, height: cellWidth))
        let rightX = bounds.minX + cellWidth + spacing
        let rightHeight = max(0, (cellWidth - spacing) / 2)
        place(subviews[1], in: CGRect(x: rightX, y: bounds.minY, width: cellWidth, height: rightHeight))
        place(subviews[2], in: CGRect(x: rightX, y: bounds.minY + rightHeight + spacing, width: cellWidth, height: rightHeight))
    }

    private func placeFourItemGrid(_ subviews: Subviews, width: CGFloat, bounds: CGRect) {
        let cellWidth = max(0, (width - spacing) / 2)
        for index in 0..<min(4, subviews.count) {
            let row = index / 2
            let column = index % 2
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (cellWidth + spacing),
                y: bounds.minY + CGFloat(row) * (cellWidth + spacing)
            )
            place(subviews[index], in: CGRect(x: origin.x, y: origin.y, width: cellWidth, height: cellWidth))
        }
    }

    private func placeThreeColumnGrid(_ subviews: Subviews, count: Int, width: CGFloat, bounds: CGRect) {
        let cellWidth = max(0, (width - spacing * 2) / 3)
        for index in 0..<count {
            let row = index / 3
            let column = index % 3
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (cellWidth + spacing),
                y: bounds.minY + CGFloat(row) * (cellWidth + spacing)
            )
            place(subviews[index], in: CGRect(x: origin.x, y: origin.y, width: cellWidth, height: cellWidth))
        }
    }

    private func place(_ subview: LayoutSubviews.Element, in frame: CGRect) {
        subview.place(
            at: frame.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: frame.width, height: frame.height)
        )
    }
}

@MainActor
private struct DynamicMediaCell: View {
    let media: DynamicMedia
    let previewProvider: (any ChatAttachmentPreviewProviding)?
    let isOpening: Bool
    let onOpen: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Color(.secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [placeholderColor.opacity(0.22), placeholderColor.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 7) {
                        Image(systemName: media.kind.symbol)
                            .font(.system(size: 27, weight: .semibold))
                        Text(DynamicText.nonBlank(media.fileName) ?? media.kind.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                    }
                    .foregroundStyle(placeholderColor)
                }

                if media.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.58), in: Circle())
                }

                if isOpening {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开\(media.kind.title)：\(media.fileName)")
        .accessibilityIdentifier("dynamic.media.\(media.fileId)")
        // [修改] 图片和视频统一走附件预览链路，视频异步生成第一帧后再替换占位图。
        .task(id: media.fileId) {
            guard media.kind != .file, let previewProvider else { return }
            guard let preview = try? await previewProvider.preview(for: media.chatAttachment),
                  let data = try? await DynamicMediaThumbnailRenderer.thumbnailData(for: preview),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            self.image = image
        }
    }

    private var placeholderColor: Color {
        switch media.kind {
        case .image: AppTheme.documentBlue
        case .video: AppTheme.mediaCoral
        case .file: AppTheme.archiveViolet
        }
    }
}

@MainActor
struct DynamicReferenceCard: View {
    let reference: DynamicReference
    let onOpenMedia: ((DynamicMedia) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(reference.sourceType.title, systemImage: reference.sourceType.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryGreen)
            Text(reference.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if !reference.subtitle.isEmpty {
                Text(reference.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !reference.media.isEmpty {
                HStack(spacing: 8) {
                    ForEach(reference.media.prefix(4)) { media in
                        Button {
                            onOpenMedia?(media)
                        } label: {
                            Image(systemName: media.kind.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(media.kind == .video ? AppTheme.mediaCoral : AppTheme.documentBlue)
                                .frame(width: 30, height: 30)
                                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(onOpenMedia == nil)
                        .accessibilityLabel(media.fileName)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.7)
        }
        .accessibilityIdentifier("dynamic.reference.\(reference.sourceType.rawValue).\(reference.sourceId)")
    }
}

@MainActor
struct DynamicAvatarView: View {
    let author: DynamicAuthor
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.image(from: author.avatar) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let value = author.avatar,
                      let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(DynamicText.nonBlank(author.nickname) ?? DynamicText.nonBlank(author.username) ?? "用户")的头像")
    }

    // [修改] 兼容服务端返回的纯 Base64、data URL 和头像 HTTP/HTTPS 地址。
    static func image(from rawValue: String?) -> UIImage? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        let payload: String
        if let separator = rawValue.range(of: "base64,", options: .caseInsensitive) {
            payload = String(rawValue[separator.upperBound...])
        } else {
            payload = rawValue
        }
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else { return nil }
        return UIImage(data: data)
    }

    private var initials: some View {
        ZStack {
            Circle().fill(AppTheme.primaryGreen.gradient)
            Text(String((DynamicText.nonBlank(author.nickname) ?? DynamicText.nonBlank(author.username) ?? "动").prefix(1)))
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

@MainActor
struct DynamicErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
    }
}

// [修改] 动态媒体浏览状态保留同一动态的完整媒体顺序，并从点击项开始分页浏览。
struct DynamicMediaGalleryState: Identifiable, Equatable {
    let media: [DynamicMedia]
    let selectedIndex: Int

    var id: String {
        "\(selectedIndex)-" + media.map { String($0.fileId) }.joined(separator: ",")
    }

    init(media: [DynamicMedia], selectedMediaID: Int64) {
        let visibleMedia = DynamicMediaGridLayout.visibleMedia(from: media)
        self.media = visibleMedia
        self.selectedIndex = max(0, visibleMedia.firstIndex(where: { $0.fileId == selectedMediaID }) ?? 0)
    }
}

// [修改] 图片和视频在同一个分页预览器内连续查看，图片完整适配，视频复用在线播放控制器。
@MainActor
struct DynamicMediaGalleryView: View {
    let state: DynamicMediaGalleryState
    let previewProvider: (any ChatAttachmentPreviewProviding)?

    @State private var selectedIndex: Int
    @State private var previews: [Int64: ChatAttachmentPreview] = [:]
    @State private var errors: [Int64: String] = [:]

    init(state: DynamicMediaGalleryState, previewProvider: (any ChatAttachmentPreviewProviding)?) {
        self.state = state
        self.previewProvider = previewProvider
        _selectedIndex = State(initialValue: state.selectedIndex)
    }

    var body: some View {
        NavigationStack {
            Group {
                if state.media.isEmpty {
                    ContentUnavailableView("没有可预览的媒体", systemImage: "photo.on.rectangle.angled")
                } else if let previewProvider {
                    TabView(selection: $selectedIndex) {
                        ForEach(Array(state.media.enumerated()), id: \.element.fileId) { index, media in
                            page(for: media, previewProvider: previewProvider)
                                .tag(index)
                                .task(id: "\(media.fileId)-\(selectedIndex)") {
                                    guard abs(index - selectedIndex) <= 1 else { return }
                                    await load(media: media, previewProvider: previewProvider)
                                }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                } else {
                    ContentUnavailableView("当前账号没有可用的媒体预览凭据", systemImage: "lock.slash")
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("\(min(selectedIndex + 1, state.media.count))/\(state.media.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    @ViewBuilder
    private func page(
        for media: DynamicMedia,
        previewProvider: any ChatAttachmentPreviewProviding
    ) -> some View {
        if let preview = previews[media.fileId] {
            switch preview.kind {
            case .image:
                DynamicImagePreviewView(preview: preview)
            case .video:
                DynamicVideoPreviewView(preview: preview)
            case .file:
                DynamicQuickLookPreview(url: preview.url)
            }
        } else if let message = errors[media.fileId] {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.white)
                Button("重新加载") {
                    Task { await load(media: media, previewProvider: previewProvider, force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ProgressView("加载媒体")
                .tint(.white)
                .foregroundStyle(.white)
        }
    }

    private func load(
        media: DynamicMedia,
        previewProvider: any ChatAttachmentPreviewProviding,
        force: Bool = false
    ) async {
        guard force || (previews[media.fileId] == nil && errors[media.fileId] == nil) else { return }
        do {
            let preview = try await previewProvider.preview(for: media.chatAttachment)
            guard !Task.isCancelled else { return }
            previews[media.fileId] = preview
            errors[media.fileId] = nil
        } catch {
            guard !Task.isCancelled else { return }
            errors[media.fileId] = (error as? LocalizedError)?.errorDescription ?? "媒体打开失败"
        }
    }
}

// [修改] 图片预览取消固定 padding 和横向滚动，始终按容器比例完整显示整张图片。
@MainActor
private struct DynamicImagePreviewView: View {
    let preview: ChatAttachmentPreview
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("加载图片")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .background(Color.black)
        .task(id: preview.id) {
            guard let data = try? await DynamicMediaThumbnailRenderer.thumbnailData(for: preview),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            self.image = image
        }
    }
}

// [修改] 保留单媒体预览兼容入口；新列表和详情统一使用 DynamicMediaGalleryView。
@MainActor
struct DynamicMediaPreviewSheet: View {
    let preview: ChatAttachmentPreview

    var body: some View {
        NavigationStack {
            Group {
                switch preview.kind {
                case .video:
                    DynamicVideoPreviewView(preview: preview)
                case .image:
                    DynamicImagePreviewView(preview: preview)
                case .file:
                    DynamicQuickLookPreview(url: preview.url)
                }
            }
            .navigationTitle(preview.attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if preview.kind != .video {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: preview.url)
                    }
                }
            }
        }
    }
}

@MainActor
private struct DynamicVideoPreviewView: View {
    let preview: ChatAttachmentPreview
    @State private var controller: DriveVideoPlaybackController
    @State private var showsFullscreen = false

    init(preview: ChatAttachmentPreview) {
        self.preview = preview
        if let playback = preview.playback, let refreshPlayback = preview.refreshPlayback {
            _controller = State(initialValue: DriveVideoPlaybackController(
                playback: playback,
                refreshPlayback: refreshPlayback
            ))
        } else {
            _controller = State(initialValue: DriveVideoPlaybackController(url: preview.url))
        }
    }

    var body: some View {
        Group {
            if let player = controller.player {
                videoContent(player: player, fullscreen: false)
            } else {
                ProgressView("加载视频")
            }
        }
        .background(Color.black)
        .task { await controller.start(autoplay: true) }
        .onDisappear { controller.invalidate() }
        .fullScreenCover(isPresented: $showsFullscreen) {
            if let player = controller.player {
                videoContent(player: player, fullscreen: true)
                    .background(Color.black.ignoresSafeArea())
                    .statusBarHidden(true)
                    .overlay(alignment: .topLeading) {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityLabel("动态视频全屏播放")
                            .accessibilityIdentifier("dynamic.video.fullscreen-view")
                    }
            }
        }
    }

    private func videoContent(player: AVPlayer, fullscreen: Bool) -> some View {
        VStack(spacing: 0) {
            if fullscreen {
                DriveFullscreenVideoSurface(
                    player: player,
                    presentationSize: controller.presentationSizeState.size
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // [修改] 动态视频弹窗复用网盘播放框，按 AVPlayer presentationSize 展示真实比例。
                DrivePreviewVideoSurface(
                    player: player,
                    presentationSize: controller.presentationSizeState.size
                )
            }
            controls(fullscreen: fullscreen)
        }
        .background(Color.black)
        .overlay { statusOverlay }
    }

    private func controls(fullscreen: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(Self.time(controller.playbackState.currentTime))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { controller.playbackState.currentTime },
                        set: { controller.updateScrubbing(to: $0) }
                    ),
                    in: 0...controller.playbackState.sliderUpperBound,
                    onEditingChanged: { editing in
                        if editing {
                            controller.beginScrubbing()
                        } else {
                            Task { await controller.endScrubbing() }
                        }
                    }
                )
                .disabled(controller.playbackState.duration <= 0)
                .tint(AppTheme.primaryGreen)
                .accessibilityIdentifier("dynamic.video.progress")
                Text(Self.time(controller.playbackState.duration))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42, alignment: .leading)
            }

            HStack(spacing: 18) {
                Button { Task { await controller.togglePlayback() } } label: {
                    Image(systemName: controller.playbackState.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 32)
                }
                .accessibilityLabel(controller.playbackState.isPlaying ? "暂停" : "播放")
                .accessibilityIdentifier("dynamic.video.play-pause")

                Button { Task { await controller.stop() } } label: {
                    Image(systemName: "stop.fill").frame(width: 36, height: 32)
                }
                .accessibilityLabel("停止")
                .accessibilityIdentifier("dynamic.video.stop")

                Spacer()

                Button { showsFullscreen = !fullscreen } label: {
                    Image(systemName: fullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 36, height: 32)
                }
                .accessibilityLabel(fullscreen ? "退出全屏" : "全屏播放")
                .accessibilityIdentifier(fullscreen ? "dynamic.video.exit-fullscreen" : "dynamic.video.fullscreen")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.94))
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch controller.phase {
        case .loading:
            ProgressView("加载视频").tint(.white).foregroundStyle(.white)
        case .waiting:
            ProgressView("正在缓冲").tint(.white).foregroundStyle(.white)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("重新加载") { Task { await controller.retry() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("dynamic.video.retry")
            }
            .padding(18)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        case .ended:
            Label("播放结束", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.58), in: Capsule())
        case .idle, .ready:
            EmptyView()
        }
    }

    private static func time(_ value: TimeInterval) -> String {
        let seconds = max(Int(value.rounded(.down)), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}

private struct DynamicQuickLookPreview: UIViewControllerRepresentable {
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
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

enum DynamicPostCopying {
    static func updating(
        _ post: DynamicPost,
        likeCount: Int? = nil,
        replyCount: Int? = nil,
        repostCount: Int? = nil,
        liked: Bool? = nil,
        reposted: Bool? = nil
    ) -> DynamicPost {
        DynamicPost(
            id: post.id,
            author: post.author,
            content: post.content,
            media: post.media,
            reference: post.reference,
            likeCount: likeCount ?? post.likeCount,
            replyCount: replyCount ?? post.replyCount,
            repostCount: repostCount ?? post.repostCount,
            liked: liked ?? post.liked,
            reposted: reposted ?? post.reposted,
            originalPost: post.originalPost?.value,
            createdAt: post.createdAt,
            isMine: post.isMine
        )
    }
}

private enum DynamicShareText {
    static func make(for post: DynamicPost) -> String {
        let author = DynamicText.nonBlank(post.author.nickname) ?? DynamicText.nonBlank(post.author.username) ?? "好友"
        let content = post.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? "\(author)分享了一条动态" : "\(author)：\(content)"
    }
}

private enum DynamicDateText {
    static func relative(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "刚刚" }
        let secondsValue = timestamp > 10_000_000_000 ? Double(timestamp) / 1_000 : Double(timestamp)
        let date = Date(timeIntervalSince1970: secondsValue)
        let elapsed = max(0, Date().timeIntervalSince(date))
        switch elapsed {
        case ..<60: return "刚刚"
        case ..<3_600: return "\(Int(elapsed / 60))分钟前"
        case ..<86_400: return "\(Int(elapsed / 3_600))小时前"
        case ..<(7 * 86_400): return "\(Int(elapsed / 86_400))天前"
        default: return date.formatted(.dateTime.month().day())
        }
    }
}

enum DynamicText {
    static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

extension DynamicMedia {
    var chatAttachment: ChatAttachment {
        ChatAttachment(
            kind: kind.rawValue,
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType
        )
    }
}

private extension DynamicMediaKind {
    var symbol: String {
        switch self {
        case .image: "photo.fill"
        case .video: "video.fill"
        case .file: "doc.fill"
        }
    }

    var title: String {
        switch self {
        case .image: "图片"
        case .video: "视频"
        case .file: "文件"
        }
    }
}

private extension DynamicReferenceSourceType {
    var title: String {
        switch self {
        case .chatMessage: "来自聊天"
        case .driveFile: "来自网盘"
        }
    }

    var symbol: String {
        switch self {
        case .chatMessage: "bubble.left.and.text.bubble.right"
        case .driveFile: "externaldrive.fill"
        }
    }
}
