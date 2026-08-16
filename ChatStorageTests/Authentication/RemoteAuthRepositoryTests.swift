import XCTest
@testable import ChatStorage

final class RemoteAuthRepositoryTests: XCTestCase {
    // [修改] 注册必须使用 0x30 的 macOS 兼容字段，且注册成功不能伪造登录态或覆盖已有凭据。
    func testRegisterUsesWireKeysWithoutPersistingSession() async throws {
        let client = FakeFrameRequestClient(response: .success(registerResponse()))
        let store = MemorySecureStore()
        try store.set(Data("existing-session".utf8), for: .sessionToken)
        try store.set(Data("existing-user".utf8), for: .currentUser)
        let repository = RemoteAuthRepository(client: client, secureStore: store)

        let user = try await repository.register(
            account: " 18806504525 ",
            email: " alice@example.com ",
            password: "secret",
            avatarData: "avatar-base64",
            avatarName: "avatar.jpg"
        )

        XCTAssertEqual(user.username, "18806504525")
        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        XCTAssertEqual(sent.type, .userRegisterRequest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: String])
        XCTAssertEqual(json, [
            "userName": "18806504525",
            "password": "secret",
            "mail": "alice@example.com",
            "avatarData": "avatar-base64",
            "avatarName": "avatar.jpg",
        ])
        XCTAssertEqual(try store.data(for: .sessionToken), Data("existing-session".utf8))
        XCTAssertEqual(try store.data(for: .currentUser), Data("existing-user".utf8))
        XCTAssertNil(try store.data(for: .transferToken))
    }

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

    // [修改] 会话恢复前的强制重连必须下沉到真实控制客户端，不能只重复调用 connect()。
    func testReconnectRebuildsUnderlyingControlConnection() async throws {
        let client = FakeFrameRequestClient(response: .success(userResponse()))
        let repository = RemoteAuthRepository(client: client, secureStore: MemorySecureStore())

        try await repository.reconnect()

        let events = await client.events
        XCTAssertEqual(events, ["reconnect"])
        let sentFrames = await client.sentFrames
        XCTAssertTrue(sentFrames.isEmpty)
    }

    // [修改] 心跳必须使用 0x47 并携带本次请求 nonce，防止旧响应被误认为当前连接可用。
    func testHeartbeatSendsNonceAndAcceptsMatchingResponse() async throws {
        let client = FakeFrameRequestClient(response: .success(heartbeatResponse(nonce: "nonce-1")))
        let repository = RemoteAuthRepository(
            client: client,
            secureStore: MemorySecureStore(),
            nonceProvider: { "nonce-1" }
        )

        try await repository.heartbeat()

        let sentFrames = await client.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        XCTAssertEqual(sent.type, .heartbeatRequest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: String])
        XCTAssertEqual(json, ["nonce": "nonce-1"])
    }

    // [修改] 请求客户端的测试替身不会替我们校验帧类型，仓库本身仍必须只接受 0x48。
    func testHeartbeatRejectsUnexpectedResponseType() async {
        let client = FakeFrameRequestClient(response: .success(userResponse()))
        let repository = RemoteAuthRepository(
            client: client,
            secureStore: MemorySecureStore(),
            nonceProvider: { "nonce-1" }
        )

        do {
            try await repository.heartbeat()
            XCTFail("非 0x48 响应不能通过心跳校验")
        } catch let error as AuthError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // [修改] 只接受当前 nonce，避免代理缓存、迟到响应或串线响应掩盖已断开的连接。
    func testHeartbeatRejectsMismatchedNonce() async {
        let client = FakeFrameRequestClient(response: .success(heartbeatResponse(nonce: "stale-nonce")))
        let repository = RemoteAuthRepository(
            client: client,
            secureStore: MemorySecureStore(),
            nonceProvider: { "nonce-1" }
        )

        do {
            try await repository.heartbeat()
            XCTFail("nonce 不一致时必须判定心跳失败")
        } catch let error as AuthError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

    func testAvatarBusinessFailureKeepsExistingSession() async throws {
        let client = FakeFrameRequestClient(response: .success(errorResponse(code: "AVATAR_INVALID")))
        let store = MemorySecureStore()
        try store.set(Data("stored-session".utf8), for: .sessionToken)
        try store.set(Data("stored-transfer".utf8), for: .transferToken)
        try store.set(Data("stored-user".utf8), for: .currentUser)
        let repository = RemoteAuthRepository(client: client, secureStore: store)

        do {
            _ = try await repository.updateAvatar(avatarData: "invalid", avatarName: "avatar.jpg")
            XCTFail("Expected avatar update rejection")
        } catch let error as AuthError {
            XCTAssertEqual(error, .server(message: "密码错误", code: "AVATAR_INVALID"))
        }

        XCTAssertEqual(try store.data(for: .sessionToken), Data("stored-session".utf8))
        XCTAssertEqual(try store.data(for: .transferToken), Data("stored-transfer".utf8))
        XCTAssertEqual(try store.data(for: .currentUser), Data("stored-user".utf8))
    }

    func testAvatarSuccessWithoutNewTokensPreservesExistingTokens() async throws {
        let client = FakeFrameRequestClient(response: .success(avatarResponseWithoutTokens()))
        let store = MemorySecureStore()
        try store.set(Data("stored-session".utf8), for: .sessionToken)
        try store.set(Data("stored-transfer".utf8), for: .transferToken)
        let repository = RemoteAuthRepository(client: client, secureStore: store)

        let user = try await repository.updateAvatar(avatarData: "new-avatar", avatarName: "avatar.jpg")

        XCTAssertEqual(user.avatar, "new-avatar")
        XCTAssertEqual(user.sessionToken, "stored-session")
        XCTAssertEqual(user.transferToken, "stored-transfer")
        XCTAssertEqual(try store.data(for: .sessionToken), Data("stored-session".utf8))
        XCTAssertEqual(try store.data(for: .transferToken), Data("stored-transfer".utf8))
    }

    private func userResponse() -> Frame {
        Frame(type: .userResponse, payload: Data(#"{"success":true,"code":200,"data":{"userId":42,"userName":"alice","nickName":"Alice","mail":"alice@example.com","status":1,"transferToken":"transfer-1","sessionToken":"session-1"}}"#.utf8))
    }

    private func registerResponse() -> Frame {
        Frame(
            type: .userResponse,
            payload: Data(#"{"success":true,"code":200,"data":{"userId":43,"userName":"18806504525","mail":"alice@example.com","status":1}}"#.utf8)
        )
    }

    private func errorResponse(code: String) -> Frame {
        Frame(type: .userResponse, payload: Data("{\"success\":false,\"code\":400,\"message\":\"密码错误\",\"errorCode\":\"\(code)\"}".utf8))
    }

    private func avatarResponseWithoutTokens() -> Frame {
        Frame(
            type: .userResponse,
            payload: Data(#"{"success":true,"code":200,"data":{"userId":42,"userName":"alice","avatar":"new-avatar"}}"#.utf8)
        )
    }

    private func heartbeatResponse(nonce: String) -> Frame {
        Frame(
            type: .heartbeatResponse,
            payload: Data("{\"success\":true,\"message\":\"ok\",\"data\":{\"nonce\":\"\(nonce)\",\"serverTime\":1}}".utf8)
        )
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

    func reconnect() async throws {
        events.append("reconnect")
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
