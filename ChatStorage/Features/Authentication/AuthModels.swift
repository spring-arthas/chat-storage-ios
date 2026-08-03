import Foundation

struct LoginRequest: Codable, Equatable, Sendable {
    let username: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case username = "userName"
        case password
    }
}

struct SessionResumeRequest: Codable, Equatable, Sendable {
    let sessionToken: String
}

struct LogoutRequest: Codable, Equatable, Sendable {}

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
