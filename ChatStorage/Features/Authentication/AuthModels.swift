import Foundation

struct LoginRequest: Codable, Equatable, Sendable {
    let username: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case username = "userName"
        case password
    }
}

// [修改] 与 macOS 和 net-server 的 0x30 注册 JSON 保持一致；头像字段为空时不编码。
struct RegisterRequest: Codable, Equatable, Sendable {
    let username: String
    let password: String
    let email: String
    let avatarData: String?
    let avatarName: String?

    enum CodingKeys: String, CodingKey {
        case username = "userName"
        case password
        case email = "mail"
        case avatarData
        case avatarName
    }
}

struct SessionResumeRequest: Codable, Equatable, Sendable {
    let sessionToken: String
}

// [修改] 控制连接心跳使用独立 nonce，响应必须原样回显后才算当前连接可用。
struct HeartbeatRequest: Codable, Equatable, Sendable {
    let nonce: String
}

struct HeartbeatResponseEnvelope: Decodable, Equatable, Sendable {
    let success: Bool
    let message: String
    let data: HeartbeatResponseData?
    let errorCode: String?
}

struct HeartbeatResponseData: Decodable, Equatable, Sendable {
    let nonce: String
    let serverTime: Int64?
}

struct LogoutRequest: Codable, Equatable, Sendable {}

// [修改] 头像更新帧 0x45 的请求体，avatarData 为 base64 图片内容。
struct UpdateAvatarRequest: Codable, Equatable, Sendable {
    let avatarData: String
    let avatarName: String
}

struct UserResponseEnvelope: Decodable, Equatable, Sendable {
    let success: Bool?
    let code: Int
    let message: String
    let data: AuthenticatedUser?
    let errorCode: String?

    var isSuccess: Bool { success ?? (code == 200) }

    enum CodingKeys: String, CodingKey {
        case success, code, message, msg, data, errorCode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        code = try values.decodeIfPresent(Int.self, forKey: .code) ?? (success == true ? 200 : 400)
        message = try values.decodeIfPresent(String.self, forKey: .message)
            ?? values.decodeIfPresent(String.self, forKey: .msg)
            ?? ""
        data = try values.decodeIfPresent(AuthenticatedUser.self, forKey: .data)
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

struct AuthenticatedUser: Codable, Equatable, Sendable {
    let id: Int64
    let username: String
    let nickname: String?
    let avatar: String?
    let email: String?
    let phone: String?
    let status: Int?
    let transferToken: String?
    let sessionToken: String?

    init(
        id: Int64,
        username: String,
        nickname: String?,
        avatar: String?,
        email: String?,
        phone: String?,
        status: Int?,
        transferToken: String?,
        sessionToken: String?
    ) {
        self.id = id
        self.username = username
        self.nickname = nickname
        self.avatar = avatar
        self.email = email
        self.phone = phone
        self.status = status
        self.transferToken = transferToken
        self.sessionToken = sessionToken
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: FlexibleKey.self)
        id = try values.decodeFirst(Int64.self, keys: ["userId", "id"]) ?? 0
        username = try values.decodeFirst(String.self, keys: ["userName", "username"]) ?? ""
        nickname = try values.decodeFirst(String.self, keys: ["nickName", "nickname"])
        avatar = try values.decodeFirst(String.self, keys: ["avatar"])
        email = try values.decodeFirst(String.self, keys: ["mail", "email"])
        phone = try values.decodeFirst(String.self, keys: ["phone"])
        status = try values.decodeFirst(Int.self, keys: ["status"])
        transferToken = try values.decodeFirst(String.self, keys: ["transferToken"])
        sessionToken = try values.decodeFirst(String.self, keys: ["sessionToken"])
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: FlexibleKey.self)
        try values.encode(id, forKey: FlexibleKey("userId"))
        try values.encode(username, forKey: FlexibleKey("userName"))
        try values.encodeIfPresent(nickname, forKey: FlexibleKey("nickName"))
        try values.encodeIfPresent(avatar, forKey: FlexibleKey("avatar"))
        try values.encodeIfPresent(email, forKey: FlexibleKey("mail"))
        try values.encodeIfPresent(phone, forKey: FlexibleKey("phone"))
        try values.encodeIfPresent(status, forKey: FlexibleKey("status"))
        try values.encodeIfPresent(transferToken, forKey: FlexibleKey("transferToken"))
        try values.encodeIfPresent(sessionToken, forKey: FlexibleKey("sessionToken"))
    }
}

// [修改] 仅从服务端 transferToken 中读取毫秒过期时间用于本地提前刷新；身份和签名仍全部由服务端校验。
enum TransferTokenExpiration {
    static func expirationDate(from token: String?) -> Date? {
        guard let token else { return nil }
        let parts = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5,
              let expiresAtMilliseconds = Int64(parts[2]),
              expiresAtMilliseconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1_000)
    }
}

private struct FlexibleKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == FlexibleKey {
    func decodeFirst<T: Decodable>(_ type: T.Type, keys: [String]) throws -> T? {
        for name in keys {
            let key = FlexibleKey(name)
            if contains(key), let value = try decodeIfPresent(type, forKey: key) {
                return value
            }
        }
        return nil
    }
}
