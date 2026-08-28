import Foundation
import Observation

@MainActor
@Observable
final class DynamicComposerRouteStore {
    private(set) var pendingDraft: DynamicComposerDraft?
    let draftStore: DynamicComposerDraftStore

    init(persistenceKey: String = "default") {
        draftStore = DynamicComposerDraftStore(persistenceKey: persistenceKey)
    }

    func present(_ draft: DynamicComposerDraft) {
        // [修改] 发布入口只保留最新一次草稿，消费后立即清空。
        pendingDraft = draft
    }

    func consume() -> DynamicComposerDraft? {
        defer { pendingDraft = nil }
        return pendingDraft
    }
}

// [修改] 动态草稿独立落盘到 Application Support，退出应用后仍保留媒体顺序和上传状态。
actor DynamicComposerDraftStore {
    private let fileURL: URL

    init(persistenceKey: String = "default") {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChatStorage/DynamicDrafts", isDirectory: true)
        let safeKey = persistenceKey.unicodeScalars.map { scalar in
            scalar.isASCII && (scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar))
                ? String(scalar)
                : "_"
        }.joined()
        fileURL = root.appendingPathComponent("\(safeKey).json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> DynamicComposerPersistedDraft? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? ProtocolJSON.decoder().decode(DynamicComposerPersistedDraft.self, from: data)
    }

    func save(_ draft: DynamicComposerPersistedDraft) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try ProtocolJSON.encoder().encode(draft)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // [修改] 草稿写入失败不能阻断当前发布流程，下一次进入时仍可由传输中心恢复任务。
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

struct DynamicComposerPersistedDraft: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let reference: DynamicReference?
    let mediaItems: [DynamicComposerMediaItem]
}
