import Foundation

protocol DynamicRepository: Sendable {
    func create(_ request: DynamicCreateRequest) async throws -> DynamicCreateResult
    func timeline(scope: DynamicTimelineScope, beforeId: Int64?, limit: Int) async throws -> DynamicTimelinePage
    func action(dynamicId: Int64, action: DynamicAction) async throws -> DynamicActionResult
    func detail(dynamicId: Int64, beforeReplyId: Int64?, limit: Int) async throws -> DynamicPostDetail
    func delete(dynamicId: Int64) async throws
}

enum DynamicRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case server(message: String, code: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(let message, _):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "动态操作失败" : normalized
        case .invalidResponse:
            return "动态操作失败"
        }
    }
}

actor RemoteDynamicRepository: DynamicRepository {
    private let client: any FrameRequesting
    private let timeout: Duration

    init(client: any FrameRequesting, timeout: Duration = .seconds(15)) {
        self.client = client
        self.timeout = timeout
    }

    func create(_ request: DynamicCreateRequest) async throws -> DynamicCreateResult {
        try await requestData(
            frame: Frame(type: .dynamicCreateRequest, payload: try encode(request)),
            expecting: .dynamicCreateResponse,
            as: DynamicCreateResult.self
        )
    }

    func timeline(scope: DynamicTimelineScope, beforeId: Int64?, limit: Int) async throws -> DynamicTimelinePage {
        let request = DynamicTimelineRequest(scope: scope.rawValue, beforeId: beforeId, limit: limit)
        return try await requestData(
            frame: Frame(type: .dynamicTimelineRequest, payload: try encode(request)),
            expecting: .dynamicTimelineResponse,
            as: DynamicTimelinePage.self
        )
    }

    func action(dynamicId: Int64, action: DynamicAction) async throws -> DynamicActionResult {
        let request = DynamicActionRequest(dynamicId: dynamicId, action: action.wireValue, content: action.content)
        return try await requestData(
            frame: Frame(type: .dynamicActionRequest, payload: try encode(request)),
            expecting: .dynamicActionResponse,
            as: DynamicActionResult.self
        )
    }

    func detail(dynamicId: Int64, beforeReplyId: Int64?, limit: Int) async throws -> DynamicPostDetail {
        // [修改] 详情请求把回复游标和页大小原样交给服务端。
        let request = DynamicDetailRequest(dynamicId: dynamicId, beforeReplyId: beforeReplyId, limit: limit)
        return try await requestData(
            frame: Frame(type: .dynamicDetailRequest, payload: try encode(request)),
            expecting: .dynamicDetailResponse,
            as: DynamicPostDetail.self
        )
    }

    func delete(dynamicId: Int64) async throws {
        let response = try await client.request(
            Frame(type: .dynamicDeleteRequest, payload: try encode(DynamicIDRequest(dynamicId: dynamicId))),
            expecting: [.dynamicDeleteResponse],
            timeout: timeout
        )
        let envelope: DynamicEnvelope<DynamicEmptyData> = try decodeEnvelope(response.payload)
        try validate(envelope)
    }

    private func requestData<T: Decodable & Sendable>(
        frame: Frame,
        expecting responseType: FrameType,
        as type: T.Type
    ) async throws -> T {
        let response = try await client.request(frame, expecting: [responseType], timeout: timeout)
        let envelope: DynamicEnvelope<T> = try decodeEnvelope(response.payload)
        try validate(envelope)
        guard let data = envelope.data else { throw DynamicRepositoryError.invalidResponse }
        return data
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try ProtocolJSON.encoder().encode(value)
        } catch {
            throw DynamicRepositoryError.invalidResponse
        }
    }

    private func decodeEnvelope<T: Decodable & Sendable>(_ payload: Data) throws -> DynamicEnvelope<T> {
        do {
            return try ProtocolJSON.decoder().decode(DynamicEnvelope<T>.self, from: payload)
        } catch {
            throw DynamicRepositoryError.invalidResponse
        }
    }

    private func validate<T>(_ envelope: DynamicEnvelope<T>) throws {
        guard envelope.isSuccess else {
            throw DynamicRepositoryError.server(message: envelope.message, code: envelope.errorCode)
        }
    }
}

private struct DynamicTimelineRequest: Encodable, Sendable {
    let scope: String
    let beforeId: Int64?
    let limit: Int
}

private struct DynamicActionRequest: Encodable, Sendable {
    let dynamicId: Int64
    let action: String
    let content: String?
}

private struct DynamicDetailRequest: Encodable, Sendable {
    let dynamicId: Int64
    let beforeReplyId: Int64?
    let limit: Int
}

private struct DynamicIDRequest: Encodable, Sendable {
    let dynamicId: Int64
}

private struct DynamicEmptyData: Decodable, Sendable {}

private struct DynamicEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool?
    let code: Int
    let message: String
    let errorCode: String?
    let data: T?

    var isSuccess: Bool { success ?? (code == 200) }

    private enum CodingKeys: String, CodingKey {
        case success
        case code
        case message
        case msg
        case errorCode
        case data
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        code = try values.decodeIfPresent(Int.self, forKey: .code) ?? (success == true ? 200 : 400)
        message = try values.decodeIfPresent(String.self, forKey: .message)
            ?? values.decodeIfPresent(String.self, forKey: .msg)
            ?? ""
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
        data = try values.decodeIfPresent(T.self, forKey: .data)
    }
}
