import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DynamicComposerViewModel {
    private(set) var text = ""
    private(set) var mediaItems: [DynamicComposerMediaItem] = []
    private(set) var reference: DynamicReference?
    private(set) var isPublishing = false
    private(set) var errorMessage: String?
    private(set) var publishedDynamicID: Int64?

    private let repository: any DynamicRepository
    private let attachmentUploader: (any ChatAttachmentUploading)?

    init(
        repository: any DynamicRepository,
        attachmentUploader: (any ChatAttachmentUploading)? = nil
    ) {
        self.repository = repository
        self.attachmentUploader = attachmentUploader
    }

    func updateText(_ value: String) {
        text = String(value.prefix(500))
        errorMessage = nil
    }

    func selectMedia(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let kinds = urls.map(Self.kind(for:))
        guard !kinds.contains(.file) else {
            errorMessage = "仅支持选择图片或视频"
            return
        }

        let selectedKinds = Set(mediaItems.map(\.kind))
        let incomingKinds = Set(kinds)
        if selectedKinds.union(incomingKinds).contains(.image), selectedKinds.union(incomingKinds).contains(.video) {
            errorMessage = "图片和视频不能同时选择"
            return
        }
        if selectedKinds.contains(.video) || incomingKinds.contains(.video) {
            guard mediaItems.isEmpty, urls.count == 1 else {
                errorMessage = "视频最多选择1个"
                return
            }
        }
        if mediaItems.count + urls.count > 4 {
            errorMessage = "照片最多选择4张"
            return
        }

        mediaItems.append(contentsOf: zip(urls, kinds).map {
            DynamicComposerMediaItem(localURL: $0.0, kind: $0.1)
        })
        errorMessage = nil
    }

    func removeAllMedia() {
        mediaItems.removeAll()
        errorMessage = nil
    }

    // [修改] 发布器支持按媒体项删除，删除后清理上一次选择或上传错误。
    func removeMedia(itemID: UUID) {
        mediaItems.removeAll { $0.id == itemID }
        errorMessage = nil
    }

    func retryUpload(itemID: UUID) async {
        guard let index = mediaItems.firstIndex(where: { $0.id == itemID }),
              mediaItems[index].state == .failed else { return }
        errorMessage = nil
        _ = await uploadItem(at: index)
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
        let request = makeCreateRequest()
        do {
            let result = try await repository.create(request)
            publishedDynamicID = result.dynamicId
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
        for index in mediaItems.indices where mediaItems[index].state != .succeeded {
            guard await uploadItem(at: index) else { return false }
        }
        return true
    }

    private func makeCreateRequest() -> DynamicCreateRequest {
        let uploadedMedia = mediaItems.compactMap(\.uploadedMedia)
        let paths = uploadedMedia.map { String($0.fileId) }.joined(separator: ",")
        return DynamicCreateRequest(
            content: text,
            media: uploadedMedia,
            imagePaths: paths.isEmpty ? nil : paths,
            reference: reference
        )
    }

    private func uploadItem(at index: Int) async -> Bool {
        guard mediaItems.indices.contains(index), let attachmentUploader else { return false }
        let identifier = mediaItems[index].id
        let sourceURL = mediaItems[index].localURL
        mediaItems[index].state = .uploading
        do {
            let attachment = try await attachmentUploader.upload(
                sourceURL: sourceURL,
                batchId: "dynamic-\(UUID().uuidString)"
            )
            guard let currentIndex = mediaItems.firstIndex(where: { $0.id == identifier }) else { return false }
            mediaItems[currentIndex].uploadedMedia = DynamicMedia(
                kind: Self.kind(for: attachment),
                fileId: attachment.fileId,
                fileName: attachment.fileName,
                fileSize: attachment.fileSize,
                mimeType: attachment.mimeType
            )
            mediaItems[currentIndex].state = .succeeded
            return true
        } catch {
            if let currentIndex = mediaItems.firstIndex(where: { $0.id == identifier }) {
                mediaItems[currentIndex].state = .failed
            }
            errorMessage = Self.message(for: error)
            return false
        }
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

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "动态发布失败"
    }
}
