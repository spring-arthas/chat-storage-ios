import Foundation
import Network

actor NWControlConnection: ControlConnection {
    nonisolated let frames: AsyncThrowingStream<Frame, Error>

    private let configuration: ServerConfiguration
    private let queue = DispatchQueue(label: "com.alibaba.chatstorage.control-connection")
    private let frameContinuation: AsyncThrowingStream<Frame, Error>.Continuation
    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var decoder = FrameStreamDecoder()
    private var sending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: ServerConfiguration) {
        self.configuration = configuration
        var captured: AsyncThrowingStream<Frame, Error>.Continuation!
        self.frames = AsyncThrowingStream { captured = $0 }
        self.frameContinuation = captured
    }

    func connect() async throws {
        if connection?.state == .ready { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.controlPort)) else {
            throw ConnectionError.invalidPort(configuration.controlPort)
        }

        let candidate = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: .tcp)
        connection = candidate
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let candidate else { return }
            Task { await self?.handle(state: state, for: candidate) }
        }
        candidate.start(queue: queue)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
        }
    }

    func send(_ frame: Frame) async throws {
        await acquireSendSlot()
        defer { releaseSendSlot() }
        guard let connection, connection.state == .ready else {
            throw ConnectionError.notConnected
        }
        let data = try FrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func disconnect() async {
        let active = connection
        connection = nil
        connectContinuation?.resume(throwing: ConnectionError.disconnected)
        connectContinuation = nil
        active?.stateUpdateHandler = nil
        active?.cancel()
    }

    private func handle(state: NWConnection.State, for candidate: NWConnection) {
        guard connection === candidate else { return }
        switch state {
        case .ready:
            connectContinuation?.resume()
            connectContinuation = nil
            receiveNext(on: candidate)
        case .failed(let error):
            connection = nil
            connectContinuation?.resume(throwing: ConnectionError.failed(error.localizedDescription))
            connectContinuation = nil
            frameContinuation.finish(throwing: ConnectionError.failed(error.localizedDescription))
        case .cancelled:
            connection = nil
            connectContinuation?.resume(throwing: ConnectionError.disconnected)
            connectContinuation = nil
        default:
            break
        }
    }

    private func receiveNext(on candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak candidate] data, _, isComplete, error in
            guard let candidate else { return }
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error, from: candidate) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?, from candidate: NWConnection) {
        guard connection === candidate else { return }
        if let data, !data.isEmpty {
            do {
                for frame in try decoder.append(data) {
                    frameContinuation.yield(frame)
                }
            } catch {
                frameContinuation.finish(throwing: error)
                candidate.cancel()
                connection = nil
                return
            }
        }
        if let error {
            frameContinuation.finish(throwing: ConnectionError.failed(error.localizedDescription))
            candidate.cancel()
            connection = nil
        } else if isComplete {
            frameContinuation.finish(throwing: ConnectionError.disconnected)
            candidate.cancel()
            connection = nil
        } else {
            receiveNext(on: candidate)
        }
    }

    private func acquireSendSlot() async {
        if !sending {
            sending = true
            return
        }
        await withCheckedContinuation { sendWaiters.append($0) }
    }

    private func releaseSendSlot() {
        if sendWaiters.isEmpty {
            sending = false
        } else {
            sendWaiters.removeFirst().resume()
        }
    }
}
