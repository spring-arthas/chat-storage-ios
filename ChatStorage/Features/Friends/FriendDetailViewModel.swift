import Foundation
import Observation

@MainActor
@Observable
final class FriendDetailViewModel {
    let friend: ChatFriend
    var alias: String
    private(set) var savedAlias: String
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let repository: any ChatRepository

    init(friend: ChatFriend, repository: any ChatRepository) {
        self.friend = friend
        self.repository = repository
        alias = friend.alias ?? ""
        savedAlias = friend.alias ?? ""
    }

    var displayName: String {
        nonBlank(savedAlias) ?? friend.nickname.flatMap(nonBlank) ?? nonBlank(friend.username) ?? "好友"
    }

    @discardableResult
    func saveAlias() async -> Bool {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            errorMessage = "备注不能为空"
            return false
        }
        guard !isSaving else { return false }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await repository.updateAlias(relationshipId: friend.relationshipId, alias: normalized)
            alias = normalized
            savedAlias = normalized
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "备注保存失败"
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func nonBlank(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}
