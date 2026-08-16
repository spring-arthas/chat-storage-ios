import Foundation

enum RequestResponseError: Error, Equatable, Sendable {
    case emptyExpectedTypes
    case timedOut
    case cancelled
    case closed
}

protocol FrameRequesting: Sendable {
    var pushes: AsyncStream<Frame> { get }
    func connect() async throws
    func reconnect() async throws
    func close() async

    func request(
        _ frame: Frame,
        expecting expectedTypes: Set<FrameType>,
        timeout: Duration
    ) async throws -> Frame
}

extension FrameRequesting {
    var pushes: AsyncStream<Frame> { AsyncStream { $0.finish() } }
    // [修改] 轻量测试替身默认复用 connect，生产客户端下沉到 ControlConnection 强制重建。
    func reconnect() async throws { try await connect() }
    func close() async {}
}

private final class FramePushBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Frame>.Continuation] = [:]
    private var isFinished = false

    func stream() -> AsyncStream<Frame> {
        let identifier = UUID()
        return AsyncStream { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
                return
            }
            continuations[identifier] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(identifier)
            }
        }
    }

    func yield(_ frame: Frame) {
        lock.lock()
        let active = Array(continuations.values)
        lock.unlock()
        active.forEach { $0.yield(frame) }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let active = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        active.forEach { $0.finish() }
    }

    private func remove(_ identifier: UUID) {
        lock.lock()
        continuations.removeValue(forKey: identifier)
        lock.unlock()
    }
}

actor RequestResponseClient: FrameRequesting {
    nonisolated var pushes: AsyncStream<Frame> { pushBroadcaster.stream() }

    private struct PendingRequest {
        let expectedTypes: Set<FrameType>
        let continuation: AsyncThrowingStream<Frame, Error>.Continuation
    }

    private let connection: any ControlConnection
    private let pushBroadcaster: FramePushBroadcaster
    private var pending: [UUID: PendingRequest] = [:]
    private var occupiedTypes: Set<FrameType> = []
    private var availabilityWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var listener: Task<Void, Never>?
    private var isClosed = false

    init(connection: any ControlConnection) {
        self.connection = connection
        self.pushBroadcaster = FramePushBroadcaster()
        self.listener = nil
        Task { [weak self] in
            await self?.startListening()
        }
    }

    private func startListening() {
        guard listener == nil, !isClosed else { return }
        listener = Task { [weak self, frames = connection.frames] in
            do {
                for try await frame in frames {
                    await self?.receive(frame)
                }
                await self?.failAll(with: RequestResponseError.closed)
            } catch {
                await self?.failAll(with: error)
            }
        }
    }

    var pendingRequestCount: Int { pending.count }

    func connect() async throws {
        try await connection.connect()
    }

    func reconnect() async throws {
        guard !isClosed else { throw RequestResponseError.closed }
        // 旧连接上的在途请求不能跨 TCP 连接继续等待响应。
        failAll(with: ConnectionError.disconnected)
        try await connection.reconnect()
    }

    func request(
        _ frame: Frame,
        expecting expectedTypes: Set<FrameType>,
        timeout: Duration = .seconds(10)
    ) async throws -> Frame {
        guard !expectedTypes.isEmpty else { throw RequestResponseError.emptyExpectedTypes }
        guard !isClosed else { throw RequestResponseError.closed }
        try await reserve(expectedTypes)
        defer { releaseReservation(expectedTypes) }
        try Task.checkCancellation()
        guard !isClosed else { throw RequestResponseError.closed }
        let identifier = UUID()
        let responseStream = registerPending(identifier, expectedTypes: expectedTypes)

        return try await withTaskCancellationHandler {
            do {
                // [修改] send、响应等待和超时都属于当前请求任务，父任务取消会同步传递，不再遗留后台发送。
                return try await withThrowingTaskGroup(of: Frame.self) { group in
                    group.addTask { [connection] in
                        try Task.checkCancellation()
                        try await connection.send(frame)
                        var iterator = responseStream.makeAsyncIterator()
                        guard let response = try await iterator.next() else {
                            throw RequestResponseError.closed
                        }
                        return response
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw RequestResponseError.timedOut
                    }
                    guard let result = try await group.next() else {
                        throw RequestResponseError.closed
                    }
                    group.cancelAll()
                    return result
                }
            } catch is CancellationError {
                fail(identifier, with: RequestResponseError.cancelled)
                throw RequestResponseError.cancelled
            } catch {
                fail(identifier, with: error)
                throw error
            }
        } onCancel: {
            Task { await self.fail(identifier, with: RequestResponseError.cancelled) }
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        listener?.cancel()
        listener = nil
        failAll(with: RequestResponseError.closed)
        resumeAvailabilityWaiters(throwing: RequestResponseError.closed)
        pushBroadcaster.finish()
        await connection.disconnect()
    }

    private func receive(_ frame: Frame) {
        // [修改] 所有收到的帧都广播，避免匹配响应被其他长期订阅者丢失。
        pushBroadcaster.yield(frame)
        if let match = pending.first(where: { $0.value.expectedTypes.contains(frame.type) }) {
            complete(match.key, with: .success(frame))
        }
    }

    private func reserve(_ types: Set<FrameType>) async throws {
        while !occupiedTypes.isDisjoint(with: types) {
            guard !isClosed else { throw RequestResponseError.closed }
            let identifier = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    availabilityWaiters[identifier] = continuation
                }
            } onCancel: {
                // [修改] 在响应类型占位队列中取消时立即移除 waiter，不能等前一个请求结束后继续发送。
                Task { await self.cancelAvailabilityWaiter(identifier) }
            }
        }
        try Task.checkCancellation()
        guard !isClosed else { throw RequestResponseError.closed }
        occupiedTypes.formUnion(types)
    }

    private func registerPending(
        _ identifier: UUID,
        expectedTypes: Set<FrameType>
    ) -> AsyncThrowingStream<Frame, Error> {
        var captured: AsyncThrowingStream<Frame, Error>.Continuation!
        let stream = AsyncThrowingStream<Frame, Error> { captured = $0 }
        pending[identifier] = PendingRequest(expectedTypes: expectedTypes, continuation: captured)
        return stream
    }

    private func releaseReservation(_ types: Set<FrameType>) {
        occupiedTypes.subtract(types)
        resumeAvailabilityWaiters()
    }

    private func cancelAvailabilityWaiter(_ identifier: UUID) {
        guard let continuation = availabilityWaiters.removeValue(forKey: identifier) else { return }
        continuation.resume(throwing: RequestResponseError.cancelled)
    }

    private func resumeAvailabilityWaiters(throwing error: Error? = nil) {
        let continuations = Array(availabilityWaiters.values)
        availabilityWaiters.removeAll()
        for continuation in continuations {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func fail(_ identifier: UUID, with error: Error) {
        complete(identifier, with: .failure(error))
    }

    private func complete(_ identifier: UUID, with result: Result<Frame, Error>) {
        guard let request = pending.removeValue(forKey: identifier) else { return }
        switch result {
        case .success(let frame):
            request.continuation.yield(frame)
            request.continuation.finish()
        case .failure(let error):
            request.continuation.finish(throwing: error)
        }
    }

    private func failAll(with error: Error) {
        let identifiers = Array(pending.keys)
        for identifier in identifiers {
            fail(identifier, with: error)
        }
    }
}
