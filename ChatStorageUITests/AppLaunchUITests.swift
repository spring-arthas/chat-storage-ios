import XCTest

final class AppLaunchUITests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "unauthenticated"]
        app.launch()
        XCTAssertTrue(app.exists)
    }
}
