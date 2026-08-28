import CoreTransferable
import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// [修改] 发布器直接绑定既有状态机，500 字和 9 个混合媒体的规则只保留一个事实源。
@MainActor
struct DynamicComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DynamicComposerViewModel
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedVideos: [PhotosPickerItem] = []
    @State private var selectionErrorMessage: String?
    @State private var isSubmitting = false
    @State private var previewingMedia: DynamicMediaGalleryState?

    private let routeStore: DynamicComposerRouteStore
    private let currentUser: AuthenticatedUser
    private let attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)?
    private let onPublished: () -> Void

    init(
        repository: any DynamicRepository,
        attachmentUploader: (any ChatAttachmentUploading)?,
        attachmentPreviewProvider: (any ChatAttachmentPreviewProviding)? = nil,
        routeStore: DynamicComposerRouteStore,
        currentUser: AuthenticatedUser,
        onPublished: @escaping () -> Void
    ) {
        _model = State(initialValue: DynamicComposerViewModel(
            repository: repository,
            attachmentUploader: attachmentUploader,
            draftStore: routeStore.draftStore
        ))
        self.routeStore = routeStore
        self.currentUser = currentUser
        self.attachmentPreviewProvider = attachmentPreviewProvider
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
                        HStack {
                            Text("已选择 \(model.mediaItems.count)/9")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryGreen)
                            Spacer()
                            Text("照片和视频可混选")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
        .task {
            model.consumeDraft(from: routeStore)
            await model.restorePersistedDraft()
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            Task { await importPhotos(items) }
        }
        .onChange(of: selectedVideos) { _, items in
            guard !items.isEmpty else { return }
            selectedVideos = []
            Task { await importVideos(items) }
        }
        .onChange(of: model.publishedDynamicID) { _, dynamicID in
            guard dynamicID != nil else { return }
            cleanupStagedMedia()
            onPublished()
            dismiss()
        }
        .sheet(item: $previewingMedia) { state in
            if let attachmentPreviewProvider {
                DynamicMediaGalleryView(state: state, previewProvider: attachmentPreviewProvider)
            } else {
                ContentUnavailableView("当前账号没有可用的媒体预览凭据", systemImage: "lock.slash")
            }
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
                maxSelectionCount: model.remainingMediaCount,
                matching: .images
            ) {
                Label("照片", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isSubmitting || model.remainingMediaCount == 0)
            .accessibilityIdentifier("dynamic.composer.photos")

            PhotosPicker(
                selection: $selectedVideos,
                maxSelectionCount: model.remainingMediaCount,
                matching: .videos
            ) {
                Label("视频", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isSubmitting || model.remainingMediaCount == 0)
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
                        DynamicComposerStaging.removeIfManaged(item.localURL)
                        model.removeMedia(itemID: item.id)
                    },
                    onRetry: { Task { await model.retryUpload(itemID: item.id) } },
                    onPreview: { openPreview(for: item) }
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
        Task {
            await model.discardDraft()
            cleanupStagedMedia()
            dismiss()
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var failedCount = 0
        var pendingItems: [(PhotosPickerItem, UUID)] = []
        for item in items.prefix(model.remainingMediaCount) {
            let fileExtension = item.supportedContentTypes
                .first(where: { $0.conforms(to: .image) })?
                .preferredFilenameExtension ?? "jpg"
            let fileName = "照片-\(UUID().uuidString).\(fileExtension)"
            guard let itemID = await model.prepareLocalMedia(
                fileName: fileName,
                kind: .image,
                photoLibraryAssetIdentifier: item.itemIdentifier
            ) else {
                failedCount += 1
                continue
            }
            pendingItems.append((item, itemID))
        }

        // [修改] 所有选中图片先创建任务，再读取源文件，避免后续附件等待前一个文件读取完才显示。
        for (item, itemID) in pendingItems {
            do {
                guard let value = try await item.loadTransferable(type: DynamicPickedImageFile.self) else {
                    await model.failLocalMediaUpload(itemID: itemID, message: "照片读取失败，请重试")
                    failedCount += 1
                    continue
                }
                if !(await model.finishLocalMediaUpload(itemID: itemID, sourceURL: value.url)) {
                    failedCount += 1
                }
            } catch {
                await model.failLocalMediaUpload(itemID: itemID, message: "照片读取失败，请重试")
                failedCount += 1
            }
        }
        guard !pendingItems.isEmpty else {
            selectionErrorMessage = "没有读取到可发布的照片"
            return
        }
        if failedCount > 0 {
            selectionErrorMessage = "\(failedCount) 张照片读取失败，其他照片已保留"
        } else {
            selectionErrorMessage = nil
        }
    }

    private func importVideos(_ items: [PhotosPickerItem]) async {
        var failedCount = 0
        var pendingTransferredVideos: [(PhotosPickerItem, UUID)] = []
        guard await DynamicComposerPhotosAccess.requestReadAccessIfNeeded() else {
            selectionErrorMessage = "没有照片访问权限，无法上传视频"
            return
        }
        for item in items.prefix(model.remainingMediaCount) {
            let fileExtension = item.supportedContentTypes
                .first(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) })?
                .preferredFilenameExtension ?? "mov"
            let fileName = "视频-\(UUID().uuidString).\(fileExtension)"
            switch DynamicComposerVideoSelectionRoute.route(for: item.itemIdentifier) {
            case .photoLibrary(let assetIdentifier):
                if !(await model.selectPhotoLibraryVideo(fileName: fileName, assetIdentifier: assetIdentifier)) {
                    failedCount += 1
                }
            case .transferredFile:
                guard let itemID = await model.prepareLocalMedia(fileName: fileName, kind: .video) else {
                    failedCount += 1
                    continue
                }
                // [修改] 先为所有无资源标识的视频创建任务，再开始读取视频源文件。
                pendingTransferredVideos.append((item, itemID))
            }
        }

        // [修改] 多选视频的每条本地任务先落库，后续大文件读取不会阻塞其他任务显示。
        for (item, itemID) in pendingTransferredVideos {
            do {
                guard let value = try await item.loadTransferable(type: DynamicPickedVideoFile.self) else {
                    await model.failLocalMediaUpload(itemID: itemID, message: "视频读取失败，请重试")
                    failedCount += 1
                    continue
                }
                if !(await model.finishLocalMediaUpload(itemID: itemID, sourceURL: value.url)) {
                    failedCount += 1
                }
            } catch {
                await model.failLocalMediaUpload(itemID: itemID, message: "视频读取失败，请重试")
                failedCount += 1
            }
        }
        if failedCount > 0 {
            selectionErrorMessage = DynamicComposerVideoSelectionRoute.failureMessage(failedCount: failedCount)
        } else {
            selectionErrorMessage = nil
        }
    }

    private func cleanupStagedMedia() {
        model.mediaItems.map(\.localURL).forEach(DynamicComposerStaging.removeIfManaged)
    }

    // [修改] 上传成功后复用动态详情的连续媒体预览，图片和视频保持同一套查看/播放体验。
    private func openPreview(for item: DynamicComposerMediaItem) {
        guard let media = item.uploadedMedia, item.canPreview, attachmentPreviewProvider != nil else { return }
        let uploadedMedia = model.mediaItems.compactMap(\.uploadedMedia)
        previewingMedia = DynamicMediaGalleryState(media: uploadedMedia, selectedMediaID: media.fileId)
    }
}

