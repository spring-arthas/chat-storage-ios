import Foundation

protocol FriendRepository: Sendable {
    func refresh() async throws -> [ChatFriend]
    func updatePin(relationshipId: Int64, pinned: Bool) async throws -> FriendPinState
}

enum FriendRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case missingData
    case server(message: String, code: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务器返回了无法识别的好友数据"
        case .missingData: "服务器没有返回好友数据"
        case .server(let message, _): message.isEmpty ? "好友操作失败" : message
        }
    }
}
