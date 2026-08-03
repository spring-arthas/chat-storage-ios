import Foundation
import Observation

enum AppSessionState: Equatable, Sendable {
    case restoring
    case unauthenticated
    case authenticated(AuthenticatedUser)
}

@MainActor
@Observable
final class AppSession {
    private(set) var state: AppSessionState = .restoring
    let repository: any AuthRepository
    private var didRestore = false

    init(repository: any AuthRepository) {
        self.repository = repository
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        do {
            if let user = try await repository.resumeSession() {
                state = .authenticated(user)
            } else {
                state = .unauthenticated
            }
        } catch {
            state = .unauthenticated
        }
    }

    func authenticate(_ user: AuthenticatedUser) {
        state = .authenticated(user)
    }

    func logout() async {
        await repository.logout()
        state = .unauthenticated
    }
}
