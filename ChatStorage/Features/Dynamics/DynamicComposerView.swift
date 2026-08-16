import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// [修改] 发布器直接绑定既有状态机，500 字、4 图/1 视频和图片视频互斥规则只保留一个事实源。
@MainActor
struct DynamicComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DynamicComposerViewModel
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedVideo: PhotosPickerItem?
    @State private var selectionErrorMessage: String?
    @State private var isSubmitting = false

    private let routeStore: DynamicComposerRouteStore
    private let currentUser: AuthenticatedUser
    private let onPublished: () -> Void

    init(
        repository: any DynamicRepository,
        attachmentUploader: (any ChatAttachmentUploading)?,
        routeStore: DynamicComposerRouteStore,
        currentUser: AuthenticatedUser,
        onPublished: @escaping () -> Void
    ) {
        _model = State(initialValue: DynamicComposerViewModel(
            repository: repository,
            attachmentUploader: attachmentUploader
        ))
        self.routeStore = routeStore
        self.currentUser = currentUser
        self.onPublished = onPublished
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    composerHeader
                    editor

                    if let reference = model.reference {
                        DynamicReferenceCard(reference: reference, onOpenMedia: nil)
                    }

                    if !model.mediaItems.isEmpty {
                        selectedMediaGrid
                    }

                    mediaToolbar

                    if let message = selectionErrorMessage ?? model.errorMessage {
                        DynamicErrorBanner(message: message) {
                            selectionErrorMessage = nil
                            model.clearError()
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("发布动态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancel() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("发布").fontWeight(.semibold)
                        }
                    }
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("dynamic.composer.publish")
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .task { model.consumeDraft(from: routeStore) }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            Task { await importPhotos(items) }
        }
        .onChange(of: selectedVideo) { _, item in
            guard let item else { return }
            selectedVideo = nil
            Task { await importVideo(item) }
        }
        .onChange(of: model.publishedDynamicID) { _, dynamicID in
            guard dynamicID != nil else { return }
            cleanupStagedMedia()
            onPublished()
            dismiss()
        }
    }

    private var composerHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            DynamicAvatarView(
                author: DynamicAuthor(
                    id: currentUser.id,
                    username: currentUser.username,
                    nickname: DynamicText.nonBlank(currentUser.nickname) ?? currentUser.username,
                    avatar: currentUser.avatar
                ),
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(DynamicText.nonBlank(currentUser.nickname) ?? DynamicText.nonBlank(currentUser.username) ?? "我")
                    .font(.headline)
                Text("公开给好友")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if model.text.isEmpty {
                Text("分享此刻的新鲜事…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: Binding(
                get: { model.text },
                // [修改] 显式保留 MainActor 上下文，绕开 Swift 6.2 对隔离方法引用生成错误 thunk 的 IRGen 崩溃。
                set: { value in model.updateText(value) }
            ))
            .font(.body)
            .lineSpacing(4)
            .frame(minHeight: 150)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("动态正文")
            .accessibilityIdentifier("dynamic.composer.text")
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(model.text.count)/500")
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.text.count >= 500 ? AppTheme.mediaCoral : .secondary)
                .padding(.bottom, 4)
        }
    }

    private var mediaToolbar: some View {
        HStack(spacing: 12) {
            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: 4,
                matching: .images
            ) {
                Label("照片", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isSubmitting)
            .accessibilityIdentifier("dynamic.composer.photos")

            PhotosPicker(selection: $selectedVideo, matching: .videos) {
                Label("视频", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isSubmitting)
            .accessibilityIdentifier("dynamic.composer.video")
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.primaryGreen)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dynamic.composer.media")
    }

    private var selectedMediaGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            ForEach(model.mediaItems) { item in
                DynamicComposerMediaTile(
                    item: item,
                    onRemove: {
                        ChatAttachmentStaging.removeIfManaged(item.localURL)
                        model.removeMedia(itemID: item.id)
                    },
                    onRetry: { Task { await model.retryUpload(itemID: item.id) } }
                )
            }
        }
        .accessibilityIdentifier("dynamic.composer.media-grid")
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            await model.publish()
            isSubmitting = false
        }
    }

    private func cancel() {
        cleanupStagedMedia()
        dismiss()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        var failedCount = 0
        for item in items.prefix(4) {
            do {
                guard let value = try await item.loadTransferable(type: DynamicPickedImageFile.self) else {
                    failedCount += 1
                    continue
                }
                urls.append(value.url)
            } catch {
                failedCount += 1
            }
        }
        guard !urls.isEmpty else {
            selectionErrorMessage = "没有读取到可发布的照片"
            return
        }
        let previousCount = model.mediaItems.count
        model.selectMedia(urls)
        if model.mediaItems.count == previousCount {
            urls.forEach(ChatAttachmentStaging.removeIfManaged)
        }
        if failedCount > 0 {
            selectionErrorMessage = "\(failedCount) 张照片读取失败，其他照片已保留"
        } else {
            selectionErrorMessage = nil
        }
    }

    private func importVideo(_ item: PhotosPickerItem) async {
        do {
            guard let value = try await item.loadTransferable(type: DynamicPickedVideoFile.self) else {
                selectionErrorMessage = "没有读取到可发布的视频"
                return
            }
            let previousCount = model.mediaItems.count
            model.selectMedia([value.url])
            if model.mediaItems.count == previousCount {
                ChatAttachmentStaging.removeIfManaged(value.url)
            } else {
                selectionErrorMessage = nil
            }
        } catch {
            selectionErrorMessage = "视频读取失败，请重试"
        }
    }

    private func cleanupStagedMedia() {
        model.mediaItems.map(\.localURL).forEach(ChatAttachmentStaging.removeIfManaged)
    }
}

@MainActor
private struct DynamicComposerMediaTile: View {
    let item: DynamicComposerMediaItem
    let onRemove: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if item.kind == .image, let image = UIImage(contentsOfFile: item.localURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color(.secondarySystemBackground)
                        Image(systemName: item.kind == .video ? "video.fill" : "doc.fill")
                            .font(.largeTitle)
                            .foregroundStyle(item.kind == .video ? AppTheme.mediaCoral : AppTheme.archiveViolet)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1.35, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .padding(7)
            .buttonStyle(.plain)
            .disabled(item.state == .uploading)
            .accessibilityLabel("移除\(item.localURL.lastPathComponent)")

            VStack {
                Spacer()
                HStack(spacing: 7) {
                    stateIcon
                    Text(stateTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if item.state == .failed {
                        Button("重试", action: onRetry)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("dynamic.composer.retry.\(item.id.uuidString)")
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.black.opacity(0.62))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityIdentifier("dynamic.composer.media.\(item.id.uuidString)")
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch item.state {
        case .preparing:
            Image(systemName: "clock")
        case .uploading:
            ProgressView().controlSize(.mini).tint(.white)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
        }
    }

    private var stateTitle: String {
        switch item.state {
        case .preparing: "准备发送"
        case .uploading: "正在上传"
        case .succeeded: "上传完成"
        case .failed: "上传失败"
        }
    }
}

// [修改] PhotosPicker 直接产出应用暂存文件，发布器继续走 ChatAttachmentUploading，不新增上传协议。
private struct DynamicPickedImageFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(url: try ChatAttachmentStaging.copyTransferredFile(received.file, fallbackExtension: "jpg"))
        }
    }
}

private struct DynamicPickedVideoFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            Self(url: try ChatAttachmentStaging.copyTransferredFile(received.file, fallbackExtension: "mov"))
        }
    }
}
