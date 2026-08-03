import Foundation

actor RemoteAuthRepository: AuthRepository {
    private let client: any FrameRequesting
    private let secureStore: any SecureStore
    private let timeout: Duration

    init(client: any FrameRequesting, secureStore: any SecureStore, timeout: Duration = .seconds(15)) {
        self.client = client
        self.secureStore = secureStore
        self.timeout = timeout
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
        return try process(response)
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
            return try process(response)
        } catch let error as AuthError {
            if error == .sessionExpired { try clearSession() }
            throw error
        }
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

    private func process(_ frame: Frame) throws -> AuthenticatedUser {
        let envelope: UserResponseEnvelope
        do {
            envelope = try ProtocolJSON.decoder().decode(UserResponseEnvelope.self, from: frame.payload)
        } catch {
            throw AuthError.invalidResponse
        }
        guard envelope.isSuccess, let user = envelope.data else {
            try clearSession()
            if envelope.errorCode == "SESSION_INVALID" || envelope.errorCode == "SESSION_EXPIRED" {
                throw AuthError.sessionExpired
            }
            throw AuthError.server(message: envelope.message, code: envelope.errorCode)
        }
        guard let sessionToken = user.sessionToken, !sessionToken.isEmpty else {
            try clearSession()
            throw AuthError.missingSessionToken
        }
        try secureStore.set(Data(sessionToken.utf8), for: .sessionToken)
        if let transferToken = user.transferToken, !transferToken.isEmpty {
            try secureStore.set(Data(transferToken.utf8), for: .transferToken)
        } else {
            try secureStore.remove(.transferToken)
        }
        try secureStore.set(ProtocolJSON.encoder().encode(user), for: .currentUser)
        return user
    }

    private func clearSession() throws {
        try secureStore.remove(.sessionToken)
        try secureStore.remove(.transferToken)
        try secureStore.remove(.currentUser)
    }
}
