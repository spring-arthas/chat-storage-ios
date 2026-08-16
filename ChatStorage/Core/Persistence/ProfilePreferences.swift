import Foundation
import Observation

enum AppAppearance: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

struct ProfilePreferences: Codable, Equatable, Sendable {
    var notificationPreviewEnabled: Bool
    var appLockEnabled: Bool
    var appearance: AppAppearance
    var wifiOnlyTransfers: Bool

    init(
        notificationPreviewEnabled: Bool = true,
        appLockEnabled: Bool = false,
        appearance: AppAppearance = .system,
        wifiOnlyTransfers: Bool = false
    ) {
        self.notificationPreviewEnabled = notificationPreviewEnabled
        self.appLockEnabled = appLockEnabled
        self.appearance = appearance
        self.wifiOnlyTransfers = wifiOnlyTransfers
    }

    private enum CodingKeys: String, CodingKey {
        case notificationPreviewEnabled
        case appLockEnabled
        case appearance
        case wifiOnlyTransfers
    }

    // [修改] 旧版本 JSON 缺少新字段时继续恢复原偏好，Wi-Fi 限制默认关闭。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notificationPreviewEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationPreviewEnabled) ?? true
        appLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .appLockEnabled) ?? false
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        wifiOnlyTransfers = try container.decodeIfPresent(Bool.self, forKey: .wifiOnlyTransfers) ?? false
    }

    static let `default` = ProfilePreferences()
}

protocol ProfilePreferencesStoring: Sendable {
    func load() -> ProfilePreferences
    func save(_ preferences: ProfilePreferences)
}

final class UserDefaultsProfilePreferencesStore: ProfilePreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "chat-storage.profile-preferences") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ProfilePreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? ProtocolJSON.decoder().decode(ProfilePreferences.self, from: data) else {
            return .default
        }
        return preferences
    }

    func save(_ preferences: ProfilePreferences) {
        guard let data = try? ProtocolJSON.encoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
@Observable
final class ProfilePreferencesController {
    private(set) var preferences: ProfilePreferences
    private let store: any ProfilePreferencesStoring

    init(store: any ProfilePreferencesStoring) {
        self.store = store
        preferences = store.load()
    }

    var notificationPreviewEnabled: Bool { preferences.notificationPreviewEnabled }
    var appLockEnabled: Bool { preferences.appLockEnabled }
    var appearance: AppAppearance { preferences.appearance }
    var wifiOnlyTransfers: Bool { preferences.wifiOnlyTransfers }

    // [修改] 设置项每次变更立即落盘，应用重启后保持一致。
    func setNotificationPreviewEnabled(_ enabled: Bool) {
        preferences.notificationPreviewEnabled = enabled
        persist()
    }

    func setAppLockEnabled(_ enabled: Bool) {
        preferences.appLockEnabled = enabled
        persist()
    }

    func setAppearance(_ appearance: AppAppearance) {
        preferences.appearance = appearance
        persist()
    }

    func setWifiOnlyTransfers(_ enabled: Bool) {
        preferences.wifiOnlyTransfers = enabled
        persist()
    }

    private func persist() {
        store.save(preferences)
    }
}
