import XCTest
@testable import ChatStorage

@MainActor
final class ProfilePreferencesControllerTests: XCTestCase {
    func testPreferencesPersistAcrossControllerRecreation() throws {
        let suiteName = "ProfilePreferencesControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsProfilePreferencesStore(defaults: defaults)
        let controller = ProfilePreferencesController(store: store)

        controller.setAppearance(.dark)
        controller.setNotificationPreviewEnabled(false)
        controller.setAppLockEnabled(true)
        controller.setWifiOnlyTransfers(true)

        let restored = ProfilePreferencesController(store: store)
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertFalse(restored.notificationPreviewEnabled)
        XCTAssertTrue(restored.appLockEnabled)
        XCTAssertTrue(restored.wifiOnlyTransfers)
    }

    // [修改] 老版本偏好 JSON 没有 Wi-Fi 字段时必须保留原设置，并把新开关默认成关闭。
    func testLegacyPreferencesWithoutWifiSettingRemainDecodable() throws {
        let suiteName = "ProfilePreferencesControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "legacy-profile-preferences"
        defaults.set(
            Data(#"{"notificationPreviewEnabled":false,"appLockEnabled":true,"appearance":"dark"}"#.utf8),
            forKey: key
        )

        let controller = ProfilePreferencesController(
            store: UserDefaultsProfilePreferencesStore(defaults: defaults, key: key)
        )

        XCTAssertFalse(controller.notificationPreviewEnabled)
        XCTAssertTrue(controller.appLockEnabled)
        XCTAssertEqual(controller.appearance, .dark)
        XCTAssertFalse(controller.wifiOnlyTransfers)
    }
}
