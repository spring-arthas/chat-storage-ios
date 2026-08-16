import Foundation

actor RemoteAuthRepository: AuthRepository {
    private let client: any FrameRequesting
    private let secureStore: any SecureStore
    private let timeout: Duration
    private let nonceProvider: @Sendable () -> String

    init(
        client: any FrameRequesting,
        secureStore: any SecureStore,
        timeout: Duration = .seconds(15),
        nonceProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.client = client
        self.secureStore = secureStore
        self.timeout = timeout
        self.nonceProvider = nonceProvider
    }

    func login(account: String, password: String) async throws -> AuthenticatedUser {
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccount.isEmpty else { throw AuthError.invalidAccount }
        guard !password.isEmpty else { throw AuthError.invalidPassword }
        try await client.connect()
        let payload = try ProtocolJSON.encoder().encode(LoginRequest(username: normalizedAccount, password: password))
        let response = try await client.request(
            Frame(type: .userLoginRequest, payload: payload),
            expecting: [.userResponse],
            timeout: timeout
        )
        return try processAuthenticationResponse(response)
    }

    // [修改] 注册成功只返回新用户，不持久化登录凭据；注册后仍由用户主动登录。
    func register(
        account: String,
        email: String,
        password: String,
        avatarData: String?,
        avatarName: String?
    ) async throws -> AuthenticatedUser {
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccount.isEmpty else { throw AuthError.invalidAccount }
        guard !normalizedEmail.isEmpty else { throw AuthError.invalidEmail }
        guard !password.isEmpty else { throw AuthError.invalidPassword }
        try await client.connect()
        let request = RegisterRequest(
            username: normalizedAccount,
            password: password,
            email: normalizedEmail,
            avatarData: avatarData,
            avatarName: avatarData == nil ? nil : avatarName
        )
        let response = try await client.request(
            Frame(type: .userRegisterRequest, payload: try ProtocolJSON.encoder().encode(request)),
            expecting: [.userResponse],
            timeout: timeout
        )
        let envelope = try decodeEnvelope(response)
        guard envelope.isSuccess, let user = envelope.data else {
            throw authenticationError(from: envelope)
        }
        return user
    }

    func resumeSession() async throws -> AuthenticatedUser? {
        guard let tokenData = try secureStore.data(for: .sessionToken),
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        try await client.connect()
        let payload = try ProtocolJSON.encoder().encode(SessionResumeRequest(sessionToken: token))
        let response = try await client.request(
            Frame(type: .userSessionResumeRequest, payload: payload),
            expecting: [.userResponse],
            timeout: timeout
        )
        do {
            return try processAuthenticationResponse(response)
        } catch let error as AuthError {
            if error == .sessionExpired { try clearSession() }
            throw error
        }
    }

    func activate() async throws -> AuthenticatedUser? {
        try await resumeSession()
    }

    // [修改] AppSession 重连阶段先替换 TCP/TLS，再由 activate() 发送 0x46。
    func reconnect() async throws {
        try await client.reconnect()
    }

    // [修改] 0x47/0x48 心跳同时校验帧类型和 nonce，迟到响应不能掩盖断线。
    func heartbeat() async throws {
        let nonce = nonceProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nonce.isEmpty else { throw AuthError.invalidResponse }
        let payload = try ProtocolJSON.encoder().encode(HeartbeatRequest(nonce: nonce))
        let response = try await client.request(
            Frame(type: .heartbeatRequest, payload: payload),
            expecting: [.heartbeatResponse],
            timeout: timeout
        )
        guard response.type == .heartbeatResponse else { throw AuthError.invalidResponse }

        let envelope: HeartbeatResponseEnvelope
        do {
            envelope = try ProtocolJSON.decoder().decode(HeartbeatResponseEnvelope.self, from: response.payload)
        } catch {
            throw AuthError.invalidResponse
        }
        guard envelope.success else {
            if ["NOT_LOGGED_IN", "SESSION_INVALID", "SESSION_EXPIRED"].contains(envelope.errorCode) {
                throw AuthError.sessionExpired
            }
            throw AuthError.server(message: envelope.message, code: envelope.errorCode)
        }
        guard envelope.data?.nonce == nonce else { throw AuthError.invalidResponse }
    }

    // [修改] 头像更新：0x45 请求，返回带新头像的用户并持久化会话。
    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser {
        let payload = try ProtocolJSON.encoder().encode(UpdateAvatarRequest(avatarData: avatarData, avatarName: avatarName))
        let response = try await client.request(
            Frame(type: .userAvatarUpdateRequest, payload: payload),
            expecting: [.userResponse],
            timeout: timeout
        )
        return try processProfileMutationResponse(response)
    }

    func logout() async {
        do {
            _ = try await client.request(
                Frame(type: .userLogoutRequest),
                expecting: [.userResponse],
                timeout: timeout
            )
        } catch {
            // Local credentials must be cleared even if the connection is unavailable.
        }
        try? clearSession()
    }

    private func processAuthenticationResponse(_ frame: Frame) throws -> AuthenticatedUser {
        let envelope = try decodeEnvelope(frame)
        guard envelope.isSuccess, let user = envelope.data else {
            try clearSession()
            throw authenticationError(from: envelope)
        }
        guard let sessionToken = user.sessionToken, !sessionToken.isEmpty else {
            try clearSession()
            throw AuthError.missingSessionToken
        }
        try persist(user, sessionToken: sessionToken, transferToken: user.transferToken)
        return user
    }

    private func processProfileMutationResponse(_ frame: Frame) throws -> AuthenticatedUser {
        let envelope = try decodeEnvelope(frame)
        guard envelope.isSuccess, let user = envelope.data else {
            let error = authenticationError(from: envelope)
            if error == .sessionExpired {
                try clearSession()
            }
            // [修改] 头像业务失败不能删除仍有效的登录和网盘传输凭据。
            throw error
        }

        let storedSessionToken = try storedString(for: .sessionToken)
        let storedTransferToken = try storedString(for: .transferToken)
        guard let sessionToken = nonEmpty(user.sessionToken) ?? storedSessionToken else {
            throw AuthError.missingSessionToken
        }
        let transferToken = nonEmpty(user.transferToken) ?? storedTransferToken
        let mergedUser = AuthenticatedUser(
            id: user.id,
            username: user.username,
            nickname: user.nickname,
            avatar: user.avatar,
            email: user.email,
            phone: user.phone,
            status: user.status,
            transferToken: transferToken,
            sessionToken: sessionToken
        )
        // [修改] 老版本头像响应未返回新 token 时沿用 Keychain 中现有凭据。
        try persist(mergedUser, sessionToken: sessionToken, transferToken: transferToken)
        return mergedUser
    }

    private func decodeEnvelope(_ frame: Frame) throws -> UserResponseEnvelope {
        let envelope: UserResponseEnvelope
        do {
            envelope = try ProtocolJSON.decoder().decode(UserResponseEnvelope.self, from: frame.payload)
        } catch {
            throw AuthError.invalidResponse
        }
        return envelope
    }

    private func authenticationError(from envelope: UserResponseEnvelope) -> AuthError {
        if envelope.errorCode == "SESSION_INVALID" || envelope.errorCode == "SESSION_EXPIRED" {
            return .sessionExpired
        }
        return .server(message: envelope.message, code: envelope.errorCode)
    }

    private func persist(
        _ user: AuthenticatedUser,
        sessionToken: String,
        transferToken: String?
    ) throws {
        try secureStore.set(Data(sessionToken.utf8), for: .sessionToken)
        if let transferToken = nonEmpty(transferToken) {
            try secureStore.set(Data(transferToken.utf8), for: .transferToken)
        } else {
            try secureStore.remove(.transferToken)
        }
        try secureStore.set(ProtocolJSON.encoder().encode(user), for: .currentUser)
    }

    private func storedString(for key: SecureStoreKey) throws -> String? {
        guard let data = try secureStore.data(for: key),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return nonEmpty(value)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clearSession() throws {
        try secureStore.remove(.sessionToken)
        try secureStore.remove(.transferToken)
        try secureStore.remove(.currentUser)
    }
}
