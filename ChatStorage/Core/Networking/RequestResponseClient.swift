import Foundation

enum RequestResponseError: Error, Equatable, Sendable {
    case emptyExpectedTypes
    case timedOut
    case cancelled
    case closed
}

protocol FrameRequesting: Sendable {
    func connect() async throws

    func request(
        _ frame: Frame,
        expecting expectedTypes: Set<FrameType>,
        timeout: Duration
    ) async throws -> Frame
}

actor RequestResponseClient: FrameRequesting {
    nonisolated let pushes: AsyncStream<Frame>

    private struct PendingRequest {
        let expectedTypes: Set<FrameType>
        let continuation: CheckedContinuation<Frame, Error>
    }

    private let connection: any ControlConnection
    private let pushContinuation: AsyncStream<Frame>.Continuation
    private var pending: [UUID: PendingRequest] = [:]
    private var occupiedTypes: Set<FrameType> = []
    private var availabilityWaiters: [CheckedContinuation<Void, Never>] = []
    private var listener: Task<Void, Never>?
    private var isClosed = false

    init(connection: any ControlConnection) {
        self.connection = connection
        var captured: AsyncStream<Frame>.Continuation!
        self.pushes = AsyncStream { captured = $0 }
        self.pushContinuation = captured
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

    func request(
        _ frame: Frame,
        expecting expectedTypes: Set<FrameType>,
        timeout: Duration = .seconds(10)
    ) async throws -> Frame {
        guard !expectedTypes.isEmpty else { throw RequestResponseError.emptyExpectedTypes }
        guard !isClosed else { throw RequestResponseError.closed }
        await reserve(expectedTypes)
        let identifier = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[identifier] = PendingRequest(expectedTypes: expectedTypes, continuation: continuation)
                Task {
                    do {
                        try await connection.send(frame)
                    } catch {
                        self.fail(identifier, with: error)
                        return
                    }
                    do {
                        try await Task.sleep(for: timeout)
                        self.fail(identifier, with: RequestResponseError.timedOut)
                    } catch {
                        // Cancellation of the timeout helper is expected after a response.
                    }
                }
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
        pushContinuation.finish()
        await connection.disconnect()
    }

    private func receive(_ frame: Frame) {
        if let match = pending.first(where: { $0.value.expectedTypes.contains(frame.type) }) {
            complete(match.key, with: .success(frame))
        } else {
            pushContinuation.yield(frame)
        }
    }

    private func reserve(_ types: Set<FrameType>) async {
        while !occupiedTypes.isDisjoint(with: types) {
            await withCheckedContinuation { availabilityWaiters.append($0) }
        }
        occupiedTypes.formUnion(types)
    }

    private func fail(_ identifier: UUID, with error: Error) {
        complete(identifier, with: .failure(error))
    }

    private func complete(_ identifier: UUID, with result: Result<Frame, Error>) {
        guard let request = pending.removeValue(forKey: identifier) else { return }
        occupiedTypes.subtract(request.expectedTypes)
        let waiters = availabilityWaiters
        availabilityWaiters.removeAll()
        waiters.forEach { $0.resume() }
        request.continuation.resume(with: result)
    }

    private func failAll(with error: Error) {
        let identifiers = Array(pending.keys)
        for identifier in identifiers {
            fail(identifier, with: error)
        }
    }
}
