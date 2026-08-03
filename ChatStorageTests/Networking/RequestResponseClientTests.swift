import XCTest
@testable import ChatStorage

final class RequestResponseClientTests: XCTestCase {
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
        async let pushed = firstFrame(from: client.pushes)
        await Task.yield()

        connection.emit(Frame(type: .friendEventPush, payload: Data("{}".utf8)))

        let pushedFrame = await pushed
        XCTAssertEqual(pushedFrame?.type, .friendEventPush)
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
}

private func firstFrame(from stream: AsyncStream<Frame>) async -> Frame? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}

private final class FakeControlConnection: ControlConnection, @unchecked Sendable {
    let frames: AsyncThrowingStream<Frame, Error>
    var onSend: (@Sendable (Frame) async throws -> Void)?
    private let continuation: AsyncThrowingStream<Frame, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<Frame, Error>.Continuation!
        frames = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func connect() async throws {}

    func send(_ frame: Frame) async throws {
        try await onSend?(frame)
    }

    func disconnect() async {
        continuation.finish()
    }

    func emit(_ frame: Frame) {
        continuation.yield(frame)
    }
}
