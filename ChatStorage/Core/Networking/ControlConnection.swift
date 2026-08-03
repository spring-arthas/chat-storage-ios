import Foundation

protocol ControlConnection: Sendable {
    var frames: AsyncThrowingStream<Frame, Error> { get }
    func connect() async throws
    func send(_ frame: Frame) async throws
    func disconnect() async
}

enum ConnectionError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case failed(String)
    case disconnected
    case notConnected
}
