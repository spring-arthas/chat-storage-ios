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
    var account: String
    var password: String
    private(set) var state: LoginState = .idle

    private let repository: any AuthRepository

    init(repository: any AuthRepository, initialAccount: String = "", initialPassword: String = "") {
        self.repository = repository
        self.account = initialAccount
        self.password = initialPassword
    }

    // [修改] 生产入口固定为空账号和空密码，联调凭据不得写入 App 源码或安装包。
    static func production(repository: any AuthRepository) -> LoginViewModel {
        LoginViewModel(repository: repository)
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

    // [修改] Face ID 只解锁已有会话，不保存或自动填充明文密码。
    func loginWithBiometrics(using authenticator: any BiometricAuthenticating) async {
        guard state != .loading else { return }
        state = .loading
        do {
            guard try await authenticator.authenticate(reason: "使用 Face ID 登录 Chat Storage") else {
                throw BiometricAuthenticationError.rejected
            }
            guard let user = try await repository.resumeSession() else {
                state = .failed("没有可恢复的登录状态，请使用账号密码登录")
                return
            }
            state = .authenticated(user)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Face ID 登录失败")
        }
    }
}

enum RegistrationState: Equatable, Sendable {
    case idle
    case loading
    case registered(AuthenticatedUser)
    case failed(String)
}

enum RegistrationInputValidator {
    static func isValidAccount(_ value: String) -> Bool {
        isValidPhone(value) || isValidEmail(value)
    }

    static func isValidEmail(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}$"#,
            options: .regularExpression
        ) != nil
    }

    static func isValidPhone(_ value: String) -> Bool {
        value.range(of: #"^1[3-9]\d{9}$"#, options: .regularExpression) != nil
    }
}

@MainActor
@Observable
final class RegistrationViewModel {
    var account = ""
    var email = ""
    var password = ""
    var confirmPassword = ""
    var avatarData: String?
    private(set) var state: RegistrationState = .idle

    private let repository: any AuthRepository

    init(repository: any AuthRepository) {
        self.repository = repository
    }

    func register() async {
        guard state != .loading else { return }
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RegistrationInputValidator.isValidAccount(normalizedAccount) else {
            state = .failed("账号请输入有效手机号或邮箱")
            return
        }
        guard RegistrationInputValidator.isValidEmail(normalizedEmail) else {
            state = .failed("请输入有效邮箱")
            return
        }
        guard password.count >= 6 else {
            state = .failed("密码长度至少为6位")
            return
        }
        guard password == confirmPassword else {
            state = .failed("两次输入的密码不一致")
            return
        }

        account = normalizedAccount
        email = normalizedEmail
        state = .loading
        do {
            let user = try await repository.register(
                account: normalizedAccount,
                email: normalizedEmail,
                password: password,
                avatarData: avatarData,
                avatarName: avatarData == nil ? nil : "avatar.jpg"
            )
            password = ""
            confirmPassword = ""
            state = .registered(user)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "注册失败，请稍后重试")
        }
    }

    func reset() {
        account = ""
        email = ""
        password = ""
        confirmPassword = ""
        avatarData = nil
        state = .idle
    }
}
