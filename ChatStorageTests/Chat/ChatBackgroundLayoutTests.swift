import XCTest
@testable import ChatStorage

final class ChatBackgroundLayoutTests: XCTestCase {
    func testSelectedBackgroundUsesAspectFillAcrossSafeAreas() {
        XCTAssertEqual(ChatBackgroundLayout.contentMode, .fill)
        XCTAssertTrue(ChatBackgroundLayout.coversSafeAreas)
        XCTAssertTrue(ChatBackgroundLayout.clipsOverflow)
    }
}
