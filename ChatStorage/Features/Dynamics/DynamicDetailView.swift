import SwiftUI
import UIKit
import Observation

// [修改] 详情回复分页状态独立于 SwiftUI 视图，统一处理替换、追加、去重和失败重试。
@MainActor
@Observable
final class DynamicDetailViewModel {
    var post: DynamicPost
    private(set) var replies: [DynamicPost] = []
    private(set) var nextBeforeReplyId: Int64?
    private(set) var hasMore = true
    private(set) var isLoading = false
    private(set) var isLoadingNextPage = false
    private(set) var errorMessage: String?
    private(set) var canRetry = false

    private let repository: any DynamicRepository
    private let pageSize: Int
    private var hasLoadedInitial = false
    private var failedRequest: FailedRequest?

    private enum FailedRequest {
        case initial
        case next(beforeReplyId: Int64)
    }

    init(repository: any DynamicRepository, post: DynamicPost, pageSize: Int = 20) {
        self.repository = repository
        self.post = post
        self.pageSize = pageSize
    }

    func loadInitial() async {
        guard !hasLoadedInitial else { return }
        await load(replacing: true, beforeReplyId: nil)
    }

    func refresh() async {
        await load(replacing: true, beforeReplyId: nil)
    }

    func loadNextPage() async {
        guard hasMore, let cursor = nextBeforeReplyId, !isLoading else { return }
        await load(replacing: false, beforeReplyId: cursor)
    }

