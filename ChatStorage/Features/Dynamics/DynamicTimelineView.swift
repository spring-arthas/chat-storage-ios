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
    @State private var mediaPreview: ChatAttachmentPreview?
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
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    scopeSelector
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

                composeButton
                    .padding(.trailing, 18)
                    .padding(.bottom, 20)
            }
            .background(Color(.systemBackground))
            .navigationTitle("动态")
            .navigationBarTitleDisplayMode(.inline)
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
        }
        .task(id: selectedScope) {
            await activeModel.loadInitial()
        }
        // [修改] 聊天或网盘切到动态 Tab 时自动消费一次性草稿并打开同一个发布器。
        .onChange(of: composerRouteStore.pendingDraft != nil, initial: true) { _, hasDraft in
            if hasDraft { showsComposer = true }
        }
        .fullScreenCover(isPresented: $showsComposer) {
            DynamicComposerView(
                repository: repository,
                attachmentUploader: attachmentUploader,
                routeStore: composerRouteStore,
                currentUser: currentUser,
                onPublished: refreshBothTimelines
            )
        }
        .sheet(item: $mediaPreview) { preview in
            DynamicMediaPreviewSheet(preview: preview)
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

    private var scopeSelector: some View {
        HStack(spacing: 0) {
            scopeButton(title: "关注", scope: .following, identifier: "dynamic.scope.following")
            scopeButton(title: "我的", scope: .mine, identifier: "dynamic.scope.mine")
        }
        .padding(.horizontal, 16)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func scopeButton(
        title: String,
        scope: DynamicTimelineScope,
        identifier: String
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { selectedScope = scope }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(selectedScope == scope ? .semibold : .regular))
                    .foregroundStyle(selectedScope == scope ? .primary : .secondary)
                Capsule()
                    .fill(selectedScope == scope ? AppTheme.primaryGreen : .clear)
                    .frame(width: 36, height: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selectedScope == scope ? .isSelected : [])
    }

    @ViewBuilder
    private var timelineContent: some View {
        DynamicTimelineList(
            model: activeModel,
            attachmentPreviewProvider: attachmentPreviewProvider,
            previewingMediaID: previewingMediaID,
            onOpenDetail: { selectedPost = $0 },
            onOpenMedia: openMedia,
            onDelete: { deletionCandidate = $0 }
        )
        .id(selectedScope)
    }

    private var composeButton: some View {
        Button {
            showsComposer = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(AppTheme.primaryGreen.gradient, in: Circle())
                .shadow(color: AppTheme.deepGreen.opacity(0.28), radius: 12, y: 6)
        }
        .accessibilityLabel("发布动态")
        .accessibilityIdentifier("dynamic.compose")
    }

    private func openMedia(_ media: DynamicMedia) {
        guard previewingMediaID == nil else { return }
        guard let attachmentPreviewProvider else {
            mediaErrorMessage = "当前账号没有可用的媒体预览凭据"
            return
        }
        previewingMediaID = media.fileId
        mediaErrorMessage = nil
        Task {
            defer { previewingMediaID = nil }
            do {
                mediaPreview = try await attachmentPreviewProvider.preview(for: media.chatAttachment)
            } catch {
                mediaErrorMessage = (error as? LocalizedError)?.errorDescription ?? "媒体打开失败"
            }
        }
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
    let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    let previewingMediaID: Int64?
    let onOpenDetail: (DynamicPost) -> Void
    let onOpenMedia: (DynamicMedia) -> Void
    let onDelete: (DynamicPost) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
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
                        Divider().padding(.leading, 72)
                    }
                }

                if model.hasMore, !model.posts.isEmpty {
                    ProgressView()
                        .padding(20)
                        .task(id: model.nextBeforeId) { await model.loadNextPage() }
                }
            }
        }
        .refreshable { await model.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("dynamic.timeline.\(model.scope.rawValue.lowercased())")
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
    let onOpenMedia: (DynamicMedia) -> Void
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
                        onOpen: onOpenMedia
                    )
                }

                if let reference = post.reference {
                    DynamicReferenceCard(reference: reference, onOpenMedia: onOpenMedia)
                }

                if let original = post.originalPost?.value {
                    DynamicEmbeddedPostCard(
                        post: original,
                        previewProvider: attachmentPreviewProvider,
                        loadingMediaID: previewingMediaID,
                        onOpenMedia: onOpenMedia
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

// [修改] 媒体数量按 1、2、3、4 项切换布局，视频和文件保留明确类型标识。
@MainActor
struct DynamicMediaGrid: View {
    let media: [DynamicMedia]
    let previewProvider: (any ChatAttachmentPreviewProviding)?
    let loadingMediaID: Int64?
    let onOpen: (DynamicMedia) -> Void

    private var items: [DynamicMedia] { Array(media.prefix(4)) }
    private var height: CGFloat {
        switch items.count {
        case 1: 220
        case 2: 164
        case 3, 4: 220
        default: 0
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let halfWidth = max(0, (proxy.size.width - spacing) / 2)
            Group {
                switch items.count {
                case 1:
                    cell(items[0])
                case 2:
                    HStack(spacing: spacing) {
                        cell(items[0]).frame(width: halfWidth)
                        cell(items[1]).frame(width: halfWidth)
                    }
                case 3:
                    HStack(spacing: spacing) {
                        cell(items[0]).frame(width: halfWidth)
                        VStack(spacing: spacing) {
                            cell(items[1])
                            cell(items[2])
                        }
                        .frame(width: halfWidth)
                    }
                case 4:
                    VStack(spacing: spacing) {
                        HStack(spacing: spacing) {
                            cell(items[0])
                            cell(items[1])
                        }
                        HStack(spacing: spacing) {
                            cell(items[2])
                            cell(items[3])
                        }
                    }
                default:
                    EmptyView()
                }
            }
        }
        .frame(height: height)
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
        // [修改] 图片缩略图走已有附件预览缓存；视频不会为首屏额外申请播放地址。
        .task(id: media.fileId) {
            guard media.kind == .image, let previewProvider else { return }
            guard let preview = try? await previewProvider.preview(for: media.chatAttachment),
                  preview.kind == .image else { return }
            image = UIImage(contentsOfFile: preview.url.path)
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
            if let avatarData = author.avatar.flatMap({ Data(base64Encoded: $0) }),
               let image = UIImage(data: avatarData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let value = author.avatar,
                      let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" {
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

// [修改] 动态媒体打开后仍复用聊天附件预览结果和网盘视频状态机，不直接拼接远端地址。
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
                    if let image = UIImage(contentsOfFile: preview.url.path) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding()
                        }
                    } else {
                        ContentUnavailableView("图片无法打开", systemImage: "photo.badge.exclamationmark")
                    }
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
            SecureVideoSurface(player: player)
                .frame(maxWidth: .infinity, maxHeight: fullscreen ? .infinity : nil)
                .aspectRatio(fullscreen ? nil : 16 / 9, contentMode: .fit)
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
