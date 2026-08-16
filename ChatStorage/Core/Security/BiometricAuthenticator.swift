import Foundation
import LocalAuthentication

protocol BiometricAuthenticating: Sendable {
    func authenticate(reason: String) async throws -> Bool
}

enum BiometricAuthenticationError: Error, LocalizedError, Sendable {
    case unavailable
    case rejected

    var errorDescription: String? {
        switch self {
        case .unavailable: "当前设备未配置 Face ID"
        case .rejected: "Face ID 验证未通过"
        }
    }
}

struct SystemBiometricAuthenticator: BiometricAuthenticating {
    func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError) else {
            throw BiometricAuthenticationError.unavailable
        }
        let accepted = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        guard accepted else { throw BiometricAuthenticationError.rejected }
        return true
    }
}
