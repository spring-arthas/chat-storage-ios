import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
    func testUnauthenticatedLaunchShowsLoginControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "unauthenticated"]
        app.launch()

        XCTAssertTrue(app.staticTexts["你的消息与文件，只属于你"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["账号"].exists)
        XCTAssertTrue(app.secureTextFields["密码"].exists)
        XCTAssertTrue(app.staticTexts["服务器状态"].exists)
        XCTAssertTrue(app.buttons["登录"].exists)
        XCTAssertTrue(app.buttons["使用 Face ID"].exists)
    }

    func testAuthenticatedLaunchCanSelectEveryTab() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        for title in ["消息", "网盘", "我的"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            tab.tap()
            XCTAssertTrue(tab.isSelected)
        }
    }

    func testChatOpensFriendDetailsAndPinMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let conversation = app.buttons["conversation.2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        conversation.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.conversation.screen"].waitForExistence(timeout: 3))

        app.buttons["chat.friend.avatar"].tap()
        XCTAssertTrue(app.staticTexts["好友资料"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["@xiaolin"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["chat.more"].tap()
        XCTAssertTrue(app.buttons["置顶聊天"].waitForExistence(timeout: 2))
        app.buttons["置顶聊天"].tap()
        app.buttons["chat.more"].tap()
        XCTAssertTrue(app.buttons["取消置顶"].waitForExistence(timeout: 2))
    }

    func testFriendListUsesPullRefreshWithoutRefreshButton() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        XCTAssertFalse(app.buttons["刷新"].exists)
        let list = app.collectionViews["friends.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        list.swipeDown()
        XCTAssertTrue(list.exists)
    }

    func testChatSupportsNativeLeftEdgeBackGesture() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let conversation = app.buttons["conversation.2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        conversation.tap()
        XCTAssertTrue(app.buttons["chat.friend.avatar"].waitForExistence(timeout: 3))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["chat.friend.avatar"].exists)
    }
}
