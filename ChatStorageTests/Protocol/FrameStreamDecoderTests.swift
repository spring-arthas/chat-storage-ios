import XCTest
@testable import ChatStorage

final class FrameStreamDecoderTests: XCTestCase {
    func testDecoderWaitsForFragmentedFrame() throws {
        var decoder = FrameStreamDecoder()
        let bytes = try FrameCodec.encode(
            Frame(type: .userResponse, flags: 0, payload: Data("{}".utf8))
        )

        XCTAssertTrue(try decoder.append(bytes.prefix(5)).isEmpty)
        XCTAssertEqual(try decoder.append(bytes.dropFirst(5)).map(\.type), [.userResponse])
    }

    func testDecoderExtractsTwoCoalescedFrames() throws {
        var decoder = FrameStreamDecoder()
        let first = try FrameCodec.encode(Frame(type: .heartbeatResponse, flags: 0, payload: Data()))
        let second = try FrameCodec.encode(
            Frame(type: .friendEventPush, flags: 0, payload: Data("{}".utf8))
        )

        XCTAssertEqual(try decoder.append(first + second).map(\.type), [.heartbeatResponse, .friendEventPush])
    }

    func testDecoderSkipsGarbageBeforeMagic() throws {
        var decoder = FrameStreamDecoder()
        let valid = try FrameCodec.encode(Frame(type: .acknowledgement, flags: 0, payload: Data()))

        XCTAssertEqual(try decoder.append(Data([0, 1, 2]) + valid).map(\.type), [.acknowledgement])
    }

    func testDecoderKeepsTrailingMagicPrefix() throws {
        var decoder = FrameStreamDecoder()

        XCTAssertTrue(try decoder.append(Data([0x01, 0xFA])).isEmpty)
        let rest = Data([0xCE, FrameType.acknowledgement.rawValue, 0, 0, 0, 0, 0])
        XCTAssertEqual(try decoder.append(rest).map(\.type), [.acknowledgement])
    }
}
