import XCTest
@testable import ChatStorage

final class SmokeTests: XCTestCase {
    func testApplicationModuleLoads() {
        XCTAssertEqual(AppIdentity.displayName, "Chat Storage")
    }
}
