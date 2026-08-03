import Foundation

protocol AuthRepository: Sendable {
    func login(account: String, password: String) async throws -> AuthenticatedUser
    func resumeSession() async throws -> AuthenticatedUser?
    func logout() async
}

enum AuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidAccount
    case invalidPassword
    case invalidResponse
    case missingSessionToken
    case sessionExpired
    case server(message: String, code: String?)

    var errorDescription: String? {
        switch self {
        case .invalidAccount: "请输入用户名"
        case .invalidPassword: "请输入密码"
        case .invalidResponse: "服务器响应格式无效"
        case .missingSessionToken: "服务器未返回会话登录凭证"
        case .sessionExpired: "登录状态已过期，请重新登录"
        case .server(let message, _): message.isEmpty ? "请求失败" : message
        }
    }
}
