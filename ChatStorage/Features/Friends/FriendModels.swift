import Foundation

struct ChatFriend: Codable, Equatable, Identifiable, Hashable, Sendable {
    let relationshipId: Int64
    let userId: Int64
    let friendId: Int64
    let alias: String?
    let username: String
    let nickname: String?
    let avatar: String?
    let unreadCount: Int
    let latestMessage: String?
    let isOnline: Bool
    let isPinned: Bool
    let pinnedAt: Int64?

    var id: Int64 { friendId }
    var displayName: String {
        [alias, nickname, username].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }.first ?? "好友"
    }

    init(
        relationshipId: Int64,
        userId: Int64,
        friendId: Int64,
        alias: String? = nil,
        username: String,
        nickname: String? = nil,
        avatar: String? = nil,
        unreadCount: Int = 0,
        latestMessage: String? = nil,
        isOnline: Bool = false,
        isPinned: Bool = false,
        pinnedAt: Int64? = nil
    ) {
        self.relationshipId = relationshipId
        self.userId = userId
        self.friendId = friendId
        self.alias = alias
        self.username = username
        self.nickname = nickname
        self.avatar = avatar
        self.unreadCount = unreadCount
        self.latestMessage = latestMessage
        self.isOnline = isOnline
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: FriendCodingKey.self)
        relationshipId = try values.first(Int64.self, ["id", "relationshipId"]) ?? 0
        userId = try values.first(Int64.self, ["userId"]) ?? 0
        friendId = try values.first(Int64.self, ["friendId"]) ?? 0
        alias = try values.first(String.self, ["alias"])
        username = try values.first(String.self, ["userName", "username"]) ?? ""
        nickname = try values.first(String.self, ["nickName", "nickname"])
        avatar = try values.first(String.self, ["avatar"])
        unreadCount = try values.first(Int.self, ["unreadCount", "unread_count", "unreadMsgCount", "unreadMessageCount"]) ?? 0
        latestMessage = try values.first(String.self, ["latestUnreadMsg", "latestMsg", "lastMsg", "latestMessage", "lastMessage"])
        // [修改] 同时兼容服务端字段和 Swift 本地 Codable 字段，避免缓存重载丢状态。
        let online = try values.bool(["online", "isOnline"])
        let onlineStatus = try values.first(String.self, ["onlineStatus"])
        isOnline = online ?? (onlineStatus?.uppercased() == "ONLINE")
        isPinned = try values.bool(["pinned", "isPinned"]) ?? false
        pinnedAt = try values.first(Int64.self, ["pinnedAt"])
    }
}

struct FriendPinState: Codable, Equatable, Sendable {
    let relationshipId: Int64
    let isPinned: Bool
    let pinnedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case relationshipId
        case isPinned = "pinned"
        case pinnedAt
    }
}

struct FriendPinUpdateRequest: Codable, Equatable, Sendable {
    let relationshipId: Int64
    let pinned: Bool
}

struct FriendListEnvelope: Decodable, Sendable {
    let success: Bool?
    let code: Int
    let message: String
    let data: [ChatFriend]?
    let errorCode: String?

    var isSuccess: Bool { success ?? (code == 200) }

    enum CodingKeys: String, CodingKey { case success, code, message, msg, data, errorCode }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        code = try values.decodeIfPresent(Int.self, forKey: .code) ?? (success == true ? 200 : 400)
        message = try values.decodeIfPresent(String.self, forKey: .message)
            ?? values.decodeIfPresent(String.self, forKey: .msg)
            ?? ""
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
        if let list = try? values.decodeIfPresent([ChatFriend].self, forKey: .data) {
            data = list
        } else if let item = try? values.decodeIfPresent(ChatFriend.self, forKey: .data) {
            data = [item]
        } else {
            data = nil
        }
    }
}

struct FriendPinEnvelope: Decodable, Sendable {
    let success: Bool?
    let code: Int
    let message: String
    let data: FriendPinState?
    let errorCode: String?

    var isSuccess: Bool { success ?? (code == 200) }

    enum CodingKeys: String, CodingKey { case success, code, message, msg, data, errorCode }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        code = try values.decodeIfPresent(Int.self, forKey: .code) ?? (success == true ? 200 : 400)
        message = try values.decodeIfPresent(String.self, forKey: .message)
            ?? values.decodeIfPresent(String.self, forKey: .msg)
            ?? ""
        data = try values.decodeIfPresent(FriendPinState.self, forKey: .data)
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

private struct FriendCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == FriendCodingKey {
    func first<T: Decodable>(_ type: T.Type, _ names: [String]) throws -> T? {
        for name in names {
            let key = FriendCodingKey(name)
            if contains(key), let value = try decodeIfPresent(type, forKey: key) { return value }
        }
        return nil
    }

    func bool(_ names: [String]) throws -> Bool? {
        if let value = try first(Bool.self, names) { return value }
        if let value = try first(Int.self, names) { return value != 0 }
        if let value = try first(String.self, names) {
            return ["true", "1", "yes", "y", "online"].contains(value.lowercased())
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