    func retry() async {
        guard let failedRequest else { return }
        switch failedRequest {
        case .initial:
            await load(replacing: true, beforeReplyId: nil)
        case .next(let cursor):
            await load(replacing: false, beforeReplyId: cursor)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func load(replacing: Bool, beforeReplyId: Int64?) async {
        guard !isLoading else { return }
        isLoading = true
        isLoadingNextPage = !replacing
        errorMessage = nil
        defer {
            isLoading = false
            isLoadingNextPage = false
        }

        do {
            let detail = try await repository.detail(
                dynamicId: post.id,
                beforeReplyId: beforeReplyId,
                limit: pageSize
            )
            post = detail.post
            replies = replacing ? Self.unique(detail.replies) : Self.merging(replies, detail.replies)
            nextBeforeReplyId = detail.nextBeforeReplyId
            hasMore = detail.hasMore && detail.nextBeforeReplyId != nil
            hasLoadedInitial = true
            failedRequest = nil
            canRetry = false
        } catch {
            // [修改] 请求失败不改旧回复、游标和 hasMore，保证用户仍可重试当前页。
            failedRequest = replacing ? .initial : .next(beforeReplyId: beforeReplyId ?? nextBeforeReplyId ?? 0)
            canRetry = true
            errorMessage = Self.message(for: error)
        }
    }

    private static func unique(_ values: [DynamicPost]) -> [DynamicPost] {
        var identifiers = Set<Int64>()
        return values.filter { identifiers.insert($0.id).inserted }
    }

    private static func merging(_ existing: [DynamicPost], _ additional: [DynamicPost]) -> [DynamicPost] {
        var identifiers = Set(existing.map(\.id))
        return existing + additional.filter { identifiers.insert($0.id).inserted }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "回复加载失败"
    }
}

// [修改] 详情页由仓库重新取权威动态和回复，回复成功后刷新详情，不在 UI 层伪造回复记录。
@MainActor
struct DynamicDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var detailModel: DynamicDetailViewModel
    @State private var replyText = ""
    @State private var isSendingReply = false
    @State private var errorMessage: String?
    @State private var mediaPreview: ChatAttachmentPreview?
    @State private var previewingMediaID: Int64?
    @State private var showsDeleteConfirmation = false

    private let repository: any DynamicRepository
    private let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    private let onDeleted: () -> Void

    init(
        repository: any DynamicRepository,
        post: DynamicPost,
        attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?,
        onDeleted: @escaping () -> Void = {}
    ) {
        self.repository = repository
        _detailModel = State(initialValue: DynamicDetailViewModel(repository: repository, post: post))
        self.attachmentPreviewProvider = attachmentPreviewProvider
        self.onDeleted = onDeleted
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                DynamicPostCard(
                    post: detailModel.post,
                    attachmentPreviewProvider: attachmentPreviewProvider,
                    previewingMediaID: previewingMediaID,
                    onOpenDetail: nil,
                    onReply: focusReply,
                    onRepost: toggleRepost,
                    onLike: toggleLike,
                    onOpenMedia: openMedia,
                    onDelete: detailModel.post.isMine ? { showsDeleteConfirmation = true } : nil
                )

                Divider()

                HStack {
                    Text("回复")
                        .font(.headline)
                    Spacer()
                    Text("\(detailModel.post.replyCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if detailModel.isLoading, detailModel.replies.isEmpty {
                    ProgressView("加载回复")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if detailModel.replies.isEmpty, detailModel.canRetry {
                    ContentUnavailableView {
                        Label("回复加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(detailModel.errorMessage ?? "请稍后重试")
                    } actions: {
                        Button("重试") {
                            Task { await detailModel.retry() }
                        }
                        .accessibilityIdentifier("dynamic.detail.reply-retry")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if detailModel.replies.isEmpty {
                    ContentUnavailableView(
                        "还没有回复",
                        systemImage: "bubble.left",
                        description: Text("说点什么，开启这段对话。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ForEach(detailModel.replies) { reply in
                        DynamicReplyRow(reply: reply)
                        Divider().padding(.leading, 68)
                    }
                }

                if detailModel.hasMore, !detailModel.replies.isEmpty {
                    if detailModel.canRetry {
                        Button("重试加载回复") {
                            Task { await detailModel.retry() }
                        }
                        .padding(.vertical, 16)
                        .accessibilityIdentifier("dynamic.detail.reply-retry")
                    } else {
                        ProgressView("加载更多回复")
                            .padding(.vertical, 16)
                            .task(id: detailModel.nextBeforeReplyId) {
                                await detailModel.loadNextPage()
                            }
                    }
                }
            }
        }
        .refreshable { await loadDetail() }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { replyComposer }
        .navigationTitle("动态详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await loadDetail() }
        .sheet(item: $mediaPreview) { DynamicMediaPreviewSheet(preview: $0) }
        .alert("动态操作失败", isPresented: actionErrorIsPresented) {
            Button("知道了") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请稍后重试")
        }
        .confirmationDialog(
            "删除这条动态？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deletePost() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后好友将无法再看到这条动态。")
        }
        .accessibilityIdentifier("dynamic.detail.\(detailModel.post.id)")
    }

    private var actionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var replyComposer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("回复这条动态", text: Binding(
                    get: { replyText },
                    set: { replyText = String($0.prefix(280)) }
                ), axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("dynamic.detail.reply-input")

                Button {
                    sendReply()
                } label: {
                    if isSendingReply {
                        ProgressView().controlSize(.small)
                            .frame(width: 38, height: 38)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(AppTheme.primaryGreen, in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingReply)
                .accessibilityLabel("发送回复")
                .accessibilityIdentifier("dynamic.detail.reply-send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)
        }
    }

    private func loadDetail() async {
        await detailModel.refresh()
    }

    private func focusReply() {
        // [修改] 输入栏固定在底部，VoiceOver 可通过稳定标识直接聚焦，不额外维护第二套回复 Sheet。
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func sendReply() {
        let content = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isSendingReply else { return }
        isSendingReply = true
        errorMessage = nil
        Task {
            do {
                let result = try await repository.action(dynamicId: detailModel.post.id, action: .reply(content: content))
                detailModel.post = DynamicPostCopying.updating(
                    detailModel.post,
                    likeCount: result.likeCount,
                    replyCount: result.replyCount,
                    repostCount: result.repostCount,
                    liked: result.liked,
                    reposted: result.reposted
                )
                replyText = ""
                await loadDetail()
            } catch {
                errorMessage = message(for: error)
            }
            isSendingReply = false
        }
    }

    private func toggleLike() {
        let original = detailModel.post
        let action: DynamicAction = original.liked ? .unlike : .like
        detailModel.post = DynamicPostCopying.updating(
            original,
            likeCount: max(0, original.likeCount + (original.liked ? -1 : 1)),
            liked: !original.liked
        )
        Task {
            do {
                apply(try await repository.action(dynamicId: original.id, action: action))
            } catch {
                detailModel.post = original
                errorMessage = message(for: error)
            }
        }
    }

    private func toggleRepost() {
        let original = detailModel.post
        let action: DynamicAction = original.reposted ? .unrepost : .repost
        detailModel.post = DynamicPostCopying.updating(
            original,
            repostCount: max(0, original.repostCount + (original.reposted ? -1 : 1)),
            reposted: !original.reposted
        )
        Task {
            do {
                apply(try await repository.action(dynamicId: original.id, action: action))
            } catch {
                detailModel.post = original
                errorMessage = message(for: error)
            }
        }
    }

    private func apply(_ result: DynamicActionResult) {
        detailModel.post = DynamicPostCopying.updating(
            detailModel.post,
            likeCount: result.likeCount,
            replyCount: result.replyCount,
            repostCount: result.repostCount,
            liked: result.liked,
            reposted: result.reposted
        )
    }

    private func deletePost() {
        Task {
            do {
                try await repository.delete(dynamicId: detailModel.post.id)
                onDeleted()
                dismiss()
            } catch {
                errorMessage = message(for: error)
            }
        }
    }

    private func openMedia(_ media: DynamicMedia) {
        guard previewingMediaID == nil else { return }
        guard let attachmentPreviewProvider else {
            errorMessage = "当前账号没有可用的媒体预览凭据"
            return
        }
        previewingMediaID = media.fileId
        Task {
            defer { previewingMediaID = nil }
            do {
                mediaPreview = try await attachmentPreviewProvider.preview(for: media.chatAttachment)
            } catch {
                errorMessage = message(for: error)
            }
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "动态操作失败"
    }
}

@MainActor
private struct DynamicReplyRow: View {
    let reply: DynamicPost

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DynamicAvatarView(author: reply.author, size: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(DynamicText.nonBlank(reply.author.nickname) ?? DynamicText.nonBlank(reply.author.username) ?? "用户")
                        .font(.subheadline.weight(.semibold))
                    Text("@\(DynamicText.nonBlank(reply.author.username) ?? "user")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(reply.content)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("dynamic.detail.reply.\(reply.id)")
    }
}