@MainActor
private struct DynamicComposerMediaTile: View {
    let item: DynamicComposerMediaItem
    let onRemove: () -> Void
    let onRetry: () -> Void
    let onPreview: () -> Void

    @State private var previewImage: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mediaPreview

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .padding(7)
            .buttonStyle(.plain)
            .accessibilityLabel("移除\(item.localURL.lastPathComponent)")
        }
        .task(id: thumbnailKey) {
            previewImage = await DynamicComposerMediaThumbnailLoader.image(for: item)
        }
        .accessibilityIdentifier("dynamic.composer.media.\(item.id.uuidString)")
    }

    private var mediaPreview: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    // [修改] 缩略图尚未返回时保持中性底色，不能显示误导性的红色视频占位图标。
                    Color(.systemGray5)
                    if item.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
            .blur(radius: item.shouldDimPreview ? 5 : 0)

            if item.shouldDimPreview {
                Color.black.opacity(0.24)
            }

            if item.kind == .video, item.canPreview {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }

            // [修改] 成功后只取消媒体朦胧层，底部仍保留“上传完成”反馈，与参考效果一致。
            uploadStatusBar

            if item.canPreview {
                Button(action: onPreview) {
                    Color.clear
                }
                .buttonStyle(.plain)
                .accessibilityLabel("预览\(item.localURL.lastPathComponent)")
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.35, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var uploadStatusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                stateIcon
                Text(statusPresentation.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if statusPresentation.showsProgressTrack {
                    Text("\(Int(statusPresentation.progress * 100))%")
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
                Spacer(minLength: 0)
                if statusPresentation.allowsRetry {
                    Button("重试", action: onRetry)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("dynamic.composer.retry.\(item.id.uuidString)")
                }
            }

            if statusPresentation.showsProgressTrack {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.24))
                        Capsule()
                            .fill(AppTheme.primaryGreen)
                            .frame(width: max(2, proxy.size.width * statusPresentation.progress))
                    }
                }
                .frame(height: 3)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.68))
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch item.state {
        case .preparing:
            Image(systemName: "clock")
        case .uploading:
            Image(systemName: "arrow.up.circle.fill")
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
        }
    }

    private var statusPresentation: DynamicComposerMediaStatusPresentation {
        DynamicComposerMediaStatusPresentation(item: item)
    }

    private var thumbnailKey: String {
        "\(item.localURL.absoluteString)-\(item.photoLibraryAssetIdentifier ?? "")"
    }
}

