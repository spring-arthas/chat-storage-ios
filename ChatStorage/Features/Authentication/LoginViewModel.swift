import Foundation
import Observation

enum LoginState: Equatable, Sendable {
    case idle
    case loading
    case authenticated(AuthenticatedUser)
    case failed(String)
}

@MainActor
@Observable
final class LoginViewModel {
    var account = ""
    var password = ""
    private(set) var state: LoginState = .idle

    private let repository: any AuthRepository

    init(repository: any AuthRepository) {
        self.repository = repository
    }

    func login() async {
        guard state != .loading else { return }
        guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("请输入用户名")
            return
        }
        guard !password.isEmpty else {
            state = .failed("请输入密码")
            return
        }
        state = .loading
        do {
            let user = try await repository.login(account: account, password: password)
            password = ""
            state = .authenticated(user)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "登录失败，请稍后重试")
        }
    }
}
