import Foundation

protocol ControlConnection: Sendable {
    var frames: AsyncThrowingStream<Frame, Error> { get }
    func connect() async throws
    func reconnect() async throws
    func send(_ frame: Frame) async throws
    func disconnect() async
}

extension ControlConnection {
    // [修改] 简单测试替身沿用 connect；真实 NW 连接覆盖为强制替换 transport。
    func reconnect() async throws {
        try await connect()
    }
}

enum ConnectionError: Error, Equatable, Sendable, LocalizedError {
    case invalidPort(Int)
    case failed(String)
    case disconnected
    case notConnected
    case connectionTimeout

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "端口无效：\(port)"
        case .failed(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "连接服务器失败" : detail
        case .disconnected:
            return "连接已断开"
        case .notConnected:
            return "尚未连接服务器"
        case .connectionTimeout:
            return "连接服务器超时"
        }
    }
}
