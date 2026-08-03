import XCTest

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
}
