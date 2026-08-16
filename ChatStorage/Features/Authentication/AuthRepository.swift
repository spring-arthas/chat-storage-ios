import Foundation

protocol AuthRepository: Sendable {
    func login(account: String, password: String) async throws -> AuthenticatedUser
    func register(
        account: String,
        email: String,
        password: String,
        avatarData: String?,
        avatarName: String?
    ) async throws -> AuthenticatedUser
    func resumeSession() async throws -> AuthenticatedUser?
    func activate() async throws -> AuthenticatedUser?
    func reconnect() async throws
    func heartbeat() async throws
    func updateAvatar(avatarData: String, avatarName: String) async throws -> AuthenticatedUser
    func logout() async
}

extension AuthRepository {
    // [修改] 现有测试/预览替身可按需覆盖；不支持注册的仓库必须返回明确错误。
    func register(
        account: String,
        email: String,
        password: String,
        avatarData: String?,
        avatarName: String?
    ) async throws -> AuthenticatedUser {
        throw AuthError.server(message: "当前登录服务不支持注册", code: "REGISTER_UNSUPPORTED")
    }

    func activate() async throws -> AuthenticatedUser? {
        try await resumeSession()
    }

    // [修改] 预览和业务测试仓库没有真实 Socket，默认无需执行 transport 重建。
    func reconnect() async throws {}

    // [修改] 预览仓库和不关心网络保活的测试替身保持兼容，真实仓库覆盖此实现。
    func heartbeat() async throws {}
}

enum AuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidAccount
    case invalidEmail
    case invalidPassword
    case invalidResponse
    case missingSessionToken
    case sessionExpired
    case server(message: String, code: String?)

    var errorDescription: String? {
        switch self {
        case .invalidAccount: "请输入用户名"
        case .invalidEmail: "请输入有效邮箱"
        case .invalidPassword: "请输入密码"
        case .invalidResponse: "服务器响应格式无效"
        case .missingSessionToken: "服务器未返回会话登录凭证"
        case .sessionExpired: "登录状态已过期，请重新登录"
        case .server(let message, _): message.isEmpty ? "请求失败" : message
        }
    }
}
