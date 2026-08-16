import XCTest
@testable import ChatStorage

final class RequestResponseClientTests: XCTestCase {
    func testCancellingOneConnectWaiterKeepsSharedConnectionAlive() async {
        let transport = FakeControlTransport(stateAfterStart: nil)
        let connection = NWControlConnection(
            configuration: .default,
            transportFactory: FakeControlTransportFactory([transport]).make
        )
        let firstConnect = Task { try await connection.connect() }
        let firstStarted = await waitUntil { transport.startCallCount == 1 }
        XCTAssertTrue(firstStarted)

        let secondConnect = Task { try await connection.connect() }
        let bothWaiting = await waitUntil { transport.stateReadCount >= 4 }
        XCTAssertTrue(bothWaiting)

        firstConnect.cancel()
        _ = await firstConnect.result
        transport.transition(to: .ready)

        let secondCompleted = expectation(description: "第二个连接等待者完成")
        Task {
            _ = await secondConnect.result
            secondCompleted.fulfill()
        }
        let waiterResult = await XCTWaiter.fulfillment(of: [secondCompleted], timeout: 1)
        if waiterResult != .completed {
            await connection.disconnect()
            _ = await secondConnect.result
            XCTFail("取消一个等待者后，共享连接无法继续完成")
            return
        }

        switch await secondConnect.result {
        case .success:
            XCTAssertEqual(transport.cancelCallCount, 0)
        case .failure(let error):
            XCTFail("Expected shared connection to stay alive, got \(error)")
        }
        await connection.disconnect()
    }