// [修改] 图片读取本地原图，视频优先读取暂存文件，仍在相册路径时直接取 PHAsset 首帧。
@MainActor
private enum DynamicComposerMediaThumbnailLoader {
    static func image(for item: DynamicComposerMediaItem) async -> UIImage? {
        switch item.kind {
        case .image:
            if item.localURL.isFileURL,
               let image = UIImage(contentsOfFile: item.localURL.path) {
                return image
            }
            guard let identifier = item.photoLibraryAssetIdentifier else { return nil }
            return await photoLibraryImage(identifier: identifier)
        case .video:
            if item.localURL.isFileURL, FileManager.default.fileExists(atPath: item.localURL.path) {
                return await videoImage(from: DynamicComposerVideoAssetBox(AVURLAsset(url: item.localURL)))
            }
            guard let identifier = item.photoLibraryAssetIdentifier else { return nil }
            return await photoLibraryVideoImage(identifier: identifier)
        case .file:
            return nil
        }
    }

    private static func photoLibraryVideoImage(identifier: String) async -> UIImage? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        if let image = await photoLibraryImage(for: asset) {
            return image
        }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = true
        let assetBox = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: DynamicComposerVideoAssetBox(avAsset))
            }
        }
        return await videoImage(from: assetBox)
    }

    // [修改] 视频和图片在文件导出前先从 Photos 取缩略图，选择后立即展示真实内容。
    private static func photoLibraryImage(identifier: String) async -> UIImage? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        return await photoLibraryImage(for: asset)
    }

    private static func photoLibraryImage(for asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 720, height: 720),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // [修改] AVFoundation 对象放入受控盒后再交给非隔离缩略图任务，满足 Swift 6 数据竞争检查。
    nonisolated private static func videoImage(from assetBox: DynamicComposerVideoAssetBox) async -> UIImage? {
        guard let asset = assetBox.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        for second in [0.0, 1.0, 2.0] {
            do {
                let result = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
                return UIImage(cgImage: result.image)
            } catch {
                continue
            }
        }
        return nil
    }
}

private final class DynamicComposerVideoAssetBox: @unchecked Sendable {
    let asset: AVAsset?

    init(_ asset: AVAsset?) {
        self.asset = asset
    }
}

// [修改] PhotosPicker 先通过传输中心创建任务，再产出应用暂存文件并完成同一任务的入队。
private struct DynamicPickedImageFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(url: try DynamicComposerStaging.copyTransferredFile(received.file, fallbackExtension: "jpg"))
        }
    }
}

// [修改] 没有 Photos 资源标识时回退到文件表示，仍通过 ChatAttachmentUploading 创建持久上传任务。
private struct DynamicPickedVideoFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            Self(url: try DynamicComposerStaging.copyTransferredFile(received.file, fallbackExtension: "mov"))
        }
    }
}

// [修改] 资源标识缺失只切换上传路径，不再把选中的视频直接丢弃。
enum DynamicComposerVideoSelectionRoute: Equatable {
    case photoLibrary(assetIdentifier: String)
    case transferredFile

    static func route(for itemIdentifier: String?) -> Self {
        guard let itemIdentifier = itemIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemIdentifier.isEmpty else {
            return .transferredFile
        }
        return .photoLibrary(assetIdentifier: itemIdentifier)
    }

    static func failureMessage(failedCount: Int) -> String {
        "\(failedCount) 个视频读取失败，其他视频已保留"
    }
}

// [修改] 动态照片暂存到 Application Support，视频保留 Photos 资源标识供断点续传。
private enum DynamicComposerStaging {
    static let directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("ChatStorage/DynamicDrafts/Media", isDirectory: true)

    static func copyTransferredFile(_ sourceURL: URL, fallbackExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension.isEmpty ? fallbackExtension : sourceURL.pathExtension
        let destination = directoryURL.appendingPathComponent("媒体-\(UUID().uuidString).\(fileExtension)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func removeIfManaged(_ url: URL) {
        let root = directoryURL.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private enum DynamicComposerPhotosAccess {
    static func requestReadAccessIfNeeded() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let updated = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return updated == .authorized || updated == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
