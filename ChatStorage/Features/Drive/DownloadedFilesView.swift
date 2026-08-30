import AVFoundation
import Photos
import SwiftUI
import UIKit

private enum DownloadedFilesFilter: String, CaseIterable, Identifiable {
    case all, images, videos, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .images: return "图片"
        case .videos: return "视频"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .images: return "photo"
        case .videos: return "video"
        case .other: return "doc"
        }
    }
}

private enum DownloadedFilesLayout: String {
    case list, grid
}

struct DownloadedFilesView: View {
    let store: DownloadedFileStore
    let transferStore: FileTransferTaskStore?
    let userId: Int64
    let serverScopeID: String

    @State private var records: [DownloadedFileRecord] = []
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var savingRecordIDs: Set<String> = []
    @State private var selectedRecordIDs: Set<String> = []
    @State private var isSelecting = false
    @State private var filter: DownloadedFilesFilter = .all
    @State private var layout: DownloadedFilesLayout = .list
    @State private var showsBatchDeleteConfirmation = false
    @State private var fullscreenPreview: DrivePreview?
    @State private var quickLookPreview: DrivePreview?

    init(
        store: DownloadedFileStore,
        transferStore: FileTransferTaskStore? = nil,
        userId: Int64 = 0,
        serverScopeID: String = ServerConfiguration.default.storageScopeID
    ) {
        self.store = store
        self.transferStore = transferStore
        self.userId = userId
        self.serverScopeID = serverScopeID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if records.isEmpty {
                    ContentUnavailableView(
                        "暂无已下载文件",
                        systemImage: "arrow.down.circle",
                        description: Text("从网盘下载完成的文件会显示在这里")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    summary
                    filterBar
                    if filteredRecords.isEmpty {
                        ContentUnavailableView(
                            "没有匹配附件",
                            systemImage: filter.systemImage,
                            description: Text("切换附件类型查看其他下载内容")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else if layout == .list {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredRecords) { record in
                                listCard(record)
                            }
                        }
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(filteredRecords) { record in
                                gridCard(record)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("已下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSelecting.toggle()
                            if !isSelecting { selectedRecordIDs.removeAll() }
                        }
                    } label: {
                        Label(isSelecting ? "完成" : "选择", systemImage: isSelecting ? "checkmark" : "checklist")
                    }
                    .accessibilityIdentifier("downloaded.selection")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            layout = layout == .list ? .grid : .list
                        }
                    } label: {
                        Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                    }
                    .accessibilityLabel(layout == .list ? "切换大图" : "切换列表")
                    .accessibilityIdentifier("downloaded.layout")

                    Menu {
                        Button("全部清除", role: .destructive) { clearAll() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多已下载操作")
                    .accessibilityIdentifier("downloaded.more")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selectedRecordIDs.isEmpty {
                batchActionBar
            }
        }
        .task {
            records = await store.all()
            for await values in store.stream() {
                records = values
                selectedRecordIDs.formIntersection(values.map(\.id))
            }
        }
        .sheet(item: $quickLookPreview) { preview in
            DrivePreviewView(preview: preview)
        }
        .fullScreenCover(item: $fullscreenPreview) { preview in
            // 图片和视频都直接进入与网盘在线播放一致的沉浸式查看模式。
            DrivePreviewView(preview: preview, startsFullscreen: true)
        }
        .alert("已下载操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请稍后重试")
        }
        .alert("相册保存", isPresented: Binding(
            get: { noticeMessage != nil },
            set: { if !$0 { noticeMessage = nil } }
        )) {
            Button("知道了") { noticeMessage = nil }
        } message: {
            Text(noticeMessage ?? "")
        }
        .alert("确认删除所选附件", isPresented: $showsBatchDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { removeSelected() }
        } message: {
            Text("将删除所选的 \(selectedRecordIDs.count) 个记录及其本机文件，此操作无法恢复。")
        }
    }

    private var filteredRecords: [DownloadedFileRecord] {
        records.filter { record in
            switch filter {
            case .all: return true
            case .images: return record.isImage
            case .videos: return record.isVideo
            case .other: return !record.isImage && !record.isVideo
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DownloadedFilesFilter.allCases) { value in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { filter = value }
                    } label: {
                        Label(value.title, systemImage: value.systemImage)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(filter == value ? .white : AppTheme.primaryGreen)
                            .background(
                                filter == value ? AppTheme.primaryGreen : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == value ? .isSelected : [])
                    .accessibilityIdentifier("downloaded.filter.\(value.rawValue)")
                }
            }
        }
        .accessibilityIdentifier("downloaded.filters")
    }

