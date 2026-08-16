import Foundation
import UniformTypeIdentifiers

protocol ChatAttachmentUploading: Sendable {
    func upload(sourceURL: URL, batchId: String) async throws -> ChatAttachment
}

struct RemoteChatAttachmentUploader: ChatAttachmentUploading, Sendable {
    private let manager: TransferManager

    init(manager: TransferManager) { self.manager = manager }

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
        let kind = contentType?.conforms(to: .image) == true ? "image" : "file"
        return ChatAttachment(
            kind: kind,
            fileId: result.fileId,
            fileName: sourceURL.lastPathComponent,
            fileSize: Int64(values.fileSize ?? 0),
            mimeType: mimeType
        )
    }
}
