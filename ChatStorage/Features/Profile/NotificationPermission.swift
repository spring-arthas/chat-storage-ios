import Foundation
import Observation
import UserNotifications

enum MessageNotificationUserInfo {
    static let friendIdKey = "friendId"
}

enum NotificationPermissionStatus: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var title: String {
        switch self {
        case .notDetermined: "未申请"
        case .denied: "已关闭"
        case .authorized: "已允许"
        case .provisional: "临时允许"
        case .ephemeral: "临时会话"
        }
    }
}

protocol NotificationPermissionProviding: Sendable {
    func status() async -> NotificationPermissionStatus
    func requestAuthorization() async throws -> NotificationPermissionStatus
}

final class SystemNotificationPermissionProvider: NotificationPermissionProviding, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func status() async -> NotificationPermissionStatus {
        let settings = await center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    func requestAuthorization() async throws -> NotificationPermissionStatus {
        _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        return await status()
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .notDetermined
        }
    }
}

struct MessageNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let friendId: Int64
}

protocol MessageNotificationDelivering: Sendable {
    func deliver(_ request: MessageNotificationRequest) async throws
}

final class SystemMessageNotificationCenter: MessageNotificationDelivering, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func deliver(_ request: MessageNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = [MessageNotificationUserInfo.friendIdKey: request.friendId]
        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: nil
        ))
    }
}

@MainActor
@Observable
final class MessageNotificationRouteStore {
    private(set) var pendingFriendId: Int64?

    func open(friendId: Int64) {
        guard friendId > 0 else { return }
        pendingFriendId = friendId
    }

    // [修改] 好友列表尚未加载到目标好友时保留路由，下一次刷新后继续消费。
    func consume(friendId: Int64) -> Int64? {
        guard pendingFriendId == friendId else { return nil }
        pendingFriendId = nil
        return friendId
    }

    func reset() {
        pendingFriendId = nil
    }
}

@MainActor
final class MessageNotificationCoordinator {
    private let center: any MessageNotificationDelivering
    private let routeStore: MessageNotificationRouteStore
    private let previewEnabled: @MainActor @Sendable () -> Bool

    init(
        center: any MessageNotificationDelivering,
        routeStore: MessageNotificationRouteStore,
        previewEnabled: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.center = center
        self.routeStore = routeStore
        self.previewEnabled = previewEnabled
    }

    func handle(
        _ event: ChatEvent,
        currentUserId: Int64,
        currentFriendId: Int64?,
        isMessagesTabActive: Bool = true,
        isSceneActive: Bool = true,
        friendName: String
    ) async {
        guard case .message(let message) = event,
              message.senderId != currentUserId,
              message.senderId > 0 else { return }
        // [修改] 只有消息 Tab 正在前台展示目标会话时免通知；保留的导航栈不能冒充可见页面。
        let isConversationVisible = isMessagesTabActive
            && isSceneActive
            && currentFriendId == message.senderId
        guard !isConversationVisible else { return }
        let body = previewEnabled() ? message.conversationSummary : "你收到一条新消息"
        let identifier = message.messageId > 0
            ? "chat-message-\(message.messageId)" : "chat-message-\(message.id)"
        try? await center.deliver(MessageNotificationRequest(
            identifier: identifier,
            title: friendName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新消息" : friendName,
            body: body,
            friendId: message.senderId
        ))
    }
}

// [修改] 长期 Socket 监听共享同一份页面可见性，避免 SwiftUI 重建后任务继续读取旧 Tab/前台状态。
@MainActor
final class MessageNotificationVisibilityState {
    var isMessagesTabActive = true
    var isSceneActive = true
}