    private func listCard(_ record: DownloadedFileRecord) -> some View {
        HStack(spacing: 10) {
            Button { handleTap(record) } label: {
                HStack(spacing: 12) {
                    if isSelecting { selectionIndicator(for: record) }
                    downloadedRow(record)
                }
            }
            .buttonStyle(.plain)

            if !isSelecting {
                actionMenu(for: record)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            if record.isImage || record.isVideo {
                Button("保存到相册", systemImage: "square.and.arrow.down") { saveToPhotos([record]) }
            }
            Button("删除记录和文件", systemImage: "trash", role: .destructive) { remove(record) }
        }
        .accessibilityIdentifier("downloaded.row.\(record.id)")
    }

    private func gridCard(_ record: DownloadedFileRecord) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { handleTap(record) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        DownloadedFileThumbnail(record: record, store: store)
                            .frame(maxWidth: .infinity)
                            .frame(height: 142)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        if isSelecting {
                            selectionIndicator(for: record)
                                .padding(8)
                        }
                    }
                    Text(record.fileName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file)) · \(DriveDateFormatter.string(for: record.downloadedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if !isSelecting {
                actionMenu(for: record)
                    .padding(8)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            if record.isImage || record.isVideo {
                Button("保存到相册", systemImage: "square.and.arrow.down") { saveToPhotos([record]) }
            }
            Button("删除记录和文件", systemImage: "trash", role: .destructive) { remove(record) }
        }
        .accessibilityIdentifier("downloaded.grid.\(record.id)")
    }

    private func actionMenu(for record: DownloadedFileRecord) -> some View {
        Menu {
            if record.isImage || record.isVideo {
                Button {
                    saveToPhotos([record])
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                }
                .disabled(!savingRecordIDs.isEmpty)
            }
            Button("删除记录和文件", systemImage: "trash", role: .destructive) {
                remove(record)
            }
        } label: {
            if savingRecordIDs.contains(record.id) {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("downloaded.actions.\(record.id)")
    }

    private func selectionIndicator(for record: DownloadedFileRecord) -> some View {
        Image(systemName: selectedRecordIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selectedRecordIDs.contains(record.id) ? AppTheme.primaryGreen : .secondary)
            .accessibilityHidden(true)
    }

    private var batchActionBar: some View {
        HStack(spacing: 14) {
            Text("已选 \(selectedRecordIDs.count) 项")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                saveToPhotos(selectedRecords)
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .disabled(selectedRecords.filter { $0.isImage || $0.isVideo }.isEmpty || !savingRecordIDs.isEmpty)
            Button(role: .destructive) {
                showsBatchDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectedRecords: [DownloadedFileRecord] {
        records.filter { selectedRecordIDs.contains($0.id) }
    }

    private func handleTap(_ record: DownloadedFileRecord) {
        if isSelecting {
            if selectedRecordIDs.contains(record.id) {
                selectedRecordIDs.remove(record.id)
            } else {
                selectedRecordIDs.insert(record.id)
            }
        } else {
            open(record)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.primaryGreen)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("已下载文件")
                    .font(.subheadline.weight(.semibold))
                Text("共 \(records.count) 个 · \(formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("downloaded.summary")
    }

    private func downloadedRow(_ record: DownloadedFileRecord) -> some View {
        HStack(spacing: 12) {
            DownloadedFileThumbnail(record: record, store: store)
                .frame(width: 72, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                    Text("·")
                    Text(DriveDateFormatter.string(for: record.downloadedAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityLabel("打开\(typeName(for: record))：\(record.fileName)")
        .accessibilityIdentifier("downloaded.row.\(record.id)")
    }

    private var formattedBytes: String {
        let bytes = records.reduce(Int64(0)) { $0 + max($1.fileSize, 0) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func open(_ record: DownloadedFileRecord) {
        Task { @MainActor in
            do {
                let access = try await store.fileAccess(for: record)
                guard FileManager.default.fileExists(atPath: access.url.path) else {
                    errorMessage = "本地文件不存在，无法打开"
                    return
                }
                let entry = DriveFileEntry(
                    id: record.remoteFileId ?? 0,
                    parentId: 0,
                    name: record.fileName,
                    path: access.url.path,
                    size: record.fileSize,
                    fileType: record.fileType,
                    isFile: true,
                    hasChildren: false,
                    modifiedAt: record.downloadedAt
                )
                let kind: DrivePreviewKind = record.isImage
                    ? .image
                    : record.isVideo ? .video : .downloaded
                let preview = DrivePreview(
                    entry: entry,
                    url: access.url,
                    kind: kind,
                    access: access,
                    id: "downloaded-\(record.id)"
                )
                if record.isImage || record.isVideo {
                    fullscreenPreview = preview
                } else {
                    quickLookPreview = preview
                }
            } catch {
                errorMessage = "本地文件无法访问，请确认文件仍然存在"
            }
        }
    }

    private func remove(_ record: DownloadedFileRecord) {
        remove(records: [record])
    }

    private func removeSelected() {
        let targets = selectedRecords
        guard !targets.isEmpty else { return }
        remove(records: targets)
    }

    private func remove(records targets: [DownloadedFileRecord]) {
        let ids = Set(targets.map(\.id))
        Task { @MainActor in
            do {
                // Store 会先删除本地文件（含未完成残留），再删除客户端记录。
                try await store.remove(ids: ids)
                try await transferStore?.removeCompletedDownloads(
                    ids: ids,
                    userId: userId,
                    serverScopeID: serverScopeID
                )
                selectedRecordIDs.subtract(ids)
                if selectedRecordIDs.isEmpty { isSelecting = false }
            } catch {
                errorMessage = "删除记录或本地文件失败"
            }
        }
    }

    private func clearAll() {
        Task { @MainActor in
            do {
                let ids = Set(records.map(\.id))
                try await store.clear()
                try await transferStore?.removeCompletedDownloads(
                    ids: ids,
                    userId: userId,
                    serverScopeID: serverScopeID
                )
                selectedRecordIDs.removeAll()
                isSelecting = false
            } catch {
                errorMessage = "清除记录或本地文件失败"
            }
        }
    }

    private func saveToPhotos(_ record: DownloadedFileRecord) {
        saveToPhotos([record])
    }

    private func saveToPhotos(_ targets: [DownloadedFileRecord]) {
        let recordsToSave = targets.filter { $0.isImage || $0.isVideo }
        guard !recordsToSave.isEmpty, savingRecordIDs.isEmpty else { return }
        savingRecordIDs = Set(recordsToSave.map(\.id))
        Task { @MainActor in
            defer { savingRecordIDs.removeAll() }
            var successCount = 0
            var failedCount = 0
            for record in recordsToSave {
                do {
                    let access = try await store.fileAccess(for: record)
                    guard FileManager.default.fileExists(atPath: access.url.path) else {
                        throw DownloadedFilePhotoSaverError.fileMissing
                    }
                    try await DownloadedFilePhotoSaver.save(record: record, access: access)
                    successCount += 1
                } catch {
                    failedCount += 1
                }
            }
            if failedCount == 0 {
                noticeMessage = "已保存 \(successCount) 个附件到系统相册"
            } else if successCount == 0 {
                errorMessage = "保存到相册失败，请稍后重试"
            } else {
                noticeMessage = "已保存 \(successCount) 个附件，\(failedCount) 个失败"
            }
        }
    }

    private func typeName(for record: DownloadedFileRecord) -> String {
        if record.isImage { return "图片" }
        if record.isVideo { return "视频" }
        return "文件"
    }
}

private enum DownloadedFilePhotoSaver {
    static func save(record: DownloadedFileRecord, access: TransferScopedURLAccess) async throws {
        guard record.isImage || record.isVideo else { throw DownloadedFilePhotoSaverError.unsupported }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolvedAuthorization: PHAuthorizationStatus
        if authorization == .notDetermined {
            resolvedAuthorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            resolvedAuthorization = authorization
        }
        guard resolvedAuthorization == .authorized || resolvedAuthorization == .limited else {
            throw DownloadedFilePhotoSaverError.authorizationDenied
        }

        let url = access.url
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let resourceType: PHAssetResourceType = record.isImage ? .photo : .video
                request.addResource(with: resourceType, fileURL: url, options: nil)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? DownloadedFilePhotoSaverError.saveFailed)
                }
            }
        }
    }
}

private enum DownloadedFilePhotoSaverError: LocalizedError {
    case unsupported
    case authorizationDenied
    case fileMissing
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "只有图片和视频可以保存到相册"
        case .authorizationDenied:
            return "没有相册写入权限，请在系统设置中允许访问照片"
        case .fileMissing:
            return "本地文件不存在，无法保存到相册"
        case .saveFailed:
            return "保存到相册失败，请稍后重试"
        }
    }
}

private struct DownloadedFileThumbnail: View {
    let record: DownloadedFileRecord
    let store: DownloadedFileStore

    @State private var thumbnail: UIImage?
    @State private var access: TransferScopedURLAccess?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(iconColor)
            }

            if record.isVideo {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.6), in: Circle())
            }
        }
        .clipped()
        .task(id: record.id) { await loadThumbnail() }
        .accessibilityHidden(true)
    }

    private var iconName: String {
        switch record.fileExtension {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": "photo.fill"
        case "mp4", "mov", "m4v", "mkv", "avi", "webm": "video.fill"
        case "pdf": "doc.richtext.fill"
        case "zip", "rar", "7z": "archivebox.fill"
        case "doc", "docx", "txt", "rtf": "doc.text.fill"
        case "xls", "xlsx", "csv": "tablecells.fill"
        default: "doc.fill"
        }
    }

    private var iconColor: Color {
        if record.isImage { return .orange }
        if record.isVideo { return AppTheme.documentBlue }
        if record.fileExtension == "pdf" { return .red }
        return AppTheme.primaryGreen
    }

    @MainActor
    private func loadThumbnail() async {
        guard record.isImage || record.isVideo, !Task.isCancelled else { return }
        guard let resolvedAccess = try? await store.fileAccess(for: record) else { return }
        access = resolvedAccess
        let url = resolvedAccess.url

        if record.isImage {
            thumbnail = UIImage(contentsOfFile: url.path)
            return
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        for second in [0.0, 1.0, 2.0] {
            guard !Task.isCancelled else { return }
            if let result = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)) {
                thumbnail = UIImage(cgImage: result.image)
                return
            }
        }
    }
}