    func testControlConnectionReturnsTimeoutWhenTransportNeverBecomesReady() async {
        let transport = FakeControlTransport(stateAfterStart: nil)
        let connection = NWControlConnection(
            configuration: .default,
            transportFactory: FakeControlTransportFactory([transport]).make
        )
        let completed = expectation(description: "连接等待结束")
        let connectTask = Task<Result<Void, Error>, Never> {
            do {
                try await connection.connect()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        Task {
            _ = await connectTask.value
            completed.fulfill()
        }

        // [修改] 生产连接超时为 10 秒，再留 1 秒调度余量；旧实现会永远卡在任务组退出阶段。
        let waiterResult = await XCTWaiter.fulfillment(of: [completed], timeout: 11)
        if waiterResult != .completed {
            await connection.disconnect()
            _ = await connectTask.value
            XCTFail("连接超时触发后仍未返回")
            return
        }

        switch await connectTask.value {
        case .success:
            XCTFail("Expected connection timeout")
        case .failure(let error):
            XCTAssertEqual(error as? ConnectionError, .connectionTimeout)
        }
        await connection.disconnect()
    }

    func testControlConnectionReconnectsWithoutEndingFramesAfterTransientFailure() async throws {
        let firstTransport = FakeControlTransport()
        let secondTransport = FakeControlTransport()
        let transportFactory = FakeControlTransportFactory([firstTransport, secondTransport])
        let connection = NWControlConnection(
            configuration: .default,
            transportFactory: transportFactory.make
        )

        try await connection.connect()
        let expectedFrame = Frame(type: .friendEventPush, payload: Data("reconnected".utf8))
        let encodedFrame = try FrameCodec.encode(expectedFrame)

        // [修改] 先留下半个旧连接帧，确保重连时 decoder 会清空且长期 frames 流不会结束。
        firstTransport.deliver(data: encodedFrame.prefix(4))
        let firstReceiveReady = await waitUntil { firstTransport.receiveRegistrationCount >= 2 }
        XCTAssertTrue(firstReceiveReady)
        firstTransport.transition(to: .failed("network lost"))

        try await connection.connect()
        XCTAssertEqual(transportFactory.creationCount, 2)
        let secondReceiveReady = await waitUntil { secondTransport.receiveRegistrationCount >= 1 }
        XCTAssertTrue(secondReceiveReady)

        let receivedFrameTask = Task { try await nextFrame(from: connection.frames) }
        secondTransport.deliver(data: encodedFrame)

        let receivedFrame = try await receivedFrameTask.value
        XCTAssertEqual(receivedFrame, expectedFrame)
        await connection.disconnect()
    }

    // [修改] 心跳失败时即使旧 transport 仍显示 ready，也必须强制换一条新的 TCP/TLS 连接。
    func testExplicitReconnectReplacesReadyTransportAndKeepsFramesStreamOpen() async throws {
        let firstTransport = FakeControlTransport()
        let secondTransport = FakeControlTransport()
        let transportFactory = FakeControlTransportFactory([firstTransport, secondTransport])
        let connection = NWControlConnection(
            configuration: .default,
            transportFactory: transportFactory.make
        )

        try await connection.connect()
        try await connection.reconnect()

        XCTAssertEqual(firstTransport.cancelCallCount, 1)
        XCTAssertEqual(transportFactory.creationCount, 2)

        let expectedFrame = Frame(type: .friendEventPush, payload: Data("new-tls-connection".utf8))
        let receivedFrameTask = Task { try await nextFrame(from: connection.frames) }
        secondTransport.deliver(data: try FrameCodec.encode(expectedFrame))

        let receivedFrame = try await receivedFrameTask.value
        XCTAssertEqual(receivedFrame, expectedFrame)
        await connection.disconnect()
    }

    func testExplicitDisconnectEndsLongLivedFramesStream() async throws {
        let transport = FakeControlTransport()
        let connection = NWControlConnection(
            configuration: .default,
            transportFactory: FakeControlTransportFactory([transport]).make
        )

        try await connection.connect()
        await connection.disconnect()

        let receivedFrame = try await nextFrame(from: connection.frames)
        XCTAssertNil(receivedFrame)
    }

    func testRequestRegistersWaiterBeforeSend() async throws {
        let connection = FakeControlConnection()
        let client = RequestResponseClient(connection: connection)
        connection.onSend = { frame in
            XCTAssertEqual(frame.type, .userLoginRequest)
            connection.emit(Frame(type: .userResponse, payload: Data("{}".utf8)))
        }

        let response = try await client.request(
            Frame(type: .userLoginRequest, payload: Data()),
            expecting: [.userResponse],
            timeout: .seconds(1)
        )

        XCTAssertEqual(response.type, .userResponse)
        await client.close()
    }

    func testUnsolicitedFrameAppearsOnPushStream() async throws {
        let connection = FakeControlConnection()
        let client = RequestResponseClient(connection: connection)
        // [修改] 先同步创建推送流，确保广播订阅已经注册；async let + 单次 yield 没有时序保证，会偶发永久等待。
        let pushes = client.pushes

        connection.emit(Frame(type: .friendEventPush, payload: Data("{}".utf8)))

        let pushedFrame = await nextFrame(from: pushes)
        XCTAssertEqual(pushedFrame?.type, .friendEventPush)
        await client.close()
    }

    func testMatchedResponseIsBroadcastToMultiplePushSubscribers() async throws {
        let connection = FakeControlConnection()
        let client = RequestResponseClient(connection: connection)
        let firstSubscriber = client.pushes
        let secondSubscriber = client.pushes
        let request = Task {
            try await client.request(
                Frame(type: .userLoginRequest),
                expecting: [.userResponse],
                timeout: .seconds(1)
            )
        }
        // [修改] 先确认请求已真正写入连接，再模拟服务端响应；服务端不可能在收到请求前回复。
        let requestSent = await waitUntil { connection.sentFrames.count == 1 }
        XCTAssertTrue(requestSent)

        let response = Frame(type: .userResponse, payload: Data("response".utf8))
        connection.emit(response)

        let requestResponse = try await request.value
        let firstResponse = await nextFrame(from: firstSubscriber)
        let secondResponse = await nextFrame(from: secondSubscriber)
        XCTAssertEqual(requestResponse, response)
        XCTAssertEqual(firstResponse, response)
        XCTAssertEqual(secondResponse, response)
        await client.close()
    }

    func testTimeoutRemovesPendingRequest() async {
        let connection = FakeControlConnection()
        let client = RequestResponseClient(connection: connection)

        do {
            _ = try await client.request(
                Frame(type: .fileListRequest, payload: Data()),
                expecting: [.fileResponse],
                timeout: .milliseconds(20)
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? RequestResponseError, .timedOut)
        }

        let pendingCount = await client.pendingRequestCount
        XCTAssertEqual(pendingCount, 0)
        await client.close()
    }

    func testCancellationRemovesPendingRequest() async {
        let connection = FakeControlConnection()
        let client = RequestResponseClient(connection: connection)
        let task = Task {
            try await client.request(
                Frame(type: .fileListRequest, payload: Data()),
                expecting: [.fileResponse],
                timeout: .seconds(5)
            )
        }
        await Task.yield()

        task.cancel()
        _ = await task.result

        let pendingCount = await client.pendingRequestCount
        XCTAssertEqual(pendingCount, 0)
        await client.close()
    }

    // [修改] 同响应类型请求排队时取消，前一个请求释放占位后也不能再发送已取消帧。
    func testCancelledReservationNeverSendsFrameAfterEarlierRequestCompletes() async throws {
        let connection = FakeControlConnection()
        let client = RequestResponseClient(connection: connection)
        let firstRequest = Task {
            try await client.request(
                Frame(type: .fileListRequest),
                expecting: [.fileResponse],
                timeout: .seconds(1)
            )
        }
        let firstFrameSent = await waitUntil { connection.sentFrames.count == 1 }
        XCTAssertTrue(firstFrameSent)

        let cancelledRequest = Task {
            try await client.request(
                Frame(type: .fileDetailRequest),
                expecting: [.fileResponse],
                timeout: .seconds(1)
            )
        }
        await Task.yield()
        cancelledRequest.cancel()

        connection.emit(Frame(type: .fileResponse, payload: Data("first".utf8)))
        _ = try await firstRequest.value
        _ = await cancelledRequest.result
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(connection.sentFrames.count, 1)
        await client.close()
    }

    // [修改] 被取消的第二个 send 仍在串行槽位排队时，绝不能在第一个 send 完成后写入 transport。
    func testCancelledQueuedSendNeverReachesTransport() async throws {
        let transport = FakeControlTransport(automaticallyCompletesSends: false)
        let connection = NWControlConnection(
            configuration: .default,
            transportFactory: FakeControlTransportFactory([transport]).make
        )
        try await connection.connect()

        let firstSend = Task { try await connection.send(Frame(type: .heartbeatRequest)) }
        let firstSendStarted = await waitUntil { transport.sendCallCount == 1 }
        XCTAssertTrue(firstSendStarted)
        let cancelledSend = Task { try await connection.send(Frame(type: .userSessionResumeRequest)) }
        await Task.yield()
        cancelledSend.cancel()

        transport.completeNextSend()
        _ = await firstSend.result
        try? await Task.sleep(for: .milliseconds(50))
        let sendCallCount = transport.sendCallCount
        if sendCallCount > 1 { transport.completeNextSend() }
        _ = await cancelledSend.result

        XCTAssertEqual(sendCallCount, 1)
        await connection.disconnect()
    }

    // [修改] 旧 TLS 上排队的帧不能在 reconnect 后借用新 transport 发送。
    func testReconnectRejectsQueuedFramesFromPreviousTransport() async throws {
        let firstTransport = FakeControlTransport(automaticallyCompletesSends: false)
        let secondTransport = FakeControlTransport()
        let connection = NWControlConnection(
            configuration: .default,
            transportFactory: FakeControlTransportFactory([firstTransport, secondTransport]).make
        )
        try await connection.connect()

        let inFlightSend = Task { try await connection.send(Frame(type: .heartbeatRequest)) }
        let firstSendStarted = await waitUntil { firstTransport.sendCallCount == 1 }
        XCTAssertTrue(firstSendStarted)
        let queuedSend = Task { try await connection.send(Frame(type: .userSessionResumeRequest)) }
        await Task.yield()

        try await connection.reconnect()
        firstTransport.completeNextSend()
        _ = await inFlightSend.result
        _ = await queuedSend.result

        XCTAssertEqual(secondTransport.sendCallCount, 0)
        await connection.disconnect()
    }

    // [修改] 已进入 transport.send 的任务取消后也必须立刻返回，不能永久卡住请求超时或退出。
    func testCancellingInFlightSendInvalidatesTransportAndReturns() async throws {
        let transport = FakeControlTransport(automaticallyCompletesSends: false)
        let connection = NWControlConnection(
            configuration: .default,
            transportFactory: FakeControlTransportFactory([transport]).make
        )
        try await connection.connect()

        let send = Task { try await connection.send(Frame(type: .heartbeatRequest)) }
        let sendStarted = await waitUntil { transport.sendCallCount == 1 }
        XCTAssertTrue(sendStarted)
        send.cancel()

        let completed = expectation(description: "在途发送取消后返回")
        Task {
            _ = await send.result
            completed.fulfill()
        }
        let waiterResult = await XCTWaiter.fulfillment(of: [completed], timeout: 0.5)
        if waiterResult != .completed {
            transport.completeNextSend()
            _ = await send.result
            await connection.disconnect()
            XCTFail("取消在途 send 后仍未返回")
            return
        }

        XCTAssertEqual(transport.cancelCallCount, 1)
        await connection.disconnect()
    }
}

private func nextFrame(from stream: AsyncThrowingStream<Frame, Error>) async throws -> Frame? {
    try await withThrowingTaskGroup(of: Frame?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(1))
            throw RequestResponseError.timedOut
        }
        guard let result = try await group.next() else {
            throw RequestResponseError.closed
        }
        group.cancelAll()
        return result
    }
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return predicate()
}

