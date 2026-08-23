import XCTest
import UIKit
@testable import ChatStorage

final class SmokeTests: XCTestCase {
    func testApplicationModuleLoads() {
        XCTAssertEqual(AppIdentity.displayName, "Chat Storage")
    }

    // [修改] 真机导航栏和目录树不能引用不存在的 SF Symbol，否则按钮会显示为空白。
    func testRequiredInterfaceSystemSymbolsExist() {
        let symbols = [
            AppSystemSymbols.chatSettings,
            AppSystemSymbols.directory,
            AppSystemSymbols.selectedDirectoryBadge
        ]

        for symbol in symbols {
            XCTAssertNotNil(UIImage(systemName: symbol), "无效的 SF Symbol: \(symbol)")
        }
    }

    func testInfoPlistAllowsConfiguredPrivateHTTPMediaGateway() throws {
        // [修改] 真机没有 Mac 源码目录，直接检查当前已安装 App 展开后的 Info.plist。
        let infoDictionary = try XCTUnwrap(Bundle.main.infoDictionary)
        let ats = try XCTUnwrap(infoDictionary["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    @MainActor
    func testNotificationRoutePersistsUntilConsumedByMessagesPage() {
        let routeStore = MessageNotificationRouteStore()

        routeStore.open(friendId: 17)

        XCTAssertEqual(routeStore.pendingFriendId, 17)
        XCTAssertEqual(routeStore.consume(friendId: 9), nil)
        XCTAssertEqual(routeStore.pendingFriendId, 17)
        XCTAssertEqual(routeStore.consume(friendId: 17), 17)
        XCTAssertNil(routeStore.pendingFriendId)
    }
}
