import Foundation
import Network

enum ControlTransportState: Equatable, Sendable {
    case connecting
    case ready
    case failed(String)
    case cancelled
}

protocol ControlTransport: AnyObject, Sendable {
    var state: ControlTransportState { get }
    func setStateUpdateHandler(_ handler: (@Sendable (ControlTransportState) -> Void)?)
    func start(on queue: DispatchQueue)
    func send(_ data: Data, completion: @escaping @Sendable (String?) -> Void)
    func receive(
        maximumLength: Int,
        completion: @escaping @Sendable (Data?, Bool, String?) -> Void
    )
    func cancel()
}

private final class NWControlTransport: ControlTransport, @unchecked Sendable {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: TransportSecurity.makePlainTCPParameters()
        )
    }

    var state: ControlTransportState {
        Self.map(connection.state)
    }

    func setStateUpdateHandler(_ handler: (@Sendable (ControlTransportState) -> Void)?) {
        connection.stateUpdateHandler = { state in
            handler?(Self.map(state))
        }
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping @Sendable (String?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error?.localizedDescription)
        })
    }

    func receive(
        maximumLength: Int,
        completion: @escaping @Sendable (Data?, Bool, String?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
            data,
            _,
            isComplete,
            error in
            completion(data, isComplete, error?.localizedDescription)
        }
    }

    func cancel() {
        connection.cancel()
    }

    private static func map(_ state: NWConnection.State) -> ControlTransportState {
        switch state {
        case .ready:
            return .ready
        case .failed(let error):
            return .failed(error.localizedDescription)
        case .cancelled:
            return .cancelled
        default:
            return .connecting
        }
    }
}

