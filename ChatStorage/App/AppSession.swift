import Foundation
import Network
import Observation

protocol NetworkAvailabilityMonitoring: Sendable {
    func start(_ handler: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

// [修改] 普通单元测试默认不启动系统网络监听，生产容器显式注入 NWPathMonitor。
struct DisabledNetworkAvailabilityMonitor: NetworkAvailabilityMonitoring {
    func start(_ handler: @escaping @Sendable (Bool) -> Void) {}
    func cancel() {}
}

// [修改] 监听 Wi-Fi/蜂窝链路恢复，恢复时立刻打断旧退避并重新绑定会话。
final class NWPathAvailabilityMonitor: NetworkAvailabilityMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.alibaba.chatstorage.network-path")
    private let lock = NSLock()
    private var started = false

    func start(_ handler: @escaping @Sendable (Bool) -> Void) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { path in
            handler(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

enum AppSessionState: Equatable, Sendable {
    case restoring
    case loggingOut
    case unauthenticated
    case authenticated(AuthenticatedUser)
}

@MainActor
@Observable
final class AppSession {
    private enum ReconnectAttemptResult {
        case retry
        case stop
    }

    private(set) var state: AppSessionState = .restoring
    private(set) var activationError: String?
    let repository: any AuthRepository
    private let transferTokenRefreshLeadTime: TimeInterval
    private let refreshRetryDelay: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let reconnectDelays: [TimeInterval]
    private let networkMonitor: any NetworkAvailabilityMonitoring
    private var didRestore = false
    private var isRestoring = false
    private var isActivating = false
    private var tokenRefreshTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var activationIdentifier: UUID?
    private var sessionGeneration = 0
    private var reconnectGeneration = 0
    private var networkAvailable: Bool?

    init(
        repository: any AuthRepository,
        transferTokenRefreshLeadTime: TimeInterval = 5 * 60,
        refreshRetryDelay: TimeInterval = 60,
        heartbeatInterval: TimeInterval = 30,
        reconnectDelays: [TimeInterval] = [0, 1, 2, 5, 10, 30],
        networkMonitor: any NetworkAvailabilityMonitoring = DisabledNetworkAvailabilityMonitor()
    ) {
        self.repository = repository
        self.transferTokenRefreshLeadTime = max(0, transferTokenRefreshLeadTime)
        self.refreshRetryDelay = max(0.05, refreshRetryDelay)
        self.heartbeatInterval = max(0.01, heartbeatInterval)
        self.reconnectDelays = reconnectDelays.isEmpty
            ? [0, 1, 2, 5, 10, 30]
            : reconnectDelays.map { max(0, $0) }
        self.networkMonitor = networkMonitor
        networkMonitor.start { [weak self] isAvailable in
            Task { @MainActor in
                self?.handleNetworkAvailability(isAvailable)
            }
        }
    }

    func restore() async {
        guard !didRestore, !isRestoring else { return }
        let generation = sessionGeneration
        didRestore = true
        isRestoring = true
        defer { isRestoring = false }
        do {
            if let user = try await repository.resumeSession() {
                // [修改] 慢恢复期间手动登录会推进 generation，迟到结果只能丢弃。
                guard generation == sessionGeneration, state == .restoring else { return }
                sessionGeneration += 1
                applyAuthenticatedUser(user)
            } else {
                guard generation == sessionGeneration, state == .restoring else { return }
                becomeUnauthenticated()
            }
        } catch {
            guard generation == sessionGeneration, state == .restoring else { return }
            becomeUnauthenticated()
        }
    }

    func authenticate(_ user: AuthenticatedUser) {
        // [修改] 旧容器 shutdown 未完成时拒绝新登录结果，避免被随后 close/logout 覆盖。
        guard state != .loggingOut else { return }
        didRestore = true
        // [修改] 新登录使旧 activate 结果失效，不能覆盖新账号会话。
        sessionGeneration += 1
        cancelActivation()
        applyAuthenticatedUser(user)
    }

    // [修改] 资料更新只替换当前同账号会话，退出后到达的迟到回调不能把用户重新登录。
    func updateAuthenticatedUser(_ user: AuthenticatedUser) {
        guard case .authenticated(let currentUser) = state,
              currentUser.id == user.id else { return }
        applyAuthenticatedUser(user)
    }

    // [修改] 首次前台进入恢复本地会话，后续前台进入统一重连并刷新登录/传输令牌。
    func resumeForForeground() async {
        if !didRestore {
            await restore()
        } else if !isRestoring {
            await activate()
        }
    }

    func activate() async {
        guard case .authenticated = state, !isRestoring, !isActivating else { return }
        let generation = sessionGeneration
        let identifier = UUID()
        isActivating = true
        // [修改] 前台和定时刷新 0x46 都纳入可取消任务，logout 会等待它真正退出。
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performActivation(generation: generation)
        }
        activationIdentifier = identifier
        activationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishActivation(identifier)
    }

    private func performActivation(generation: Int) async {
        do {
            guard let user = try await repository.activate() else {
                guard generation == sessionGeneration, case .authenticated = state else { return }
                becomeUnauthenticated()
                return
            }
            try Task.checkCancellation()
            // [修改] logout 或新登录会推进 generation，迟到的 0x46 结果只能丢弃。
            guard generation == sessionGeneration, case .authenticated = state else { return }
            applyAuthenticatedUser(user)
        } catch is CancellationError {
            return
        } catch let error as AuthError {
            guard generation == sessionGeneration, case .authenticated = state else { return }
            if case .sessionExpired = error {
                becomeUnauthenticated()
            } else {
                activationError = error.errorDescription
                scheduleRefreshRetry()
            }
        } catch {
            guard generation == sessionGeneration, case .authenticated = state else { return }
            activationError = error.localizedDescription
            scheduleRefreshRetry()
        }
    }

    private func finishActivation(_ identifier: UUID) {
        guard activationIdentifier == identifier else { return }
        activationTask = nil
        activationIdentifier = nil
        isActivating = false
    }

    func logout() async {
        await beginLogout()
        completeLogout()
    }

    // [修改] 容器关闭期间保持 loggingOut，客户端完全 close 前不开放登录入口。
    func beginLogout() async {
        // [修改] 先推进会话代次，任何已经发出的 0x46 都不能再写回认证状态。
        sessionGeneration += 1
        // [修改] 先进入退出门禁并取消所有后台网络任务，迟到回调不能恢复旧会话。
        let cancelledTasks = cancelNetworkTasksForLogout()
        activationError = nil
        state = .loggingOut
        // [修改] 等心跳、令牌刷新和 0x46 重连任务真正退出后，再发送登出请求。
        for task in cancelledTasks {
            await task.value
        }
        await repository.logout()
    }

    // [修改] 切换服务器只冻结旧会话任务，不发送远端 logout，也不清除本地会话令牌。
    func beginConfigurationChange() async {
        sessionGeneration += 1
        let cancelledTasks = cancelNetworkTasksForLogout()
        activationError = nil
        state = .loggingOut
        for task in cancelledTasks {
            await task.value
        }
    }

    // [修改] 远端登出和旧 Socket close 都完成后，才允许界面进入登录态。
    func completeLogout() {
        guard state == .loggingOut else { return }
        state = .unauthenticated
    }

    private func applyAuthenticatedUser(_ user: AuthenticatedUser) {
        activationError = nil
        state = .authenticated(user)
        scheduleTokenRefresh(for: user)
        startHeartbeat()
    }

    private func becomeUnauthenticated() {
        sessionGeneration += 1
        cancelNetworkTasks()
        activationError = nil
        state = .unauthenticated
    }

    private func scheduleTokenRefresh(for user: AuthenticatedUser) {
        cancelScheduledRefresh()
        guard let expiresAt = TransferTokenExpiration.expirationDate(from: user.transferToken) else { return }
        let delay = max(0.05, expiresAt.timeIntervalSinceNow - transferTokenRefreshLeadTime)
        tokenRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.scheduledRefreshDidFire()
        }
    }

    private func scheduleRefreshRetry() {
        cancelScheduledRefresh()
        guard case .authenticated = state else { return }
        let delay = refreshRetryDelay
        tokenRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.scheduledRefreshDidFire()
        }
    }

    private func scheduledRefreshDidFire() async {
        // [修改] 刷新任务在整个 activate 结束前保持可见，logout 才能取消并等待完整调用链。
        await activate()
    }

    private func startHeartbeat() {
        cancelHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(self.heartbeatInterval))
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await self.sendHeartbeat() else { return }
            }
        }
    }

    private func sendHeartbeat() async -> Bool {
        guard case .authenticated = state, reconnectTask == nil else { return false }
        do {
            try await repository.heartbeat()
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            activationError = error.localizedDescription
            // [修改] 心跳只说明当前 Socket 失效，必须重连后再走 0x46，不能直接沿用登录态。
            startReconnect(forceImmediate: true, restartExisting: false)
            return false
        }
    }

    private func startReconnect(forceImmediate: Bool, restartExisting: Bool) {
        guard case .authenticated = state else { return }
        if reconnectTask != nil, !restartExisting { return }
        cancelHeartbeat()
        cancelScheduledRefresh()
        cancelReconnect()
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                let configuredDelay = self.reconnectDelays[min(attempt, self.reconnectDelays.count - 1)]
                let delay = forceImmediate && attempt == 0 ? 0 : configuredDelay
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                        try Task.checkCancellation()
                    } catch {
                        return
                    }
                }
                guard self.isCurrentReconnect(generation) else { return }
                if await self.performReconnectAttempt(generation: generation) == .stop { return }
                attempt += 1
            }
        }
    }

    private func performReconnectAttempt(generation: Int) async -> ReconnectAttemptResult {
        guard generation == reconnectGeneration, case .authenticated = state else { return .stop }
        guard !isRestoring, !isActivating else { return .retry }
        isActivating = true
        defer { isActivating = false }
        do {
            // [修改] 每次退避尝试都先销毁旧 TCP/TLS，不能在表面 ready 的坏连接上发送 0x46。
            try await repository.reconnect()
            try Task.checkCancellation()
            let user = try await repository.activate()
            // [修改] 旧代次忽略取消并迟到返回 nil 时，只能丢弃，不能注销新会话。
            try Task.checkCancellation()
            guard generation == reconnectGeneration, case .authenticated = state else { return .stop }
            guard let user else {
                becomeUnauthenticated()
                return .stop
            }
            reconnectTask = nil
            applyAuthenticatedUser(user)
            return .stop
        } catch let error as AuthError {
            guard generation == reconnectGeneration else { return .stop }
            if case .sessionExpired = error {
                becomeUnauthenticated()
                return .stop
            }
            activationError = error.errorDescription
            return .retry
        } catch {
            guard generation == reconnectGeneration else { return .stop }
            activationError = error.localizedDescription
            return .retry
        }
    }

    private func isCurrentReconnect(_ generation: Int) -> Bool {
        generation == reconnectGeneration && reconnectTask != nil
    }

    private func handleNetworkAvailability(_ isAvailable: Bool) {
        let previous = networkAvailable
        networkAvailable = isAvailable
        guard previous == false, isAvailable, case .authenticated = state else { return }
        // [修改] 网络恢复事件优先级最高，立即替换正在等待的 1/2/5/10/30 秒退避任务。
        startReconnect(forceImmediate: true, restartExisting: true)
    }

    private func cancelNetworkTasks() {
        cancelScheduledRefresh()
        cancelHeartbeat()
        cancelReconnect()
    }

    private func cancelNetworkTasksForLogout() -> [Task<Void, Never>] {
        let tasks = [tokenRefreshTask, heartbeatTask, reconnectTask, activationTask].compactMap { $0 }
        tokenRefreshTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        activationTask = nil
        activationIdentifier = nil
        isActivating = false
        reconnectGeneration += 1
        tasks.forEach { $0.cancel() }
        return tasks
    }

    private func cancelHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func cancelReconnect() {
        reconnectGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func cancelScheduledRefresh() {
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
    }

    private func cancelActivation() {
        activationTask?.cancel()
        activationTask = nil
        activationIdentifier = nil
        isActivating = false
    }
}
