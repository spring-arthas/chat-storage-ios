import Foundation

struct FrameStreamDecoder: Sendable {
    private var buffer = Data()

    mutating func append<Bytes: DataProtocol>(_ incoming: Bytes) throws -> [Frame] {
        buffer.append(Data(incoming))
        var frames: [Frame] = []

        while true {
            resynchronizeToMagic()
            guard buffer.count >= FrameCodec.headerSize else {
                return frames
            }

            let payloadLength: Int
            do {
                payloadLength = try FrameCodec.readPayloadLength(from: buffer)
            } catch {
                buffer.removeFirst()
                throw error
            }

            let totalLength = FrameCodec.headerSize + payloadLength
            guard buffer.count >= totalLength else {
                return frames
            }

            let frameBytes = Data(buffer.prefix(totalLength))
            do {
                frames.append(try FrameCodec.decode(frameBytes))
                buffer.removeFirst(totalLength)
            } catch {
                buffer.removeFirst()
                throw error
            }
        }
    }

    private mutating func resynchronizeToMagic() {
        guard !FrameCodec.hasMagicPrefix(buffer) else { return }

        if let magicIndex = buffer.indices.dropLast().first(where: { index in
            buffer[index] == 0xFA && buffer[buffer.index(after: index)] == 0xCE
        }) {
            buffer.removeSubrange(buffer.startIndex..<magicIndex)
        } else if buffer.last == 0xFA {
            buffer = Data([0xFA])
        } else {
            buffer.removeAll(keepingCapacity: true)
        }
    }
}
