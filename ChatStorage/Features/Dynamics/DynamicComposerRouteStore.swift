import Foundation
import Observation

@MainActor
@Observable
final class DynamicComposerRouteStore {
    private(set) var pendingDraft: DynamicComposerDraft?

    func present(_ draft: DynamicComposerDraft) {
        // [修改] 发布入口只保留最新一次草稿，消费后立即清空。
        pendingDraft = draft
    }

    func consume() -> DynamicComposerDraft? {
        defer { pendingDraft = nil }
        return pendingDraft
    }
}
