import Foundation
import Observation

@MainActor
@Observable
final class AppLockController {
    private(set) var isLocked: Bool
    private(set) var isChanging = false
    private(set) var errorMessage: String?

    private let preferences: ProfilePreferencesController
    private let authenticator: any BiometricAuthenticating

    init(preferences: ProfilePreferencesController, authenticator: any BiometricAuthenticating) {
        self.preferences = preferences
        self.authenticator = authenticator
        isLocked = preferences.appLockEnabled
    }

    var isEnabled: Bool { preferences.appLockEnabled }

    // [修改] 开关应用锁前先验证本人，避免未授权人员关闭或开启锁定。
    func setEnabled(_ enabled: Bool) async {
        guard enabled != preferences.appLockEnabled, !isChanging else { return }
        isChanging = true
        errorMessage = nil
        defer { isChanging = false }
        do {
            guard try await authenticator.authenticate(reason: enabled ? "开启 Chat Storage 应用锁" : "关闭 Chat Storage 应用锁") else {
                throw BiometricAuthenticationError.rejected
            }
            preferences.setAppLockEnabled(enabled)
            isLocked = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Face ID 验证失败"
        }
    }

    func lockIfNeeded() {
        if preferences.appLockEnabled { isLocked = true }
    }

    func unlock() async {
        guard preferences.appLockEnabled, !isChanging else {
            isLocked = false
            return
        }
        isChanging = true
        errorMessage = nil
        defer { isChanging = false }
        do {
            guard try await authenticator.authenticate(reason: "解锁 Chat Storage") else {
                throw BiometricAuthenticationError.rejected
            }
            isLocked = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Face ID 验证失败"
        }
    }

    func clearError() { errorMessage = nil }
}
