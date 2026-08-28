import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DynamicComposerViewModel {
    static let maxMediaCount = 9
    private(set) var text = ""
    private(set) var mediaItems: [DynamicComposerMediaItem] = []
    var remainingMediaCount: Int { max(0, Self.maxMediaCount - mediaItems.count) }
    private(set) var reference: DynamicReference?
    private(set) var isPublishing = false
    private(set) var errorMessage: String?
    private(set) var publishedDynamicID: Int64?

    private let repository: any DynamicRepository
    private let attachmentUploader: (any ChatAttachmentUploading)?
    private let photoLibraryUploader: (any DynamicPhotoLibraryUploading)?
    private let draftStore: DynamicComposerDraftStore?
    private var draftID = UUID()
    private var uploadTasks: [UUID: Task<Bool, Never>] = [:]
    private var transferObservationTask: Task<Void, Never>?

    init(
        repository: any DynamicRepository,
        attachmentUploader: (any ChatAttachmentUploading)? = nil,
        draftStore: DynamicComposerDraftStore? = nil
    ) {
        self.repository = repository
        self.attachmentUploader = attachmentUploader
        self.photoLibraryUploader = attachmentUploader as? any DynamicPhotoLibraryUploading
        self.draftStore = draftStore
        startTransferObservation()
    }

    func updateText(_ value: String) {
        text = String(value.prefix(500))
        errorMessage = nil
        persistDraft()
    }

    @discardableResult
    func selectMedia(_ urls: [URL]) -> Int {
        guard !urls.isEmpty else { return 0 }
        let kinds = urls.map(Self.kind(for:))
        guard !kinds.contains(.file) else {
            errorMessage = "仅支持选择图片或视频"
            return 0
        }

        let acceptedCount = min(urls.count, remainingMediaCount)
        guard acceptedCount > 0 else {
            errorMessage = "照片和视频最多选择9个"
            return 0
        }
        mediaItems.append(contentsOf: zip(urls.prefix(acceptedCount), kinds.prefix(acceptedCount)).map {
            DynamicComposerMediaItem(localURL: $0.0, kind: $0.1)
        })
        errorMessage = acceptedCount == urls.count ? nil : "照片和视频最多选择9个"
        persistDraft()
        beginUploads(for: mediaItems.suffix(acceptedCount).map(\.id))
        return acceptedCount
    }

    // [修改] 本地附件先插入动态草稿并在传输中心创建 preparing 任务，再等待 PhotosPicker 读取源文件。
    @discardableResult
    func prepareLocalMedia(
        fileName: String,
        kind: DynamicMediaKind,
        photoLibraryAssetIdentifier: String? = nil
    ) async -> UUID? {
        guard let photoLibraryUploader else {
            errorMessage = "媒体上传不可用"
            return nil
        }
        guard mediaItems.count < Self.maxMediaCount else {
            errorMessage = "照片和视频最多选择9个"
            return nil
        }

        let itemID = UUID()
        let item = DynamicComposerMediaItem(
            id: itemID,
            // [修改] 图片文件尚在导出时也保留 Photos 标识，发布页可先显示原图缩略图。
            localURL: photoLibraryAssetIdentifier.map { URL(string: "photos-library://\($0)")! }
                ?? URL(fileURLWithPath: "/dev/null"),
            kind: kind,
            photoLibraryAssetIdentifier: photoLibraryAssetIdentifier
        )
        mediaItems.append(item)
        errorMessage = nil
        persistDraft()

        do {
            let preparation = try await photoLibraryUploader.beginDynamicFileUpload(
                fileName: fileName,
                batchId: item.uploadBatchID
            )
            guard let index = mediaItems.firstIndex(where: { $0.id == itemID }) else { return nil }
            mediaItems[index].transferTaskID = preparation.taskId
            persistDraft()
            return itemID
        } catch {
            if let index = mediaItems.firstIndex(where: { $0.id == itemID }) {
                mediaItems[index].state = .failed
            }
            errorMessage = Self.message(for: error)
            persistDraft()
            return nil
        }
    }

    // [修改] PhotosPicker 源文件就绪后，把同一条 preparing 任务交回传输中心并等待实际上传完成。
    func finishLocalMediaUpload(itemID: UUID, sourceURL: URL) async -> Bool {
        guard let photoLibraryUploader,
              let index = mediaItems.firstIndex(where: { $0.id == itemID }),
              let taskID = mediaItems[index].transferTaskID else {
            return false
        }
        mediaItems[index].localURL = sourceURL
        persistDraft()
        do {
            try await photoLibraryUploader.finishDynamicFileUpload(
                PhotoLibraryUploadPreparation(taskId: taskID),
                sourceURL: sourceURL
            )
            let task = Task { [weak self] in
                guard let self else { return false }
                return await self.waitUntilUploadTerminal(itemID: itemID)
            }
            uploadTasks[itemID] = task
            return await task.value
        } catch {
            await markDynamicFileUploadFailed(
                itemID: itemID,
                message: Self.message(for: error),
                taskID: taskID
            )
            return false
        }
    }

    // [修改] 源文件读取失败时保留已显示的传输任务，并将其置为可重试的失败状态。
    func failLocalMediaUpload(itemID: UUID, message: String) async {
        guard let index = mediaItems.firstIndex(where: { $0.id == itemID }) else { return }
        if let taskID = mediaItems[index].transferTaskID, let photoLibraryUploader {
            await photoLibraryUploader.failDynamicFileUpload(
                PhotoLibraryUploadPreparation(taskId: taskID),
                message: message
            )
        }
        mediaItems[index].state = .failed
        errorMessage = message
        persistDraft()
    }

    func removeAllMedia() {
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        mediaItems.removeAll()
        errorMessage = nil
        persistDraft()
    }

    // [修改] 发布器支持按媒体项删除，删除后清理上一次选择或上传错误。
    func removeMedia(itemID: UUID) {
        uploadTasks[itemID]?.cancel()
        uploadTasks.removeValue(forKey: itemID)
        mediaItems.removeAll { $0.id == itemID }
        errorMessage = nil
        persistDraft()
    }

    func retryUpload(itemID: UUID) async {
        guard let index = mediaItems.firstIndex(where: { $0.id == itemID }),
              mediaItems[index].state == .failed else { return }
        errorMessage = nil
        let task: Task<Bool, Never>
        if mediaItems[index].photoLibraryAssetIdentifier != nil, photoLibraryUploader != nil {
            task = beginPhotoLibraryUpload(for: itemID, replacingExisting: true)
        } else {
            task = beginUpload(for: itemID, replacingExisting: true)
        }
        _ = await task.value
    }

    // [修改] 视频选择后先插入动态项并创建 preparing 任务，随后直接从 Photos 分块上传。
    @discardableResult
    func selectPhotoLibraryVideo(fileName: String, assetIdentifier: String) async -> Bool {
        guard let photoLibraryUploader else {
            errorMessage = "视频上传服务不可用"
            return false
        }
        guard mediaItems.count < Self.maxMediaCount else {
            errorMessage = "照片和视频最多选择9个"
            return false
        }

        let itemID = UUID()
        let item = DynamicComposerMediaItem(
            id: itemID,
            localURL: URL(string: "photos-library://\(assetIdentifier)")!,
            kind: .video,
            photoLibraryAssetIdentifier: assetIdentifier
        )
        mediaItems.append(item)
        errorMessage = nil
        persistDraft()

        var preparation: PhotoLibraryUploadPreparation?
        do {
            // [修改] 选择相册视频时在当前调用内完成任务落库，返回前传输中心已有可见记录。
            let newPreparation = try await photoLibraryUploader.beginDynamicVideoUpload(
                fileName: fileName,
                photoLibraryAssetIdentifier: assetIdentifier,
                batchId: item.uploadBatchID
            )
            preparation = newPreparation
            guard let index = mediaItems.firstIndex(where: { $0.id == itemID }) else { return false }
            mediaItems[index].transferTaskID = newPreparation.taskId
            persistDraft()
            try await photoLibraryUploader.startDynamicVideoUpload(newPreparation)
        } catch {
            await markPhotoLibraryUploadFailed(
                itemID: itemID,
                message: Self.message(for: error),
                preparation: preparation
            )
            return false
        }
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.waitUntilUploadTerminal(itemID: itemID)
        }
        uploadTasks[itemID] = task
        return true
    }

    func publish() async {
        guard !isPublishing else { return }
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !mediaItems.isEmpty || reference != nil else {
            errorMessage = "请输入内容或添加媒体"
            return
        }
        guard await uploadPendingMedia() else { return }

        isPublishing = true
        errorMessage = nil
        guard let request = makeCreateRequest() else {
            isPublishing = false
            return
        }
        do {
            let result = try await repository.create(request)
            publishedDynamicID = result.dynamicId
            await draftStore?.clear()
        } catch {
            errorMessage = Self.message(for: error)
        }
        isPublishing = false
    }

    func retryPublish() async {
        await publish()
    }

    func consumeDraft(from store: DynamicComposerRouteStore) {
        guard let draft = store.consume() else { return }
        updateText(draft.text)
        reference = draft.reference
        persistDraft()
    }

    // [修改] Restore the persistent draft and resume unfinished media uploads when the composer opens.
    func restorePersistedDraft() async {
        guard mediaItems.isEmpty, text.isEmpty, reference == nil, let draftStore,
              let draft = await draftStore.load() else { return }
        draftID = draft.id
        text = String(draft.text.prefix(500))
        reference = draft.reference
        mediaItems = Array(draft.mediaItems.prefix(Self.maxMediaCount))
        errorMessage = nil
        mediaItems.filter { $0.state != .succeeded }.forEach { item in
            if item.photoLibraryAssetIdentifier != nil, photoLibraryUploader != nil {
                _ = beginPhotoLibraryUpload(for: item.id)
            } else {
                _ = beginUpload(for: item.id)
            }
        }
    }

    func discardDraft() async {
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        await draftStore?.clear()
    }

    // [修改] 测试和发布流程都可以等待自动上传任务收敛，避免发布请求早于最后一个媒体结果。
    func waitForPendingUploads() async {
        let tasks = Array(uploadTasks.values)
        for task in tasks { _ = await task.value }
    }

    func clearError() {
        errorMessage = nil
    }

    private func uploadPendingMedia() async -> Bool {
        guard !mediaItems.isEmpty else { return true }
        guard attachmentUploader != nil else {
            errorMessage = "媒体上传不可用"
            return false
        }
        let itemIDs = mediaItems.map(\.id)
        for itemID in itemIDs {
            guard let item = mediaItems.first(where: { $0.id == itemID }) else { continue }
            if item.state == .succeeded { continue }
            if let task = uploadTasks[itemID] {
                guard await task.value else { return false }
            } else {
                // [修改] 预创建任务尚未拿到源文件时只等待选择流程，禁止回退到旧 upload() 产生重复任务。
                guard item.transferTaskID == nil || item.state != .preparing else {
                    errorMessage = "附件仍在准备中，请稍后重试"
                    return false
                }
                guard await uploadItem(itemID: itemID) else { return false }
            }
        }
        return true
    }

    // [修改] 发布请求必须和已选择媒体一一对应，禁止 compactMap 静默丢附件后提交不完整动态。
    private func makeCreateRequest() -> DynamicCreateRequest? {
        let uploadedMedia = mediaItems.map(\.uploadedMedia)
        guard uploadedMedia.allSatisfy({ $0 != nil }) else {
            errorMessage = "仍有附件未完成上传，请稍后重试"
            return nil
        }
        let media = uploadedMedia.compactMap { $0 }
        guard media.count == mediaItems.count, media.count <= Self.maxMediaCount else {
            errorMessage = "动态附件数量无效，请重新选择"
            return nil
        }
        let paths = media.map { String($0.fileId) }.joined(separator: ",")
        return DynamicCreateRequest(
            content: text,
            media: media,
            imagePaths: paths.isEmpty ? nil : paths,
            reference: reference
        )
    }

    private func uploadItem(itemID: UUID) async -> Bool {
        guard let index = mediaItems.firstIndex(where: { $0.id == itemID }), let attachmentUploader else {
            errorMessage = "媒体上传不可用"
            return false
        }
        let sourceURL = mediaItems[index].localURL
        let batchID = mediaItems[index].uploadBatchID
        mediaItems[index].state = .uploading
        persistDraft()
        do {
            let attachment = try await attachmentUploader.upload(
                sourceURL: sourceURL,
                batchId: batchID
            )
            guard let currentIndex = mediaItems.firstIndex(where: { $0.id == itemID }) else { return false }
            mediaItems[currentIndex].uploadedMedia = DynamicMedia(
                kind: Self.kind(for: attachment),
                fileId: attachment.fileId,
                fileName: attachment.fileName,
                fileSize: attachment.fileSize,
                mimeType: attachment.mimeType
            )
            mediaItems[currentIndex].state = .succeeded
            mediaItems[currentIndex].progress = 1
            persistDraft()
            return true
        } catch {
            if let currentIndex = mediaItems.firstIndex(where: { $0.id == itemID }) {
                mediaItems[currentIndex].state = .failed
            }
            errorMessage = Self.message(for: error)
            persistDraft()
            return false
        }
    }

    private func beginUploads(for itemIDs: [UUID]) {
        itemIDs.forEach { _ = beginUpload(for: $0) }
    }

    private func beginUpload(for itemID: UUID, replacingExisting: Bool = false) -> Task<Bool, Never> {
        if !replacingExisting, let existing = uploadTasks[itemID] { return existing }
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.uploadItem(itemID: itemID)
        }
        uploadTasks[itemID] = task
        return task
    }

    private func beginPhotoLibraryUpload(
        for itemID: UUID,
        replacingExisting: Bool = false
    ) -> Task<Bool, Never> {
        if !replacingExisting, let existing = uploadTasks[itemID] { return existing }
        guard let photoLibraryUploader,
              let item = mediaItems.first(where: { $0.id == itemID }),
              let assetIdentifier = item.photoLibraryAssetIdentifier else {
            return Task { false }
        }
        let task = Task { [weak self] in
            guard let self else { return false }
            guard let taskID = item.transferTaskID else {
                return await self.startNewPhotoLibraryUpload(
                    item: item,
                    assetIdentifier: assetIdentifier,
                    uploader: photoLibraryUploader
                )
            }
            self.setPreparingState(for: itemID)
            await photoLibraryUploader.retryDynamicVideoUpload(
                PhotoLibraryUploadPreparation(taskId: taskID)
            )
            return await self.waitUntilUploadTerminal(itemID: itemID)
        }
        uploadTasks[itemID] = task
        return task
    }

    private func startNewPhotoLibraryUpload(
        item: DynamicComposerMediaItem,
        assetIdentifier: String,
        uploader: any DynamicPhotoLibraryUploading
    ) async -> Bool {
        var preparation: PhotoLibraryUploadPreparation?
        do {
            let newPreparation = try await uploader.beginDynamicVideoUpload(
                fileName: item.localURL.lastPathComponent,
                photoLibraryAssetIdentifier: assetIdentifier,
                batchId: item.uploadBatchID
            )
            preparation = newPreparation
            guard let index = mediaItems.firstIndex(where: { $0.id == item.id }) else { return false }
            mediaItems[index].transferTaskID = newPreparation.taskId
            setPreparingState(for: item.id)
            persistDraft()
            try await uploader.startDynamicVideoUpload(newPreparation)
            return await waitUntilUploadTerminal(itemID: item.id)
        } catch {
            await markPhotoLibraryUploadFailed(
                itemID: item.id,
                message: Self.message(for: error),
                preparation: preparation
            )
            return false
        }
    }

    private func waitUntilUploadTerminal(itemID: UUID) async -> Bool {
        if let item = mediaItems.first(where: { $0.id == itemID }),
           let taskID = item.transferTaskID,
           let record = await photoLibraryUploader?.transferTask(id: taskID) {
            applyTransferSnapshot([record])
        }
        while !Task.isCancelled {
            guard let item = mediaItems.first(where: { $0.id == itemID }) else { return false }
            if item.state == .succeeded { return true }
            if item.state == .failed { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func setPreparingState(for itemID: UUID) {
        guard let index = mediaItems.firstIndex(where: { $0.id == itemID }) else { return }
        mediaItems[index].state = .preparing
        errorMessage = nil
        persistDraft()
    }

    private func markPhotoLibraryUploadFailed(
        itemID: UUID,
        message: String,
        preparation: PhotoLibraryUploadPreparation?
    ) async {
        if let preparation, let photoLibraryUploader {
            await photoLibraryUploader.failDynamicVideoUpload(preparation, message: message)
        }
        guard let index = mediaItems.firstIndex(where: { $0.id == itemID }) else { return }
        mediaItems[index].state = .failed
        errorMessage = message
        persistDraft()
    }

    private func markDynamicFileUploadFailed(
        itemID: UUID,
        message: String,
        taskID: String
    ) async {
        if let photoLibraryUploader {
            await photoLibraryUploader.failDynamicFileUpload(
                PhotoLibraryUploadPreparation(taskId: taskID),
                message: message
            )
        }
        guard let index = mediaItems.firstIndex(where: { $0.id == itemID }) else { return }
        mediaItems[index].state = .failed
        errorMessage = message
        persistDraft()
    }

    private func startTransferObservation() {
        guard let photoLibraryUploader else { return }
        let stream = photoLibraryUploader.transferTaskStream
        transferObservationTask = Task { [weak self] in
            for await records in stream {
                guard !Task.isCancelled else { return }
                self?.applyTransferSnapshot(records)
            }
        }
    }

    private func applyTransferSnapshot(_ records: [TransferTaskRecord]) {
        var changed = false
        for record in records where record.direction == .upload {
            guard let index = mediaItems.firstIndex(where: { item in
                item.transferTaskID == record.id || (item.transferTaskID == nil && item.uploadBatchID == record.batchId)
            }) else { continue }

            if mediaItems[index].transferTaskID == nil {
                mediaItems[index].transferTaskID = record.id
                changed = true
            }
            let progress = record.status == .completed ? 1 : record.progress
            if mediaItems[index].progress != progress {
                mediaItems[index].progress = progress
                changed = true
            }
            switch record.status {
            case .preparing, .queued, .hashing, .running, .verifying, .paused, .pausedAuthentication:
                if mediaItems[index].state != .uploading && record.status != .preparing && record.status != .queued {
                    mediaItems[index].state = .uploading
                    changed = true
                }
            case .completed:
                if let remoteFileId = record.remoteFileId {
                    mediaItems[index].uploadedMedia = DynamicMedia(
                        kind: mediaItems[index].kind,
                        fileId: remoteFileId,
                        fileName: record.fileName,
                        fileSize: record.fileSize,
                        mimeType: Self.mimeType(for: record.fileType, kind: mediaItems[index].kind)
                    )
                    mediaItems[index].state = .succeeded
                    changed = true
                }
            case .failed, .cancelled:
                mediaItems[index].state = .failed
                errorMessage = record.errorMessage ?? "上传失败"
                changed = true
            }
        }
        if changed { persistDraft() }
    }

    private func persistDraft() {
        guard let draftStore else { return }
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !mediaItems.isEmpty
            || reference != nil
        if !hasContent {
            Task { await draftStore.clear() }
            return
        }
        let snapshot = DynamicComposerPersistedDraft(
            id: draftID,
            text: text,
            reference: reference,
            mediaItems: mediaItems
        )
        Task { await draftStore.save(snapshot) }
    }

    private static func kind(for url: URL) -> DynamicMediaKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .file
    }

    private static func kind(for attachment: ChatAttachment) -> DynamicMediaKind {
        if attachment.isImage { return .image }
        if attachment.isVideo { return .video }
        return .file
    }

    private static func mimeType(for fileType: String, kind: DynamicMediaKind) -> String {
        if let type = UTType(filenameExtension: fileType), let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return kind == .video ? "video/quicktime" : "image/jpeg"
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "动态发布失败"
    }
}