private func nextFrame(from stream: AsyncStream<Frame>) async -> Frame? {
    await withTaskGroup(of: Frame?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(200))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private final class FakeControlConnection: ControlConnection, @unchecked Sendable {
    let frames: AsyncThrowingStream<Frame, Error>
    var onSend: (@Sendable (Frame) async throws -> Void)?
    private let continuation: AsyncThrowingStream<Frame, Error>.Continuation
    private let lock = NSLock()
    private var recordedFrames: [Frame] = []

    var sentFrames: [Frame] {
        lock.withLock { recordedFrames }
    }

    init() {
        var captured: AsyncThrowingStream<Frame, Error>.Continuation!
        frames = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func connect() async throws {}

    func send(_ frame: Frame) async throws {
        lock.withLock { recordedFrames.append(frame) }
        try await onSend?(frame)
    }

    func disconnect() async {
        continuation.finish()
    }

    func emit(_ frame: Frame) {
        continuation.yield(frame)
    }
}

private final class FakeControlTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FakeControlTransport]
    private var created = 0

    init(_ transports: [FakeControlTransport]) {
        self.transports = transports
    }

    var creationCount: Int {
        lock.withLock { created }
    }

    func make(host: String, port: UInt16) -> any ControlTransport {
        lock.withLock {
            precondition(!transports.isEmpty, "No fake control transport remaining")
            created += 1
            return transports.removeFirst()
        }
    }
}