actor NWControlConnection: ControlConnection {
    nonisolated let frames: AsyncThrowingStream<Frame, Error>

    private let configuration: ServerConfiguration
    private let transportFactory: @Sendable (String, UInt16) -> any ControlTransport
    private let queue = DispatchQueue(label: "com.alibaba.chatstorage.control-connection")
    private let frameContinuation: AsyncThrowingStream<Frame, Error>.Continuation
    private var connection: (any ControlTransport)?
    private var connectionGeneration = 0
    private var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var decoder = FrameStreamDecoder()
    private var sending = false
    private struct SendWaiter {
        let identifier: UUID
        let generation: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct ActiveSend {
        let identifier: UUID
        let generation: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private var sendWaiters: [SendWaiter] = []
    private var activeSend: ActiveSend?
    private var isClosed = false

    init(
        configuration: ServerConfiguration,
        transportFactory: @escaping @Sendable (String, UInt16) -> any ControlTransport = {
            NWControlTransport(host: $0, port: $1)
        }
    ) {
        self.configuration = configuration
        self.transportFactory = transportFactory
        var captured: AsyncThrowingStream<Frame, Error>.Continuation!
        self.frames = AsyncThrowingStream { captured = $0 }
        self.frameContinuation = captured
    }

    func connect() async throws {
        guard !isClosed else { throw ConnectionError.disconnected }
        if connection?.state == .ready { return }
        if let active = connection {
            switch active.state {
            case .connecting:
                // [修改] 复用已有连接时同样受超时保护，避免二次并发登录时无限等待。
                return try await awaitConnection(active, timeout: .seconds(10))
            case .failed(let message):
                discard(active, connectError: ConnectionError.failed(message), cancel: true)
            case .cancelled:
                discard(active, connectError: ConnectionError.disconnected, cancel: false)
            case .ready:
                return
            }
        }
        guard let port = UInt16(exactly: configuration.controlPort) else {
            throw ConnectionError.invalidPort(configuration.controlPort)
        }

        // 控制端口 10086 与服务端约定使用普通 TCP，不发送 TLS ClientHello。
        let candidate = transportFactory(configuration.host, port)
        connectionGeneration += 1
        connection = candidate
        candidate.setStateUpdateHandler { [weak self, weak candidate] state in
            guard let candidate else { return }
            Task { await self?.handle(state: state, for: candidate) }
        }
        candidate.start(on: queue)

        // [修改] 连接阶段也必须有超时，否则服务端不可达时会无限转圈。
        try await awaitConnection(candidate, timeout: .seconds(10))
    }

    // 心跳失败时不能相信旧 transport 的 ready 状态，保留 frames 订阅并强制重建 TCP。
    func reconnect() async throws {
        guard !isClosed else { throw ConnectionError.disconnected }
        if let active = connection {
            discard(active, connectError: ConnectionError.disconnected, cancel: true)
        }
        try Task.checkCancellation()
        try await connect()
    }

    func send(_ frame: Frame) async throws {
        let generation = connectionGeneration
        try await acquireSendSlot(generation: generation)
        defer { releaseSendSlot() }
        try Task.checkCancellation()
        // [修改] 排队期间发生 reconnect 后，旧帧不能读取并写入新 transport。
        guard generation == connectionGeneration,
              let connection,
              connection.state == .ready else {
            throw ConnectionError.notConnected
        }
        let data = try FrameCodec.encode(frame)
        try await send(data, on: connection, generation: generation)
    }

    func disconnect() async {
        guard !isClosed else { return }
        isClosed = true
        let active = connection
        let invalidatedGeneration = connectionGeneration
        connection = nil
        connectionGeneration += 1
        resumeConnectContinuations(throwing: ConnectionError.disconnected)
        failSendOperations(
            for: invalidatedGeneration,
            throwing: ConnectionError.disconnected
        )
        active?.setStateUpdateHandler(nil)
        active?.cancel()
        decoder = FrameStreamDecoder()
        // [修改] 只有用户显式关闭客户端时才结束长期监听流；临时断线保留同一订阅供重连复用。
        frameContinuation.finish()
    }

    private func handle(state: ControlTransportState, for candidate: any ControlTransport) {
        guard isActive(candidate) else { return }
        switch state {
        case .ready:
            resumeConnectContinuations()
            receiveNext(on: candidate)
        case .failed(let message):
            discard(candidate, connectError: ConnectionError.failed(message), cancel: false)
        case .cancelled:
            discard(candidate, connectError: ConnectionError.disconnected, cancel: false)
        case .connecting:
            break
        }
    }

    private func receiveNext(on candidate: any ControlTransport) {
        candidate.receive(maximumLength: 64 * 1024) { [weak self, weak candidate] data, isComplete, errorMessage in
            guard let candidate else { return }
            Task {
                await self?.handleReceive(
                    data: data,
                    isComplete: isComplete,
                    errorMessage: errorMessage,
                    from: candidate
                )
            }
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        errorMessage: String?,
        from candidate: any ControlTransport
    ) {
        guard isActive(candidate) else { return }
        if let data, !data.isEmpty {
            do {
                for frame in try decoder.append(data) {
                    frameContinuation.yield(frame)
                }
            } catch {
                discard(candidate, connectError: error, cancel: true)
                return
            }
        }
        if let errorMessage {
            discard(candidate, connectError: ConnectionError.failed(errorMessage), cancel: true)
        } else if isComplete {
            discard(candidate, connectError: ConnectionError.disconnected, cancel: true)
        } else {
            receiveNext(on: candidate)
        }
    }

    private func awaitConnection(_ candidate: any ControlTransport, timeout: Duration) async throws {
        do {
            try await waitForConnection(candidate, timeout: timeout)
        } catch is CancellationError {
            // [修改] 单个调用方取消时只移除自己的 waiter，不能关闭其他调用方共享的连接。
            throw CancellationError()
        } catch {
            // [修改] 只清理本次等待的 candidate；旧任务不能误关随后建立的新连接。
            if isActive(candidate) {
                discard(candidate, connectError: error, cancel: true)
            }
            throw error
        }
    }

    private func waitForConnection(_ candidate: any ControlTransport, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForConnectionSignal(for: candidate)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectionError.connectionTimeout
            }
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }

    private func waitForConnectionSignal(for candidate: any ControlTransport) async throws {
        guard isActive(candidate) else { throw ConnectionError.disconnected }
        switch candidate.state {
        case .ready:
            return
        case .failed(let message):
            throw ConnectionError.failed(message)
        case .cancelled:
            throw ConnectionError.disconnected
        case .connecting:
            break
        }

        let identifier = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                connectContinuations[identifier] = continuation
            }
        } onCancel: {
            // [修改] 任务组超时后必须唤醒对应 continuation，否则任务组会永久等待子任务退出。
            Task { await self.cancelConnectContinuation(identifier) }
        }
    }

    private func cancelConnectContinuation(_ identifier: UUID) {
        guard let continuation = connectContinuations.removeValue(forKey: identifier) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func discard(
        _ candidate: any ControlTransport,
        connectError: Error,
        cancel: Bool
    ) {
        guard isActive(candidate) else { return }
        let invalidatedGeneration = connectionGeneration
        candidate.setStateUpdateHandler(nil)
        connection = nil
        connectionGeneration += 1
        decoder = FrameStreamDecoder()
        resumeConnectContinuations(throwing: connectError)
        // transport 失效时同步结束在途和排队 send，旧帧不能跨 TCP 连接代次继续执行。
        failSendOperations(for: invalidatedGeneration, throwing: connectError)
        if cancel { candidate.cancel() }
    }

    private func resumeConnectContinuations(throwing error: Error? = nil) {
        let continuations = Array(connectContinuations.values)
        connectContinuations.removeAll()
        for continuation in continuations {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func isActive(_ candidate: any ControlTransport) -> Bool {
        guard let connection else { return false }
        return ObjectIdentifier(connection) == ObjectIdentifier(candidate)
    }

    private func acquireSendSlot(generation: Int) async throws {
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw ConnectionError.disconnected }
        if !sending {
            sending = true
            return
        }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sendWaiters.append(
                    SendWaiter(
                        identifier: identifier,
                        generation: generation,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            // [修改] 串行发送队列中的任务取消后立即出队，不能在前一个 send 完成后继续写 Socket。
            Task { await self.cancelSendWaiter(identifier) }
        }
    }

    private func cancelSendWaiter(_ identifier: UUID) {
        guard let index = sendWaiters.firstIndex(where: { $0.identifier == identifier }) else { return }
        let waiter = sendWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseSendSlot() {
        while !sendWaiters.isEmpty {
            let waiter = sendWaiters.removeFirst()
            if waiter.generation == connectionGeneration {
                waiter.continuation.resume()
                return
            }
            waiter.continuation.resume(throwing: ConnectionError.disconnected)
        }
        sending = false
    }

    private func send(
        _ data: Data,
        on candidate: any ControlTransport,
        generation: Int
    ) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard generation == connectionGeneration, isActive(candidate) else {
                    continuation.resume(throwing: ConnectionError.disconnected)
                    return
                }
                activeSend = ActiveSend(
                    identifier: identifier,
                    generation: generation,
                    continuation: continuation
                )
                candidate.send(data) { [weak self] errorMessage in
                    Task {
                        await self?.completeSend(
                            identifier: identifier,
                            generation: generation,
                            errorMessage: errorMessage
                        )
                    }
                }
            }
        } onCancel: {
            // [修改] NWConnection 不能单独取消 contentProcessed；取消在途帧时销毁当前 transport。
            Task { await self.cancelActiveSend(identifier: identifier, generation: generation) }
        }
    }

    private func completeSend(
        identifier: UUID,
        generation: Int,
        errorMessage: String?
    ) {
        guard let send = activeSend,
              send.identifier == identifier,
              send.generation == generation else { return }
        activeSend = nil
        if let errorMessage {
            send.continuation.resume(throwing: ConnectionError.failed(errorMessage))
        } else {
            send.continuation.resume()
        }
    }

    private func cancelActiveSend(identifier: UUID, generation: Int) {
        guard let send = activeSend,
              send.identifier == identifier,
              send.generation == generation else { return }
        activeSend = nil
        if generation == connectionGeneration, let candidate = connection {
            discard(
                candidate,
                connectError: ConnectionError.disconnected,
                cancel: true
            )
        }
        send.continuation.resume(throwing: CancellationError())
    }

    private func failSendOperations(for generation: Int, throwing error: Error) {
        if let send = activeSend, send.generation == generation {
            activeSend = nil
            send.continuation.resume(throwing: error)
        }

        var remaining: [SendWaiter] = []
        var failed: [SendWaiter] = []
        for waiter in sendWaiters {
            if waiter.generation == generation {
                failed.append(waiter)
            } else {
                remaining.append(waiter)
            }
        }
        sendWaiters = remaining
        failed.forEach { $0.continuation.resume(throwing: error) }
    }
}
