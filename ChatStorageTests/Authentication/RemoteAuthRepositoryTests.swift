import XCTest
@testable import ChatStorage

final class RemoteAuthRepositoryTests: XCTestCase {
    func testLoginUsesAndroidWireKeysAndPersistsTokens() async throws {
        let client = FakeFrameRequestClient(response: .success(userResponse()))
        let store = MemorySecureStore()
        let repository = RemoteAuthRepository(client: client, secureStore: store)

        let user = try await repository.login(account: " alice ", password: "secret")

        XCTAssertEqual(user.username, "alice")
        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        XCTAssertEqual(sent.type, .userLoginRequest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: String])
        XCTAssertEqual(json, ["userName": "alice", "password": "secret"])
        XCTAssertEqual(try store.data(for: .sessionToken), Data("session-1".utf8))
        XCTAssertEqual(try store.data(for: .transferToken), Data("transfer-1".utf8))
        XCTAssertNotNil(try store.data(for: .currentUser))
    }

    func testLoginConnectsBeforeSendingCredentials() async throws {
        let client = FakeFrameRequestClient(response: .success(userResponse()))
        let repository = RemoteAuthRepository(client: client, secureStore: MemorySecureStore())

        _ = try await repository.login(account: "alice", password: "secret")

        let events = await client.events
        XCTAssertEqual(events, ["connect", "request"])
    }

    func testLoginRejectionClearsStoredSession() async {
        let client = FakeFrameRequestClient(response: .success(errorResponse(code: "PASSWORD_INVALID")))
        let store = MemorySecureStore()
        try? store.set(Data("old".utf8), for: .sessionToken)
        let repository = RemoteAuthRepository(client: client, secureStore: store)

        do {
            _ = try await repository.login(account: "alice", password: "wrong")
            XCTFail("Expected rejection")
        } catch let error as AuthError {
            XCTAssertEqual(error, .server(message: "密码错误", code: "PASSWORD_INVALID"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(try? store.data(for: .sessionToken))
    }

    func testMalformedLoginPayloadThrowsInvalidResponse() async {
        let client = FakeFrameRequestClient(response: .success(Frame(type: .userResponse, payload: Data("not-json".utf8))))
        let repository = RemoteAuthRepository(client: client, secureStore: MemorySecureStore())

        do {
            _ = try await repository.login(account: "alice", password: "secret")
            XCTFail("Expected invalid response")
        } catch let error as AuthError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResumeSendsStoredSessionToken() async throws {
        let client = FakeFrameRequestClient(response: .success(userResponse()))
        let store = MemorySecureStore()
        try store.set(Data("stored-session".utf8), for: .sessionToken)
        let repository = RemoteAuthRepository(client: client, secureStore: store)

        let user = try await repository.resumeSession()

        XCTAssertEqual(user?.id, 42)
        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        XCTAssertEqual(sent.type, .userSessionResumeRequest)
        XCTAssertEqual(String(data: sent.payload, encoding: .utf8), #"{"sessionToken":"stored-session"}"#)
    }

    func testExpiredResumeClearsSession() async {
        let client = FakeFrameRequestClient(response: .success(errorResponse(code: "SESSION_EXPIRED")))
        let store = MemorySecureStore()
        try? store.set(Data("expired".utf8), for: .sessionToken)
        try? store.set(Data("user".utf8), for: .currentUser)
        let repository = RemoteAuthRepository(client: client, secureStore: store)

        do {
            _ = try await repository.resumeSession()
            XCTFail("Expected expired session")
        } catch let error as AuthError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(try? store.data(for: .sessionToken))
        XCTAssertNil(try? store.data(for: .currentUser))
    }

    func testLogoutAlwaysClearsLocalSession() async {
        let client = FakeFrameRequestClient(response: .failure(RequestResponseError.closed))
        let store = MemorySecureStore()
        try? store.set(Data("session".utf8), for: .sessionToken)
        let repository = RemoteAuthRepository(client: client, secureStore: store)

        await repository.logout()

        XCTAssertNil(try? store.data(for: .sessionToken))
        let sentFrames = await client.sentFrames
        XCTAssertEqual(sentFrames.first?.type, .userLogoutRequest)
    }

    private func userResponse() -> Frame {
        Frame(type: .userResponse, payload: Data(#"{"success":true,"code":200,"data":{"userId":42,"userName":"alice","nickName":"Alice","mail":"alice@example.com","status":1,"transferToken":"transfer-1","sessionToken":"session-1"}}"#.utf8))
    }

    private func errorResponse(code: String) -> Frame {
        Frame(type: .userResponse, payload: Data("{\"success\":false,\"code\":400,\"message\":\"密码错误\",\"errorCode\":\"\(code)\"}".utf8))
    }
}

actor FakeFrameRequestClient: FrameRequesting {
    private let response: Result<Frame, Error>
    private(set) var sentFrames: [Frame] = []
    private(set) var events: [String] = []

    init(response: Result<Frame, Error>) {
        self.response = response
    }

    func connect() async throws {
        events.append("connect")
    }

    func request(_ frame: Frame, expecting: Set<FrameType>, timeout: Duration) async throws -> Frame {
        events.append("request")
        sentFrames.append(frame)
        return try response.get()
    }
}

final class MemorySecureStore: SecureStore, @unchecked Sendable {
    private var values: [SecureStoreKey: Data] = [:]
    private let lock = NSLock()

    func data(for key: SecureStoreKey) throws -> Data? {
        lock.withLock { values[key] }
    }

    func set(_ data: Data, for key: SecureStoreKey) throws {
        lock.withLock { values[key] = data }
    }

    func remove(_ key: SecureStoreKey) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}
