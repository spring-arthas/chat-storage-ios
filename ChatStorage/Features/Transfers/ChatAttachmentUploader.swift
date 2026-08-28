import Foundation
import UniformTypeIdentifiers

protocol ChatAttachmentUploading: Sendable {
    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment
}

struct RemoteChatAttachmentUploader: ChatAttachmentUploading, DynamicPhotoLibraryUploading, Sendable {
    private let manager: TransferManager

    init(manager: TransferManager) { self.manager = manager }

    var transferTaskStream: AsyncStream<[TransferTaskRecord]> {
        manager.transferTaskStream
    }

    func transferTask(id: String) async -> TransferTaskRecord? {
        await manager.transferTask(id: id)
    }

    // [修改] 动态本地附件直接转发传输中心的预创建和入队能力。
    func beginDynamicFileUpload(
        fileName: String,
        batchId: String
    ) async throws -> PhotoLibraryUploadPreparation {
        try await manager.beginDynamicFileUpload(fileName: fileName, batchId: batchId)
    }

    func finishDynamicFileUpload(
        _ preparation: PhotoLibraryUploadPreparation,
        sourceURL: URL
    ) async throws {
        try await manager.finishDynamicFileUpload(preparation, sourceURL: sourceURL)
    }

    func failDynamicFileUpload(
        _ preparation: PhotoLibraryUploadPreparation,
        message: String
    ) async {
        await manager.failDynamicFileUpload(preparation, message: message)
    }

    func beginDynamicVideoUpload(
        fileName: String,
        photoLibraryAssetIdentifier: String,
        batchId: String
    ) async throws -> PhotoLibraryUploadPreparation {
        try await manager.beginDynamicVideoUpload(
            fileName: fileName,
            photoLibraryAssetIdentifier: photoLibraryAssetIdentifier,
            batchId: batchId
        )
    }

    func startDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation) async throws {
        try await manager.startDynamicVideoUpload(preparation)
    }

    func retryDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation) async {
        await manager.retryDynamicVideoUpload(preparation)
    }

    func failDynamicVideoUpload(_ preparation: PhotoLibraryUploadPreparation, message: String) async {
        await manager.failDynamicVideoUpload(preparation, message: message)
    }

    // [修改] CHAT_ATTACHMENT 使用兼容占位目录 1，服务端会解析到私有隐藏目录。
    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let result = try await manager.upload(
            sourceURL: sourceURL,
            targetDirectoryId: 1,
            uploadPurpose: "CHAT_ATTACHMENT",
            batchId: batchId
        )
        let contentType = UTType(filenameExtension: sourceURL.pathExtension)
        let mimeType = contentType?.preferredMIMEType ?? "application/octet-stream"
        let kind: String
        if contentType?.conforms(to: .image) == true {
            kind = "image"
        } else if contentType?.conforms(to: .movie) == true || contentType?.conforms(to: .video) == true {
            kind = "video"
        } else {
            kind = "file"
        }
        return ChatAttachment(
            kind: kind,
            fileId: result.fileId,
            fileName: sourceURL.lastPathComponent,
            fileSize: Int64(values.fileSize ?? 0),
            mimeType: mimeType
        )
    }
}