private final class FakeControlTransport: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stateAfterStart: ControlTransportState?
    private let automaticallyCompletesSends: Bool
    private var currentState: ControlTransportState = .connecting
    private var stateReads = 0
    private var startCalls = 0
    private var cancelCalls = 0
    private var stateHandler: (@Sendable (ControlTransportState) -> Void)?
    private var receiveHandler: (@Sendable (Data?, Bool, String?) -> Void)?
    private var receiveRegistrations = 0
    private var sendCalls = 0
    private var sendCompletions: [@Sendable (String?) -> Void] = []

    init(
        stateAfterStart: ControlTransportState? = .ready,
        automaticallyCompletesSends: Bool = true
    ) {
        self.stateAfterStart = stateAfterStart
        self.automaticallyCompletesSends = automaticallyCompletesSends
    }

    var state: ControlTransportState {
        lock.withLock {
            stateReads += 1
            return currentState
        }
    }

    var stateReadCount: Int {
        lock.withLock { stateReads }
    }

    var startCallCount: Int {
        lock.withLock { startCalls }
    }

    var cancelCallCount: Int {
        lock.withLock { cancelCalls }
    }

    var receiveRegistrationCount: Int {
        lock.withLock { receiveRegistrations }
    }

    var sendCallCount: Int {
        lock.withLock { sendCalls }
    }

    func setStateUpdateHandler(_ handler: (@Sendable (ControlTransportState) -> Void)?) {
        lock.withLock { stateHandler = handler }
    }

    func start(on queue: DispatchQueue) {
        lock.withLock { startCalls += 1 }
        if let stateAfterStart {
            transition(to: stateAfterStart)
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (String?) -> Void) {
        let shouldComplete = lock.withLock { () -> Bool in
            sendCalls += 1
            if !automaticallyCompletesSends { sendCompletions.append(completion) }
            return automaticallyCompletesSends
        }
        if shouldComplete { completion(nil) }
    }

    func receive(
        maximumLength: Int,
        completion: @escaping @Sendable (Data?, Bool, String?) -> Void
    ) {
        lock.withLock {
            receiveRegistrations += 1
            receiveHandler = completion
        }
    }

    func cancel() {
        lock.withLock { cancelCalls += 1 }
        transition(to: .cancelled)
    }

    func transition(to state: ControlTransportState) {
        let handler = lock.withLock { () -> (@Sendable (ControlTransportState) -> Void)? in
            currentState = state
            return stateHandler
        }
        handler?(state)
    }

    func deliver(data: Data? = nil, isComplete: Bool = false, error: String? = nil) {
        let handler = lock.withLock { receiveHandler }
        handler?(data, isComplete, error)
    }

    func completeNextSend(error: String? = nil) {
        let completion = lock.withLock { () -> (@Sendable (String?) -> Void)? in
            guard !sendCompletions.isEmpty else { return nil }
            return sendCompletions.removeFirst()
        }
        completion?(error)
    }
}
