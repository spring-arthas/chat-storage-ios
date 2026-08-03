import Foundation

enum FrameCodec {
    static let headerSize = 8
    static let maximumPayloadSize = 100 * 1024 * 1024

    private static let magicFirst: UInt8 = 0xFA
    private static let magicSecond: UInt8 = 0xCE

    static func encode(_ frame: Frame) throws -> Data {
        guard frame.payload.count <= maximumPayloadSize else {
            throw ProtocolError.invalidPayloadLength(frame.payload.count)
        }

        var result = Data(capacity: headerSize + frame.payload.count)
        result.append(contentsOf: [magicFirst, magicSecond, frame.type.rawValue, frame.flags])
        var payloadLength = UInt32(frame.payload.count).bigEndian
        withUnsafeBytes(of: &payloadLength) { result.append(contentsOf: $0) }
        result.append(frame.payload)
        return result
    }

    static func decode(_ bytes: Data) throws -> Frame {
        guard bytes.count >= headerSize else {
            throw ProtocolError.incompleteHeader
        }
        guard bytes[bytes.startIndex] == magicFirst,
              bytes[bytes.index(after: bytes.startIndex)] == magicSecond else {
            throw ProtocolError.invalidMagic
        }

        let typeCode = bytes[bytes.index(bytes.startIndex, offsetBy: 2)]
        guard let type = FrameType(rawValue: typeCode) else {
            throw ProtocolError.unknownFrameType(typeCode)
        }

        let payloadLength = try readPayloadLength(from: bytes)
        let expectedLength = headerSize + payloadLength
        guard bytes.count >= expectedLength else {
            throw ProtocolError.incompleteBody(expected: expectedLength, actual: bytes.count)
        }
        guard bytes.count == expectedLength else {
            throw ProtocolError.trailingBytes(expected: expectedLength, actual: bytes.count)
        }

        let flags = bytes[bytes.index(bytes.startIndex, offsetBy: 3)]
        let payloadStart = bytes.index(bytes.startIndex, offsetBy: headerSize)
        return Frame(type: type, flags: flags, payload: Data(bytes[payloadStart..<bytes.endIndex]))
    }

    static func readPayloadLength(from bytes: Data) throws -> Int {
        guard bytes.count >= headerSize else {
            throw ProtocolError.incompleteHeader
        }

        let start = bytes.index(bytes.startIndex, offsetBy: 4)
        let end = bytes.index(start, offsetBy: 4)
        let value = bytes[start..<end].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        let length = Int(value)
        guard length <= maximumPayloadSize else {
            throw ProtocolError.invalidPayloadLength(length)
        }
        return length
    }

    static func hasMagicPrefix(_ bytes: Data) -> Bool {
        bytes.count >= 2 && bytes[bytes.startIndex] == magicFirst && bytes[bytes.index(after: bytes.startIndex)] == magicSecond
    }
}
