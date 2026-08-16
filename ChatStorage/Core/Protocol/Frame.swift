import Foundation

struct Frame: Equatable, Sendable {
    static let transferLastFrameFlag: UInt8 = 0x01
    static let transferNeedsAcknowledgementFlag: UInt8 = 0x02
    static let transferHasOffsetFlag: UInt8 = 0x04

    let type: FrameType
    let flags: UInt8
    let payload: Data

    init(type: FrameType, flags: UInt8 = 0, payload: Data = Data()) {
        self.type = type
        self.flags = flags
        self.payload = payload
    }
}

enum ProtocolError: Error, Equatable, Sendable {
    case incompleteHeader
    case invalidMagic
    case unknownFrameType(UInt8)
    case invalidPayloadLength(Int)
    case incompleteBody(expected: Int, actual: Int)
    case trailingBytes(expected: Int, actual: Int)
}
