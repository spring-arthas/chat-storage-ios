import XCTest
@testable import ChatStorage

final class FrameCodecTests: XCTestCase {
    func testEncodeUsesFaceMagicAndBigEndianLength() throws {
        let frame = Frame(type: .userLoginRequest, flags: 0x01, payload: Data([0x41, 0x42]))

        XCTAssertEqual(
            try FrameCodec.encode(frame),
            Data([0xFA, 0xCE, 0x31, 0x01, 0, 0, 0, 2, 0x41, 0x42])
        )
    }

    func testDecodeRoundTripsFrame() throws {
        let expected = Frame(type: .friendPinUpdateRequest, flags: 0x02, payload: Data("{\"pinned\":true}".utf8))

        XCTAssertEqual(try FrameCodec.decode(FrameCodec.encode(expected)), expected)
    }

    func testDecodeRejectsInvalidMagic() {
        XCTAssertThrowsError(try FrameCodec.decode(Data([0, 0, 0x31, 0, 0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? ProtocolError, .invalidMagic)
        }
    }

    func testDecodeRejectsUnknownFrameType() {
        XCTAssertThrowsError(try FrameCodec.decode(Data([0xFA, 0xCE, 0xFF, 0, 0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownFrameType(0xFF))
        }
    }

    func testDecodeRejectsPayloadOverOneHundredMiB() {
        let header = Data([0xFA, 0xCE, 0x31, 0, 0x06, 0x40, 0x00, 0x01])

        XCTAssertThrowsError(try FrameCodec.decode(header)) { error in
            XCTAssertEqual(error as? ProtocolError, .invalidPayloadLength(104_857_601))
        }
    }

    func testDecodeRejectsIncompleteBody() {
        let bytes = Data([0xFA, 0xCE, 0x31, 0, 0, 0, 0, 2, 0x41])

        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .incompleteBody(expected: 10, actual: 9))
        }
    }

    func testDecodeRejectsTrailingBytes() {
        let bytes = Data([0xFA, 0xCE, 0x31, 0, 0, 0, 0, 0, 0x01])

        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .trailingBytes(expected: 8, actual: 9))
        }
    }
}
