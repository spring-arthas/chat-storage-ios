import Foundation

struct Frame: Equatable, Sendable {
    let type: FrameType
    let flags: UInt8
    let payload: Data
}

enum ProtocolError: Error, Equatable, Sendable {
    case incompleteHeader
    case invalidMagic
    case unknownFrameType(UInt8)
    case invalidPayloadLength(Int)
    case incompleteBody(expected: Int, actual: Int)
    case trailingBytes(expected: Int, actual: Int)
}
