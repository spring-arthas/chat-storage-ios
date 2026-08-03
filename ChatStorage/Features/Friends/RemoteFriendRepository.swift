import Foundation

actor RemoteFriendRepository: FriendRepository {
    private let client: any FrameRequesting
    private let timeout: Duration

    init(client: any FrameRequesting, timeout: Duration = .seconds(15)) {
        self.client = client
        self.timeout = timeout
    }

    func refresh() async throws -> [ChatFriend] {
        let frame = try await client.request(
            Frame(type: .friendListRequest),
            expecting: [.friendListResponse],
            timeout: timeout
        )
        let envelope: FriendListEnvelope = try decode(frame.payload)
        guard envelope.isSuccess else {
            throw FriendRepositoryError.server(message: envelope.message, code: envelope.errorCode)
        }
        guard let friends = envelope.data else { throw FriendRepositoryError.missingData }
        return friends
    }

    func updatePin(relationshipId: Int64, pinned: Bool) async throws -> FriendPinState {
        let request = FriendPinUpdateRequest(relationshipId: relationshipId, pinned: pinned)
        let frame = try await client.request(
            Frame(type: .friendPinUpdateRequest, payload: try ProtocolJSON.encoder().encode(request)),
            expecting: [.friendPinUpdateResponse],
            timeout: timeout
        )
        let envelope: FriendPinEnvelope = try decode(frame.payload)
        guard envelope.isSuccess else {
            throw FriendRepositoryError.server(message: envelope.message, code: envelope.errorCode)
        }
        guard let state = envelope.data else { throw FriendRepositoryError.missingData }
        return state
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try ProtocolJSON.decoder().decode(T.self, from: data)
        } catch {
            throw FriendRepositoryError.invalidResponse
        }
    }
}
