import Foundation
import Observation

@MainActor
@Observable
final class FriendManagementViewModel {
    private(set) var results: [ChatUserSearchResult] = []
    private(set) var pendingRequests: [FriendRequestItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private let repository: any ChatRepository

    init(repository: any ChatRepository) { self.repository = repository }

    func search(keyword: String) async {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { results = []; return }
        await perform { results = try await repository.searchUsers(keyword: value) }
    }

    func add(_ result: ChatUserSearchResult, message: String = "你好，我想加你为好友") async {
        await perform {
            try await repository.addFriend(userId: result.id, message: message)
            guard let index = results.firstIndex(where: { $0.id == result.id }) else { return }
            let current = results[index]
            results[index] = ChatUserSearchResult(
                id: current.id, username: current.username, nickname: current.nickname, avatar: current.avatar,
                status: current.status, friendStatus: 0, friendStatusDescription: "等待对方同意", incomingRequestId: current.incomingRequestId
            )
        }
    }

    func loadRequests() async {
        await perform { pendingRequests = try await repository.pendingRequests() }
    }

    func handle(_ request: FriendRequestItem, accept: Bool, alias: String? = nil) async {
        await perform {
            try await repository.handleFriendRequest(requestId: request.id, accept: accept, alias: alias)
            pendingRequests.removeAll { $0.id == request.id }
        }
    }

    func clearError() { errorMessage = nil }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil; defer { isLoading = false }
        do { try await operation() }
        catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? "好友操作失败" }
    }
}
