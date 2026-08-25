import AVFoundation
import AVKit
import CoreTransferable
import Foundation
import ImageIO
import Observation
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// [修改] 把系统刷新控件替换为可测试的下拉状态机，松手后只触发一次当前目录刷新。
struct DrivePullRefreshState {
    let triggerDistance: CGFloat
    private var isArmed = false
    private var hasTriggeredCurrentGesture = false

    init(triggerDistance: CGFloat = 72) {
        self.triggerDistance = triggerDistance
    }

    mutating func update(pullDistance: CGFloat, isRefreshing: Bool) {
        if isRefreshing {
            isArmed = false
        } else if !hasTriggeredCurrentGesture, pullDistance >= triggerDistance {
            isArmed = true
        }
    }

    mutating func shouldTriggerRefresh(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) -> Bool {
        if newPhase == .tracking {
            isArmed = false
            hasTriggeredCurrentGesture = false
            return false
        }
        // [修改] 内容不足一屏时系统会从 tracking 直接回 idle，不能只接受 interacting 结束。
        let wasUserDriven = oldPhase == .tracking || oldPhase == .interacting || oldPhase == .decelerating
        let remainsUserDriven = newPhase == .tracking || newPhase == .interacting
        guard wasUserDriven, !remainsUserDriven, isArmed else { return false }
        isArmed = false
        hasTriggeredCurrentGesture = true
        return true
    }
}

// [修改] 把播放器时间和按钮语义独立成纯状态，避免 NaN 时长直接进入 Slider 导致布局或拖动异常。
struct DriveVideoPlaybackState: Equatable {
    private(set) var currentTime: TimeInterval
    private(set) var duration: TimeInterval
    private(set) var isPlaying: Bool

    init(currentTime: TimeInterval = 0, duration: TimeInterval = 0, isPlaying: Bool = false) {
        self.duration = Self.normalized(duration)
        self.currentTime = min(Self.normalized(currentTime), self.duration)
        self.isPlaying = isPlaying
    }

    var sliderUpperBound: TimeInterval { max(duration, 1) }

    var isAtEnd: Bool {
        duration > 0 && currentTime >= duration - 0.25
    }

    mutating func play() { isPlaying = true }

    mutating func pause() { isPlaying = false }

    mutating func stop() {
        isPlaying = false
        currentTime = 0
    }

    mutating func seek(to value: TimeInterval) {
        currentTime = min(max(Self.normalized(value), 0), duration)
    }

    mutating func synchronize(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        self.duration = Self.normalized(duration)
        self.currentTime = min(Self.normalized(currentTime), self.duration)
        self.isPlaying = isPlaying
    }

    private static func normalized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 0
    }
}

// 网盘预览必须按播放器解析出的展示尺寸布局。把所有视频固定在 16:9 容器中会让竖屏相册视频
// 在 AVPlayerLayer 的等比显示模式下被大幅缩小；仅在尚未拿到媒体尺寸时才使用 16:9 占位。
enum DriveVideoLayout {
    static let fallbackAspectRatio: CGFloat = 16 / 9

    static func aspectRatio(for presentationSize: CGSize) -> CGFloat {
        guard presentationSize.width.isFinite,
              presentationSize.height.isFinite,
              presentationSize.width > 0,
              presentationSize.height > 0 else {
            return fallbackAspectRatio
        }
        return presentationSize.width / presentationSize.height
    }
}

enum DriveVideoPlaybackPhase: Equatable {
    case idle
    case loading
    case ready
    case waiting
    case ended
    case failed(String)
}

enum DriveVideoPlayerEvent: Equatable {
    case ready(duration: TimeInterval)
    case time(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool)
    case waiting
    case ended
    case failed(String)
}

@MainActor
protocol DriveVideoPlayerEngine: AnyObject {
    var player: AVPlayer? { get }
    func setEventHandler(_ handler: @escaping (DriveVideoPlayerEvent) -> Void)
    func play()
    func pause()
    func seek(to seconds: TimeInterval, tolerance: TimeInterval) async
    func invalidate()
}

@MainActor
protocol DriveVideoPlayerEngineFactory: AnyObject {
    func makeEngine(url: URL) throws -> any DriveVideoPlayerEngine
}

// [修改] 播放器控制器统一处理 URL 续签、失败恢复、单次 seek 和播放状态，SwiftUI 只负责布局。
@MainActor
@Observable
final class DriveVideoPlaybackController {
    private(set) var playbackState = DriveVideoPlaybackState()
    private(set) var phase: DriveVideoPlaybackPhase = .idle
    private(set) var isScrubbing = false
    private(set) var player: AVPlayer?

    @ObservationIgnored private let engineFactory: any DriveVideoPlayerEngineFactory
    @ObservationIgnored private let refreshPlayback: (@MainActor () async throws -> MediaPlayback)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var currentURL: URL
    @ObservationIgnored private var needsInitialRefresh = false
    @ObservationIgnored private var expiresAt: Date?
    @ObservationIgnored private var refreshLeadTime: TimeInterval = 0
    @ObservationIgnored private var engine: (any DriveVideoPlayerEngine)?
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var sourceGeneration: UInt64 = 0
    @ObservationIgnored private var installGeneration: UInt64 = 0
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var commandGeneration: UInt64 = 0
    @ObservationIgnored private var resumesAfterScrubbing = false
    @ObservationIgnored private var failureRefreshAttempted = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        url: URL,
        engineFactory: any DriveVideoPlayerEngineFactory = PinnedDriveVideoPlayerEngineFactory(),
        now: @escaping () -> Date = Date.init
    ) {
        currentURL = url
        self.engineFactory = engineFactory
        refreshPlayback = nil
        self.now = now
    }

    init(
        playback: MediaPlayback,
        engineFactory: any DriveVideoPlayerEngineFactory = PinnedDriveVideoPlayerEngineFactory(),
        refreshPlayback: @escaping @MainActor () async throws -> MediaPlayback,
        now: @escaping () -> Date = Date.init
    ) {
        currentURL = playback.playURL
        self.engineFactory = engineFactory
        self.refreshPlayback = refreshPlayback
        self.now = now
        applyExpiry(playback.expiresInSeconds)
    }

    init(
        refreshPlayback: @escaping @MainActor () async throws -> MediaPlayback,
        engineFactory: any DriveVideoPlayerEngineFactory = PinnedDriveVideoPlayerEngineFactory(),
        now: @escaping () -> Date = Date.init
    ) {
        // The actual URL is supplied by the first playback-address request.
        currentURL = URL(string: "https://127.0.0.1/")!
        self.engineFactory = engineFactory
        self.refreshPlayback = refreshPlayback
        self.now = now
        needsInitialRefresh = true
    }

    func start(autoplay: Bool) async {
        guard engine == nil else { return }
        let command = commandGeneration
        if needsInitialRefresh {
            await refreshSource(resumesPlayback: autoplay, expectedCommandGeneration: command)
            return
        }
        if refreshPlayback != nil,
           let expiresAt,
           now().addingTimeInterval(refreshLeadTime) >= expiresAt {
            await refreshSource(resumesPlayback: autoplay, expectedCommandGeneration: command)
            return
        }
        await installEngine(
            url: currentURL,
            restoringTime: 0,
            resumesPlayback: autoplay,
            expectedCommandGeneration: command
        )
    }

    func togglePlayback() async {
        commandGeneration &+= 1
        let command = commandGeneration
        if playbackState.isPlaying {
            engine?.pause()
            playbackState.pause()
            if phase != .idle, !isFailed { phase = .ready }
            return
        }
        await ensureFreshSourceIfNeeded(expectedCommandGeneration: command)
        guard commandGeneration == command, engine != nil, !isFailed else { return }
        if playbackState.isAtEnd {
            playbackState.seek(to: 0)
            await seekEngine(to: 0)
            guard commandGeneration == command else { return }
        }
        engine?.play()
        playbackState.play()
        if phase == .ended { phase = .ready }
    }

    func stop() async {
        commandGeneration &+= 1
        seekGeneration &+= 1
        let generation = seekGeneration
        resumesAfterScrubbing = false
        isScrubbing = true
        engine?.pause()
        playbackState.stop()
        await engine?.seek(to: 0, tolerance: 0.1)
        guard seekGeneration == generation else { return }
        isScrubbing = false
        if !isFailed { phase = .ready }
    }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        commandGeneration &+= 1
        seekGeneration &+= 1
        resumesAfterScrubbing = playbackState.isPlaying
        isScrubbing = true
        engine?.pause()
        playbackState.pause()
    }

    func updateScrubbing(to seconds: TimeInterval) {
        if !isScrubbing { beginScrubbing() }
        playbackState.seek(to: seconds)
    }

    func endScrubbing() async {
        guard isScrubbing else { return }
        commandGeneration &+= 1
        let command = commandGeneration
        seekGeneration &+= 1
        let generation = seekGeneration
        let target = playbackState.currentTime
        let shouldResume = resumesAfterScrubbing
        resumesAfterScrubbing = false
        await ensureFreshSourceIfNeeded(expectedCommandGeneration: command)
        guard commandGeneration == command, engine != nil, !isFailed else {
            isScrubbing = false
            return
        }
        await engine?.seek(to: target, tolerance: 0.1)
        guard commandGeneration == command, seekGeneration == generation else { return }
        playbackState.seek(to: target)
        isScrubbing = false
        if shouldResume {
            engine?.play()
            playbackState.play()
        }
    }

    func retry() async {
        commandGeneration &+= 1
        let command = commandGeneration
        failureRefreshAttempted = false
        if refreshPlayback != nil {
            await refreshSource(resumesPlayback: true, expectedCommandGeneration: command)
        } else {
            await installEngine(
                url: currentURL,
                restoringTime: playbackState.currentTime,
                resumesPlayback: playbackState.isPlaying,
                expectedCommandGeneration: command
            )
        }
    }

    func invalidate() {
        // [修改] 关闭预览后让所有挂起的续签、换源和拖动结果立即失效，不能再次复活播放器。
        lifecycleGeneration &+= 1
        sourceGeneration &+= 1
        installGeneration &+= 1
        seekGeneration &+= 1
        refreshGeneration &+= 1
        commandGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        engine?.invalidate()
        engine = nil
        player = nil
        playbackState.stop()
        resumesAfterScrubbing = false
        failureRefreshAttempted = false
        isScrubbing = false
        phase = .idle
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func ensureFreshSourceIfNeeded(expectedCommandGeneration: UInt64) async {
        guard let expiresAt,
              now().addingTimeInterval(refreshLeadTime) >= expiresAt else { return }
        await refreshSource(
            resumesPlayback: false,
            expectedCommandGeneration: expectedCommandGeneration
        )
    }

    private func refreshSource(
        resumesPlayback: Bool,
        expectedLifecycleGeneration: UInt64? = nil,
        expectedCommandGeneration: UInt64? = nil,
        expectedRefreshGeneration: UInt64? = nil
    ) async {
        let lifecycle = expectedLifecycleGeneration ?? lifecycleGeneration
        let command = expectedCommandGeneration ?? commandGeneration
        let refresh: UInt64
        if let expectedRefreshGeneration {
            refresh = expectedRefreshGeneration
        } else {
            refreshTask?.cancel()
            refreshTask = nil
            refreshGeneration &+= 1
            refresh = refreshGeneration
        }
        guard lifecycleGeneration == lifecycle,
              commandGeneration == command,
              refreshGeneration == refresh,
              !Task.isCancelled,
              let refreshPlayback else { return }
        phase = .loading
        do {
            let playback = try await refreshPlayback()
            guard lifecycleGeneration == lifecycle,
                  refreshGeneration == refresh,
                  !Task.isCancelled else { return }
            guard commandGeneration == command else {
                if phase == .loading, engine != nil {
                    phase = .ready
                }
                return
            }
            currentURL = playback.playURL
            needsInitialRefresh = false
            applyExpiry(playback.expiresInSeconds)
            await installEngine(
                url: playback.playURL,
                restoringTime: playbackState.currentTime,
                resumesPlayback: resumesPlayback,
                expectedLifecycleGeneration: lifecycle,
                expectedCommandGeneration: command,
                expectedRefreshGeneration: refresh
            )
        } catch {
            guard lifecycleGeneration == lifecycle,
                  commandGeneration == command,
                  refreshGeneration == refresh,
                  !Task.isCancelled else { return }
            playbackState.pause()
            phase = .failed(error.localizedDescription.isEmpty ? "视频播放地址刷新失败" : error.localizedDescription)
        }
    }

    private func installEngine(
        url: URL,
        restoringTime: TimeInterval,
        resumesPlayback: Bool,
        expectedLifecycleGeneration: UInt64? = nil,
        expectedCommandGeneration: UInt64? = nil,
        expectedRefreshGeneration: UInt64? = nil
    ) async {
        let lifecycle = expectedLifecycleGeneration ?? lifecycleGeneration
        let command = expectedCommandGeneration ?? commandGeneration
        installGeneration &+= 1
        let installation = installGeneration
        guard lifecycleGeneration == lifecycle,
              commandGeneration == command,
              expectedRefreshGeneration.map({ refreshGeneration == $0 }) ?? true,
              !Task.isCancelled else { return }
        do {
            phase = .loading
            let nextEngine = try engineFactory.makeEngine(url: url)
            guard lifecycleGeneration == lifecycle,
                  commandGeneration == command,
                  installGeneration == installation,
                  expectedRefreshGeneration.map({ refreshGeneration == $0 }) ?? true,
                  !Task.isCancelled else {
                nextEngine.invalidate()
                return
            }
            if restoringTime > 0 {
                await nextEngine.seek(to: restoringTime, tolerance: 0.1)
                guard lifecycleGeneration == lifecycle,
                      commandGeneration == command,
                      installGeneration == installation,
                      expectedRefreshGeneration.map({ refreshGeneration == $0 }) ?? true,
                      !Task.isCancelled else {
                    nextEngine.invalidate()
                    return
                }
            }
            sourceGeneration &+= 1
            let source = sourceGeneration
            engine?.invalidate()
            engine = nextEngine
            player = nextEngine.player
            nextEngine.setEventHandler { [weak self] event in
                guard let self,
                      self.lifecycleGeneration == lifecycle,
                      self.sourceGeneration == source else { return }
                self.handle(event)
            }
            if restoringTime > 0 { playbackState.seek(to: restoringTime) }
            if resumesPlayback {
                nextEngine.play()
                playbackState.play()
            } else {
                playbackState.pause()
            }
        } catch {
            guard lifecycleGeneration == lifecycle,
                  commandGeneration == command,
                  installGeneration == installation,
                  expectedRefreshGeneration.map({ refreshGeneration == $0 }) ?? true,
                  !Task.isCancelled else { return }
            sourceGeneration &+= 1
            engine?.invalidate()
            engine = nil
            player = nil
            playbackState.pause()
            // [修改] 连不上时把目标流地址带出来，便于真机判断连的是哪种主机。
            let base = error.localizedDescription.isEmpty ? "视频加载失败" : error.localizedDescription
            phase = .failed("\(base)\n\(url.absoluteString)")
        }
    }

    private func seekEngine(to seconds: TimeInterval) async {
        seekGeneration &+= 1
        let generation = seekGeneration
        await engine?.seek(to: seconds, tolerance: 0.1)
        guard seekGeneration == generation else { return }
        playbackState.seek(to: seconds)
    }

    private func handle(_ event: DriveVideoPlayerEvent) {
        switch event {
        case .ready(let duration):
            failureRefreshAttempted = false
            playbackState.synchronize(
                currentTime: playbackState.currentTime,
                duration: duration,
                isPlaying: playbackState.isPlaying
            )
            phase = .ready
        case .time(let currentTime, let duration, let isPlaying):
            if isScrubbing {
                playbackState.synchronize(
                    currentTime: playbackState.currentTime,
                    duration: duration,
                    isPlaying: false
                )
            } else {
                playbackState.synchronize(
                    currentTime: currentTime,
                    duration: duration,
                    isPlaying: isPlaying
                )
            }
            if phase == .loading || phase == .waiting { phase = .ready }
            scheduleRefreshIfNeeded()
        case .waiting:
            if !isFailed { phase = .waiting }
        case .ended:
            // [修改] 自然播放结束是新的用户可见终态，作废结束前仍在等待的续签和播放命令。
            commandGeneration &+= 1
            playbackState.pause()
            playbackState.seek(to: playbackState.duration)
            phase = .ended
        case .failed(let message):
            let shouldResume = playbackState.isPlaying && !isScrubbing
            playbackState.pause()
            guard refreshPlayback != nil, !failureRefreshAttempted else {
                phase = .failed(message.isEmpty ? "视频播放失败" : message)
                return
            }
            failureRefreshAttempted = true
            refreshTask?.cancel()
            refreshGeneration &+= 1
            let scheduledRefreshGeneration = refreshGeneration
            let scheduledLifecycleGeneration = lifecycleGeneration
            let scheduledCommandGeneration = commandGeneration
            refreshTask = Task { [weak self] in
                guard let self else { return }
                await self.refreshSource(
                    resumesPlayback: shouldResume,
                    expectedLifecycleGeneration: scheduledLifecycleGeneration,
                    expectedCommandGeneration: scheduledCommandGeneration,
                    expectedRefreshGeneration: scheduledRefreshGeneration
                )
                guard self.lifecycleGeneration == scheduledLifecycleGeneration,
                      self.refreshGeneration == scheduledRefreshGeneration else { return }
                self.refreshTask = nil
            }
        }
    }

    private func scheduleRefreshIfNeeded() {
        guard refreshTask == nil,
              let expiresAt,
              now().addingTimeInterval(refreshLeadTime) >= expiresAt else { return }
        let shouldResume = playbackState.isPlaying
        refreshGeneration &+= 1
        let scheduledRefreshGeneration = refreshGeneration
        let scheduledLifecycleGeneration = lifecycleGeneration
        let scheduledCommandGeneration = commandGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshSource(
                resumesPlayback: shouldResume,
                expectedLifecycleGeneration: scheduledLifecycleGeneration,
                expectedCommandGeneration: scheduledCommandGeneration,
                expectedRefreshGeneration: scheduledRefreshGeneration
            )
            guard self.lifecycleGeneration == scheduledLifecycleGeneration,
                  self.refreshGeneration == scheduledRefreshGeneration else { return }
            self.refreshTask = nil
        }
    }

    private func applyExpiry(_ seconds: Int64) {
        let lifetime = max(TimeInterval(seconds), 0)
        expiresAt = now().addingTimeInterval(lifetime)
        refreshLeadTime = min(15, max(1, lifetime / 10))
    }
}

@MainActor
final class PinnedDriveVideoPlayerEngineFactory: DriveVideoPlayerEngineFactory {
    func makeEngine(url: URL) throws -> any DriveVideoPlayerEngine {
        try AVPlayerDriveVideoEngine(url: url)
    }
}

@MainActor
private final class AVPlayerDriveVideoEngine: DriveVideoPlayerEngine {
    let player: AVPlayer?
    private let retainedAsset: PinnedMediaAsset?
    private var eventHandler: ((DriveVideoPlayerEvent) -> Void)?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastDiagnosticWallTime: TimeInterval?
    private var lastDiagnosticMediaTime: TimeInterval?
    private var didPublishTrackDiagnostics = false

    init(url: URL) throws {
        let player: AVPlayer
        if url.isFileURL {
            retainedAsset = nil
            player = AVPlayer(url: url)
        } else {
            guard let asset = PinnedMediaAsset(url: url) else {
                throw MediaRepositoryError.invalidResponse
            }
            retainedAsset = asset
            player = asset.makePlayer()
        }
        self.player = player
        print("[PlayerDiag] engine-created url=\(Self.redactedURL(url))")
        observe(player)
    }

    func setEventHandler(_ handler: @escaping (DriveVideoPlayerEvent) -> Void) {
        eventHandler = handler
        publishItemStatus()
        publishTimeControlStatus()
    }

    func play() {
        print("[PlayerDiag] command=play current=\(Self.seconds(player?.currentTime().seconds))")
        player?.play()
    }

    func pause() {
        print("[PlayerDiag] command=pause current=\(Self.seconds(player?.currentTime().seconds))")
        player?.pause()
    }

    func seek(to seconds: TimeInterval, tolerance: TimeInterval) async {
        guard let player else { return }
        print("[PlayerDiag] command=seek target=\(Self.seconds(seconds)) tolerance=\(Self.seconds(tolerance))")
        let target = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        let toleranceTime = CMTime(seconds: max(tolerance, 0), preferredTimescale: 600)
        await withCheckedContinuation { continuation in
            player.seek(to: target, toleranceBefore: toleranceTime, toleranceAfter: toleranceTime) { _ in
                continuation.resume()
            }
        }
    }

    func invalidate() {
        print("[PlayerDiag] engine-invalidated current=\(Self.seconds(player?.currentTime().seconds))")
        itemStatusObservation = nil
        timeControlObservation = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        eventHandler = nil
    }

    private func observe(_ player: AVPlayer) {
        if let item = player.currentItem {
            itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.publishItemStatus() }
            }
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.eventHandler?(.ended) }
            })
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                    ?? "视频播放失败"
                Task { @MainActor [weak self] in self?.eventHandler?(.failed(message)) }
            })
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishPlaybackStalled() }
            })
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishAccessLog() }
            })
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewErrorLogEntry,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishErrorLog() }
            })
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publishTimeControlStatus() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.publishPeriodicDiagnostics(time: time, player: player)
                self.eventHandler?(.time(
                    currentTime: time.seconds,
                    duration: player.currentItem?.duration.seconds ?? 0,
                    isPlaying: player.rate > 0
                ))
            }
        }
    }

    private func publishItemStatus() {
        guard let item = player?.currentItem else { return }
        print("[PlayerDiag] item-status=\(Self.itemStatus(item.status)) duration=\(Self.seconds(item.duration.seconds)) error=\(item.error?.localizedDescription ?? "none")")
        switch item.status {
        case .readyToPlay:
            eventHandler?(.ready(duration: item.duration.seconds))
            publishTrackDiagnosticsIfNeeded(item: item)
        case .failed:
            eventHandler?(.failed(item.error?.localizedDescription ?? "视频加载失败"))
        case .unknown:
            break
        @unknown default:
            eventHandler?(.failed("视频播放器状态异常"))
        }
    }

    private func publishTimeControlStatus() {
        guard let player else { return }
        let waitingReason = player.reasonForWaitingToPlay?.rawValue ?? "none"
        print("[PlayerDiag] time-control=\(Self.timeControlStatus(player.timeControlStatus)) rate=\(Self.seconds(Double(player.rate))) waiting=\(waitingReason)")
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            eventHandler?(.waiting)
        }
    }

    private func publishPeriodicDiagnostics(time: CMTime, player: AVPlayer) {
        let wallTime = Date.timeIntervalSinceReferenceDate
        let mediaTime = time.seconds
        guard mediaTime.isFinite else { return }
        guard let previousWall = lastDiagnosticWallTime,
              let previousMedia = lastDiagnosticMediaTime else {
            lastDiagnosticWallTime = wallTime
            lastDiagnosticMediaTime = mediaTime
            return
        }
        let wallDelta = wallTime - previousWall
        guard wallDelta >= 1 else { return }
        let effectiveRate = (mediaTime - previousMedia) / wallDelta
        lastDiagnosticWallTime = wallTime
        lastDiagnosticMediaTime = mediaTime
        let item = player.currentItem
        let bufferAhead = Self.bufferAhead(item: item, currentTime: mediaTime)
        let accessEvent = item?.accessLog()?.events.last
        print(
            "[PlayerDiag] tick media=\(Self.seconds(mediaTime)) wallDelta=\(Self.seconds(wallDelta)) "
                + "mediaDelta=\(Self.seconds(mediaTime - previousMedia)) effectiveRate=\(Self.seconds(effectiveRate)) "
                + "playerRate=\(Self.seconds(Double(player.rate))) control=\(Self.timeControlStatus(player.timeControlStatus)) "
                + "bufferAhead=\(Self.seconds(bufferAhead)) empty=\(item?.isPlaybackBufferEmpty ?? false) "
                + "likely=\(item?.isPlaybackLikelyToKeepUp ?? false) droppedFrames=\(accessEvent?.numberOfDroppedVideoFrames ?? -1)"
        )
    }

    private func publishTrackDiagnosticsIfNeeded(item: AVPlayerItem) {
        guard !didPublishTrackDiagnostics else { return }
        didPublishTrackDiagnostics = true
        Task { @MainActor in
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    print("[PlayerDiag] video-track=missing")
                    return
                }
                // Swift 6 下 AVAssetTrack 不是 Sendable，同一轨道的属性顺序读取，避免跨任务并发访问。
                let frameRate = try await track.load(.nominalFrameRate)
                let frameDuration = try await track.load(.minFrameDuration)
                let size = try await track.load(.naturalSize)
                let bitRate = try await track.load(.estimatedDataRate)
                let reordersFrames = try await track.load(.requiresFrameReordering)
                print(
                    "[PlayerDiag] video-track nominalFPS=\(Self.seconds(Double(frameRate))) "
                        + "minFrameDuration=\(Self.seconds(frameDuration.seconds)) "
                        + "size=\(Int(size.width))x\(Int(size.height)) "
                        + "estimatedBitrate=\(Self.seconds(Double(bitRate))) frameReordering=\(reordersFrames)"
                )
            } catch {
                print("[PlayerDiag] video-track-error=\(error.localizedDescription)")
            }
        }
    }

    private func publishPlaybackStalled() {
        guard let player else { return }
        print("[PlayerDiag] playback-stalled current=\(Self.seconds(player.currentTime().seconds)) bufferAhead=\(Self.seconds(Self.bufferAhead(item: player.currentItem, currentTime: player.currentTime().seconds)))")
    }

    private func publishAccessLog() {
        guard let event = player?.currentItem?.accessLog()?.events.last else { return }
        print(
            "[PlayerDiag] access requests=\(event.numberOfMediaRequests) stalls=\(event.numberOfStalls) "
                + "bytes=\(event.numberOfBytesTransferred) transfer=\(Self.seconds(event.transferDuration)) "
                + "indicatedBitrate=\(Self.seconds(event.indicatedBitrate)) observedBitrate=\(Self.seconds(event.observedBitrate)) "
                + "droppedFrames=\(event.numberOfDroppedVideoFrames) overdue=\(event.downloadOverdue)"
        )
    }

    private func publishErrorLog() {
        guard let event = player?.currentItem?.errorLog()?.events.last else { return }
        print("[PlayerDiag] error-log domain=\(event.errorDomain) status=\(event.errorStatusCode) comment=\(event.errorComment ?? "none")")
    }

    private static func bufferAhead(item: AVPlayerItem?, currentTime: TimeInterval) -> TimeInterval {
        guard currentTime.isFinite, let item else { return 0 }
        return item.loadedTimeRanges
            .map(\.timeRangeValue)
            .filter { $0.start.seconds <= currentTime + 0.1 && $0.end.seconds >= currentTime }
            .map { max(0, $0.end.seconds - currentTime) }
            .max() ?? 0
    }

    private static func timeControlStatus(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown"
        }
    }

    private static func itemStatus(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        @unknown default: "unknown"
        }
    }

    private static func seconds(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else { return "nan" }
        return String(format: "%.3f", value)
    }

    private static func redactedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        let originalQueryItems = components.queryItems
        components.queryItems = originalQueryItems?.map { item in
            switch item.name.lowercased() {
            case "token", "access_token", "signature": URLQueryItem(name: item.name, value: "<redacted>")
            default: item
            }
        }
        return components.string ?? "<invalid-url>"
    }
}

// [修改] 缩略图缓存键同时包含服务器、账号和远端文件，避免切服或换号后复用旧图。
struct DriveThumbnailCacheKey: Hashable, Sendable {
    let rawValue: String

    init(serverScopeID: String, userId: Int64, fileId: Int64) {
        rawValue = "\(serverScopeID)-\(userId)-\(fileId)"
    }
}

// [修改] iPhone 网盘页面统一承载目录、文件、预览、批量操作和传输中心入口。
struct DrivePlaceholderView: View {
    @State private var model: DriveViewModel
    @AppStorage("drive.displayMode") private var displayModeRawValue = DriveDisplayMode.list.rawValue
    @AppStorage("drive.downloadDirectoryBookmark") private var downloadDirectoryBookmarkBase64 = ""
    @State private var isSelecting = false
    @State private var showsDirectoryTree = false
    @State private var newDirectoryName = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var addPresentation = DriveAddPresentationState()
    @State private var renameEntry: DriveFileEntry?
    @State private var renameValue = ""
    @State private var deleteEntry: DriveFileEntry?
    @State private var movingDirectory: DriveFileEntry?
    @State private var movingFile: DriveFileEntry?
    @State private var detailEntry: DriveFileEntry?
    @State private var preview: DrivePreview?
    @State private var sharePayload: DriveSharePayload?
    @State private var showsBatchDeleteConfirmation = false
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var loadingThumbnailKeys: Set<String> = []
    @State private var pullRefreshState = DrivePullRefreshState()
    @State private var refreshUITestTriggerCount = 0
    @State private var activeUploadCount = 0

    private let transferStore: FileTransferTaskStore
    private let transferManager: (any DriveTransferManaging)?
    private let transferCenterManager: (any TransferManaging)?
    private let mediaRepository: (any MediaPlaybackProviding)?
    private let userId: Int64
    private let username: String
    private let serverScopeID: String
    private let thumbnailLoader: DriveThumbnailLoader
    private let dynamicComposerRouteStore: DynamicComposerRouteStore
    private let onOpenDynamicComposer: () -> Void

    init(
        repository: any DriveRepository,
        transferStore: FileTransferTaskStore = .shared,
        transferManager: (any DriveTransferManaging)? = nil,
        transferCenterManager: (any TransferManaging)? = nil,
        mediaRepository: (any MediaPlaybackProviding)? = nil,
        userId: Int64 = 0,
        username: String = "",
        serverScopeID: String = ServerConfiguration.default.storageScopeID,
        dynamicComposerRouteStore: DynamicComposerRouteStore = DynamicComposerRouteStore(),
        onOpenDynamicComposer: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: DriveViewModel(repository: repository, transferManager: transferManager))
        self.transferStore = transferStore
        self.transferManager = transferManager
        self.transferCenterManager = transferCenterManager
        self.mediaRepository = mediaRepository
        self.userId = userId
        self.username = username
        self.serverScopeID = serverScopeID
        self.dynamicComposerRouteStore = dynamicComposerRouteStore
        self.onOpenDynamicComposer = onOpenDynamicComposer
        self.thumbnailLoader = DriveThumbnailLoader(
            transferManager: transferManager,
            mediaRepository: mediaRepository,
            username: username
        )
    }

    private var displayMode: DriveDisplayMode {
        DriveDisplayMode(rawValue: displayModeRawValue) ?? .list
    }

    private var allVisibleSelected: Bool {
        !model.visibleEntries.isEmpty && model.visibleEntries.allSatisfy { model.selectedEntryIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack { configuredContent }
    }

    private var driveScrollView: some View {
        // [修改] 目录栏和传输中心留在固定区域，只有目录、文件列表参与滚动。
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                searchBar
                breadcrumbBar
                transferCenterLink
                smartCollectionsBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    driveContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, isSelecting ? 76 : 20)
            }
            .accessibilityIdentifier(displayMode == .grid ? "drive.grid" : "drive.list")
            // [修改] 空目录或内容不足一屏时也允许下拉，保证刷新入口始终可用。
            .scrollBounceBehavior(.always)
            .onScrollGeometryChange(
                for: CGFloat.self,
                of: { geometry in
                    max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
                },
                action: { _, pullDistance in
                    pullRefreshState.update(pullDistance: pullDistance, isRefreshing: model.isRefreshing)
                }
            )
            .onScrollPhaseChange { oldPhase, newPhase in
                let shouldRefresh = pullRefreshState.shouldTriggerRefresh(from: oldPhase, to: newPhase)
                guard shouldRefresh else { return }
                if ProcessInfo.processInfo.arguments.contains("-driveRefreshUITest") {
                    refreshUITestTriggerCount += 1
                }
                Task { await model.refreshCurrentDirectory() }
            }
            .overlay(alignment: .bottomTrailing) {
                if ProcessInfo.processInfo.arguments.contains("-driveRefreshUITest") {
                    Text("triggers=\(refreshUITestTriggerCount)")
                        .frame(width: 1, height: 1)
                        .clipped()
                        .accessibilityIdentifier("drive.refresh-trigger-count")
                }
            }
        }
    }

    private var interactiveContent: AnyView {
        AnyView(driveScrollView
            .navigationTitle(model.currentDirectory?.name ?? "网盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { driveToolbar })
    }

    private var lifecycleContent: AnyView {
        AnyView(interactiveContent
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar }
            }
            .overlay { loadingOverlay() }
            .task { await model.load() }
            .task {
                guard let transferManager else { return }
                for await event in transferManager.completionEvents where event.direction == .upload {
                    model.scheduleRefreshAfterTransferCompletion()
                }
            }
            .task { await observeTransfers() }
            .task(id: model.searchText) { await debounceSearch() })
    }

    // [修改] 订阅任务清单变化，驱动传输中心入口的红角标数量；每个订阅者取独立流避免抢占。
    private func observeTransfers() async {
        let initial = await transferStore.all()
        applyTransferSnapshot(initial)
        for await tasks in transferStore.taskStream() {
            applyTransferSnapshot(tasks)
        }
    }

    private func applyTransferSnapshot(_ tasks: [TransferTaskRecord]) {
        let owned = tasks.filter { $0.userId == userId && $0.serverScopeID == serverScopeID }
        activeUploadCount = owned.filter { $0.direction == .upload && $0.status.isExecuting }.count
    }

    private var configuredContent: some View {
        lifecycleContent
            .alert("新建文件夹", isPresented: addDestinationBinding(.createDirectory)) {
                TextField("文件夹名称", text: $newDirectoryName)
                Button("取消", role: .cancel) { newDirectoryName = "" }
                Button("新建") { createDirectory() }
                    .disabled(newDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sheet(
                isPresented: addSourcePickerBinding,
                onDismiss: { addPresentation.sourcePickerDidDismiss() }
            ) {
                DriveAddSourcePicker { destination in
                    guard destination == .photos else {
                        addPresentation.select(destination)
                        return
                    }
                    // 零副本视频依赖 Photos 本地资源标识，必须在展示选择器前获得读取授权；
                    // 授权后的 shared library picker 才会向 itemIdentifier 暴露该标识。
                    Task {
                        guard await DrivePhotoLibraryAccess.requestReadAccessIfNeeded() else {
                            model.reportError("需要相册访问权限才能直接上传本地视频")
                            return
                        }
                        addPresentation.select(.photos)
                    }
                }
            }
            .fileImporter(
                isPresented: addDestinationBinding(.files),
                allowedContentTypes: [.data],
                allowsMultipleSelection: true,
                onCompletion: handleImportResult
            )
            .photosPicker(
                isPresented: addDestinationBinding(.photos),
                selection: $selectedPhotos,
                matching: PHPickerFilter.any(of: [.images, .videos]),
                photoLibrary: .shared()
            )
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos = []
                Task { await importPickedMedia(items) }
            }
            .alert("重命名", isPresented: Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })) {
                TextField("名称", text: $renameValue)
                Button("取消", role: .cancel) { renameEntry = nil }
                Button("保存") { renameSelectedEntry() }
                    .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("确认删除", isPresented: Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } })) {
                Button("取消", role: .cancel) { deleteEntry = nil }
                Button("删除", role: .destructive) { deleteSelectedEntry() }
            } message: {
                // [修改] 目录删除会递归清理其中全部文件，确认文案必须把影响范围说清楚。
                Text("删除后无法恢复；如果是目录，目录内全部文件也会删除。确定删除“\(deleteEntry?.name ?? "此项目")”？")
            }
            .alert("确认批量删除", isPresented: $showsBatchDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { deleteSelectedEntries() }
            } message: {
                Text("将删除已选择的 \(model.selectedEntries.count) 个项目；所选目录内的全部文件也会删除。失败项目会保留，方便重试。")
            }
            .alert("网盘操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
                Button("知道了") { model.clearError() }
            } message: {
                Text(model.errorMessage ?? "请稍后重试")
            }
            .sheet(isPresented: $showsDirectoryTree) {
                DriveDirectoryPicker(
                    title: "选择文件夹",
                    roots: model.directoryRoots,
                    excludedIDs: [],
                    selectedID: model.currentDirectory?.id,
                    loadingDirectoryIDs: model.loadingDirectoryIDs,
                    onExpand: { await model.loadDirectoryChildren(id: $0) },
                    onSelect: { id in
                    showsDirectoryTree = false
                    Task { await model.selectDirectory(id: id) }
                    }
                )
            }
            .sheet(item: $movingDirectory) { directory in
                DriveDirectoryPicker(
                    title: "移动“\(directory.name)”",
                    roots: model.directoryRoots,
                    excludedIDs: model.invalidMoveTargetIDs(for: directory),
                    selectedID: directory.parentId,
                    loadingDirectoryIDs: model.loadingDirectoryIDs,
                    onExpand: { await model.loadDirectoryChildren(id: $0) },
                    onSelect: { targetID in
                    movingDirectory = nil
                    Task { await model.moveDirectory(directory, targetParentId: targetID) }
                    }
                )
            }
            .sheet(item: $movingFile) { file in
                DriveDirectoryPicker(
                    title: "移动“\(file.name)”",
                    roots: model.directoryRoots,
                    excludedIDs: model.invalidFileMoveTargetIDs(for: file),
                    selectedID: file.parentId,
                    loadingDirectoryIDs: model.loadingDirectoryIDs,
                    onExpand: { await model.loadDirectoryChildren(id: $0) },
                    onSelect: { targetID in
                        movingFile = nil
                        Task { await model.moveFile(file, targetParentId: targetID) }
                    }
                )
            }
            .sheet(item: $detailEntry) { DriveFileDetailView(entry: $0) }
            .sheet(item: $preview) { DrivePreviewView(preview: $0) }
            .sheet(item: $sharePayload) { payload in
                DriveShareSheet(items: payload.urls, access: payload.access)
            }
            .onChange(of: newDirectoryName) { _, value in
                // [修改] 新建目录输入体感与 macOS 一致，超过 10 个字时立即截断。
                if value.count > 10 { newDirectoryName = String(value.prefix(10)) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isSelecting {
                    addButton
                }
            }
    }

    // [修改] 大号 + 浮动在右下内容区，点击弹小框「添加」Sheet；选择模式下隐藏。
    private var addButton: some View {
        Button { addPresentation.showSourcePicker() } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(AppTheme.primaryGreen, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
        .accessibilityLabel("添加")
        .accessibilityIdentifier("drive.add")
    }

    private var addSourcePickerBinding: Binding<Bool> {
        Binding(
            get: { addPresentation.isSourcePickerPresented },
            set: { addPresentation.setSourcePickerPresented($0) }
        )
    }

    private func addDestinationBinding(_ destination: DriveAddDestination) -> Binding<Bool> {
        Binding(
            get: { addPresentation.presentedDestination == destination },
            set: { addPresentation.setDestinationPresented($0, destination: destination) }
        )
    }

    @ToolbarContentBuilder
    private var driveToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showsDirectoryTree = true } label: {
                Image(systemName: "filemenu.and.selection")
            }
            .accessibilityLabel("目录树")
            .accessibilityIdentifier("drive.tree")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { toggleSelectionMode() } label: {
                Image(systemName: isSelecting ? "checkmark.circle.fill" : "checklist")
            }
            .accessibilityLabel(isSelecting ? "退出选择" : "选择项目")
            .accessibilityIdentifier("drive.selection")

            Button { toggleDisplayMode() } label: {
                Image(systemName: displayMode == .list ? "square.grid.2x2" : "list.bullet")
            }
            .accessibilityLabel(displayMode == .list ? "切换网格" : "切换列表")
            .accessibilityIdentifier("drive.display-mode")
        }
    }

    // [修改] 用自定义搜索框替代系统 .searchable，后者会干扰 fileImporter/photosPicker 的系统弹层弹出。
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索当前目录", text: $model.searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("drive.search")
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            if model.path.count > 1 {
                Button { Task { await model.goBack() } } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("返回上级")
                .accessibilityIdentifier("drive.back")
            }
            Menu {
                ForEach(model.path) { directory in
                    Button {
                        Task { await model.selectDirectory(id: directory.id) }
                    } label: {
                        Label(directory.name, systemImage: directory.id == model.currentDirectory?.id ? "checkmark" : "folder")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                    Text(model.currentDirectory?.name ?? "网盘").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryGreen)
            }
            .accessibilityLabel("当前位置")
            .accessibilityIdentifier("drive.breadcrumb")
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在刷新当前目录")
                    .accessibilityIdentifier("drive.refresh-indicator")
            } else if ProcessInfo.processInfo.arguments.contains("-driveShowRefreshIndicator") {
                // [修改] UI 测试只固定验证指示位所在层级，真实动画仍只由 isRefreshing 驱动。
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityLabel("刷新指示位置")
                    .accessibilityIdentifier("drive.refresh-indicator")
            }
            Spacer()
            if model.totalCount > 0 {
                Text("\(model.files.count)/\(model.totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 32)
    }

    private var transferCenterLink: some View {
        NavigationLink {
            TransferCenterView(
                store: transferStore,
                manager: transferCenterManager,
                userId: userId,
                serverScopeID: serverScopeID
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.documentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("传输中心").font(.subheadline.weight(.semibold))
                    Text(activeUploadCount > 0 ? "\(activeUploadCount) 个任务正在上传" : "查看上传、下载、暂停和失败任务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if activeUploadCount > 0 {
                    // [修改] 待上传 + 上传中的任务数用红色角标标注。
                    Text("\(activeUploadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.red, in: Capsule())
                        .accessibilityIdentifier("drive.transfer-badge")
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drive.transfer-center")
    }

    // [修改] 集合栏属于固定顶部区域，滚动目录和文件时始终可见。
    private var smartCollectionsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DriveSmartCollection.allCases) { collection in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            model.smartCollection = collection
                        }
                    } label: {
                        Label(collection.title, systemImage: collection.systemImage)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(model.smartCollection == collection ? .white : AppTheme.primaryGreen)
                            .background(
                                model.smartCollection == collection
                                    ? AppTheme.primaryGreen
                                    : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("drive.collection.\(collection.rawValue)")
                    .accessibilityAddTraits(model.smartCollection == collection ? .isSelected : [])
                }
            }
        }
        .accessibilityIdentifier("drive.smart-collections")
    }

    @ViewBuilder
    private var driveContent: some View {
        if model.isLoading && model.entries.isEmpty {
            ProgressView("加载网盘")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if model.visibleEntries.isEmpty {
            ContentUnavailableView(
                model.searchText.isEmpty ? "当前目录为空" : "没有匹配文件",
                systemImage: model.searchText.isEmpty ? "folder" : "magnifyingglass",
                description: Text(model.searchText.isEmpty ? "点击右上角加号创建文件夹或导入文件" : "换一个关键词试试")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if displayMode == .list {
            listContent
        } else {
            gridContent
        }
        if model.isLoadingNextPage {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
        }
    }

    private var listContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.visibleEntries) { entry in
                listRow(for: entry)
                    .onAppear { loadNextPageIfNeeded(entry) }
            }
        }
        .accessibilityIdentifier("drive.entries.list")
    }

    private var gridContent: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
            ForEach(model.visibleEntries) { entry in
                gridCell(for: entry)
                    .onAppear { loadNextPageIfNeeded(entry) }
            }
        }
        .accessibilityIdentifier("drive.entries.grid")
    }

    private func listRow(for entry: DriveFileEntry) -> some View {
        Button { handleTap(entry) } label: {
            HStack(spacing: 12) {
                thumbnailView(for: entry, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).foregroundStyle(.primary).lineLimit(1)
                    Text(entrySubtitle(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelecting { selectionMark(for: entry) }
                else if !entry.isFile { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drive.entry.\(entry.id)")
        .contextMenu { entryActions(for: entry) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { requestDelete(entry) } label: { Label("删除", systemImage: "trash") }
            Button { beginRename(entry) } label: { Label("重命名", systemImage: "pencil") }.tint(AppTheme.documentBlue)
        }
        .task(id: thumbnailKey(for: entry)) { await loadThumbnail(for: entry) }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func gridCell(for entry: DriveFileEntry) -> some View {
        Button { handleTap(entry) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    thumbnailView(for: entry, size: 112)
                        .frame(maxWidth: .infinity)
                    if isSelecting { selectionMark(for: entry).padding(6) }
                }
                Text(entry.name).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                Text(entrySubtitle(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drive.entry.\(entry.id)")
        .contextMenu { entryActions(for: entry) }
        .task(id: thumbnailKey(for: entry)) { await loadThumbnail(for: entry) }
    }

    private func selectionBarContent() -> some View {
        HStack(spacing: 12) {
            Button(allVisibleSelected ? "取消全选" : "全选") {
                if allVisibleSelected { model.clearSelection() } else { model.selectAll() }
            }
            .accessibilityIdentifier("drive.select-all")
            Spacer()
            Button { downloadSelected() } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            // [修改] 目录支持递归下载后，选中目录也必须能进入批量下载。
            .disabled(model.selectedEntries.isEmpty || model.isBatchOperating)
            .accessibilityIdentifier("drive.batch-download")
            Button(role: .destructive) { showsBatchDeleteConfirmation = true } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(model.selectedEntries.isEmpty || model.isBatchOperating)
            .accessibilityIdentifier("drive.batch-delete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionBar: some View {
        selectionBarContent()
            .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func entryActions(for entry: DriveFileEntry) -> some View {
        Button { beginRename(entry) } label: { Label("重命名", systemImage: "pencil") }
        Button { showDetails(for: entry) } label: { Label("查看详情", systemImage: "info.circle") }
        if entry.isFile {
            Button { Task { await openFile(entry) } } label: { Label("打开", systemImage: "arrow.up.right.square") }
            Button { Task { await downloadAndShare(entry) } } label: { Label("下载并分享", systemImage: "square.and.arrow.down") }
            Button { movingFile = entry } label: { Label("移动到", systemImage: "folder") }
            Button { publishToDynamics(entry) } label: { Label("发布到动态", systemImage: "quote.bubble") }
        } else {
            Button { movingDirectory = entry } label: { Label("移动到", systemImage: "folder") }
        }
        Button(role: .destructive) { requestDelete(entry) } label: { Label("删除", systemImage: "trash") }
    }

    private func publishToDynamics(_ entry: DriveFileEntry) {
        guard let draft = DriveDynamicDraftBuilder.draft(for: entry) else { return }
        dynamicComposerRouteStore.present(draft)
        onOpenDynamicComposer()
    }

    private func thumbnailView(for entry: DriveFileEntry, size: CGFloat) -> some View {
        Group {
            if let image = thumbnails[thumbnailKey(for: entry)] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: icon(for: entry))
                    .font(.title2)
                    .foregroundStyle(entry.isFile ? AppTheme.documentBlue : AppTheme.primaryGreen)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func selectionMark(for entry: DriveFileEntry) -> some View {
        Image(systemName: model.selectedEntryIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(model.selectedEntryIDs.contains(entry.id) ? AppTheme.primaryGreen : .secondary)
            .background(.thinMaterial, in: Circle())
    }

    private func loadingOverlay() -> some View {
        Group {
            if model.isTransferring { ProgressView("正在传输") .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
        }
    }

    private func debounceSearch() async {
        guard !model.searchText.isEmpty || model.currentDirectory != nil else { return }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        guard !Task.isCancelled else { return }
        await model.performSearch()
    }

    private func loadNextPageIfNeeded(_ entry: DriveFileEntry) {
        guard entry.id == model.visibleEntries.last?.id else { return }
        Task { await model.loadNextPage() }
    }

    private func handleTap(_ entry: DriveFileEntry) {
        if isSelecting {
            model.toggleSelection(entry)
        } else if entry.isFile {
            Task { await openFile(entry) }
        } else {
            Task { await model.open(entry) }
        }
    }

    private func openFile(_ entry: DriveFileEntry) async {
        switch DriveFileOpenRules.presentation(for: entry) {
        case .inlineMedia:
            await showPreview(for: entry)
        case .quickLook:
            await downloadAndOpen(entry)
        }
    }

    private func showPreview(for entry: DriveFileEntry) async {
        if isVideo(entry), let mediaRepository {
            let requestPlayback: @MainActor () async throws -> MediaPlayback = {
                try await mediaRepository.playback(fileId: entry.id, username: username)
            }
            // [修改] 先展示播放器，再由播放器异步申请 Range 播放地址；大视频不再等待请求完成或回退整文件下载。
            preview = DrivePreview(
                entry: entry,
                url: Self.pendingVideoURL,
                kind: .video,
                refreshPlayback: requestPlayback,
                localShareProvider: {
                    await makeSharePayload(for: entry)
                }
            )
            return
        }
        guard let url = await model.preview(entry) else { return }
        preview = DrivePreview(entry: entry, url: url, kind: isVideo(entry) ? .video : .image)
    }

    private static let pendingVideoURL = URL(string: "https://127.0.0.1/pending-video")!

    private func downloadAndShare(_ entry: DriveFileEntry) async {
        if let payload = await makeSharePayload(for: entry) { sharePayload = payload }
    }

    @MainActor
    private func makeSharePayload(for entry: DriveFileEntry) async -> DriveSharePayload? {
        let location = downloadLocation()
        let access = location.access
        guard let destination = nextDownloadURL(for: entry.name, directory: location.url),
              let url = await model.download(
                entry,
                destinationURL: destination,
                destinationDirectoryBookmark: location.bookmark
              ) else { return nil }
        // [修改] 分享 sheet 持有外部目录授权，直到系统分享界面关闭后再释放。
        return DriveSharePayload(urls: [url], access: access)
    }

    private func downloadAndOpen(_ entry: DriveFileEntry) async {
        let location = downloadLocation()
        let access = location.access
        guard let destination = nextDownloadURL(for: entry.name, directory: location.url),
              let url = await model.download(
                entry,
                destinationURL: destination,
                destinationDirectoryBookmark: location.bookmark
              ) else { return }
        // [修改] 普通文件“打开”下载完成后进入 Quick Look，并把外部目录授权保留到预览关闭。
        preview = DrivePreview(entry: entry, url: url, kind: .downloaded, access: access)
    }

    private func downloadSelected() {
        let location = downloadLocation()
        let access = location.access
        Task {
            let urls = await model.downloadSelected(
                to: location.url,
                destinationDirectoryBookmark: location.bookmark
            )
            // [修改] 批量分享同样延长 security-scoped access 的生命周期。
            if !urls.isEmpty { sharePayload = DriveSharePayload(urls: urls, access: access) }
            if model.selectedEntryIDs.isEmpty { isSelecting = false }
        }
    }

    private func createDirectory() {
        let value = newDirectoryName
        newDirectoryName = ""
        Task { await model.createDirectory(name: value) }
    }

    private func beginRename(_ entry: DriveFileEntry) {
        // [修改] 文件重命名只编辑主文件名，保存时由规则自动补回原扩展名。
        renameValue = DriveFileNameRules.editableName(for: entry)
        renameEntry = entry
    }

    private func renameSelectedEntry() {
        guard let entry = renameEntry else { return }
        let value = renameValue
        renameEntry = nil
        Task {
            if await model.rename(entry, name: value) { await invalidateThumbnail(for: entry) }
        }
    }

    private func requestDelete(_ entry: DriveFileEntry) { deleteEntry = entry }

    private func deleteSelectedEntry() {
        guard let entry = deleteEntry else { return }
        deleteEntry = nil
        Task {
            if await model.delete(entry) { await invalidateThumbnail(for: entry) }
        }
    }

    private func deleteSelectedEntries() {
        Task {
            let deletedEntries = await model.deleteSelected()
            for entry in deletedEntries { await invalidateThumbnail(for: entry) }
            if model.selectedEntryIDs.isEmpty { isSelecting = false }
        }
    }

    private func showDetails(for entry: DriveFileEntry) {
        Task {
            if let detail = await model.loadDetail(for: entry) { detailEntry = detail }
        }
    }

    private func toggleSelectionMode() {
        isSelecting.toggle()
        if !isSelecting { model.clearSelection() }
    }

    private func toggleDisplayMode() {
        displayModeRawValue = displayMode == .list ? DriveDisplayMode.grid.rawValue : DriveDisplayMode.list.rawValue
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                model.reportError("没有选择可上传的文件")
                return
            }
            Task { await uploadImportedFiles(urls) }
        case .failure(let error):
            if let message = DrivePickerErrorRules.message(for: error, fallback: "文件选择失败，请重试") {
                model.reportError(message)
            }
        }
    }

    private func uploadImportedFiles(_ urls: [URL]) async {
        // [修改] 多选文件一次性提交到持久传输队列，实际并发由 TransferManager 统一限制为 5。
        await model.upload(sourceURLs: urls)
    }

    // 本地相册视频直接由 Photos 分块供给传输引擎；照片仍使用既有暂存路径，避免扩大本次改动范围。
    private func importPickedMedia(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            let contentType = item.supportedContentTypes.first {
                isVideo ? $0.conforms(to: .movie) : $0.conforms(to: .image)
            }
            let fileExtension = contentType?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            let fileName = isVideo ? "视频 \(index + 1).\(fileExtension)" : "照片 \(index + 1).\(fileExtension)"
            if isVideo {
                guard let assetIdentifier = item.itemIdentifier else {
                    model.reportError("无法定位所选相册视频，请重新选择")
                    continue
                }
                guard await DrivePhotoLibraryAccess.requestReadAccessIfNeeded() else {
                    model.reportError("需要相册访问权限才能直接上传本地视频")
                    continue
                }
                guard let preparation = await model.beginPhotoLibraryUpload(
                    fileName: fileName,
                    photoLibraryAssetIdentifier: assetIdentifier
                ) else { return }
                await model.startPhotoLibraryVideoUpload(preparation)
                continue
            }

            guard let preparation = await model.beginPhotoLibraryUpload(fileName: fileName) else { return }
            do {
                guard let stagedURL = try await stagedPickedMedia(
                    item,
                    index: index,
                    isVideo: isVideo
                ) else {
                    throw FileTransferError.invalidResponse("没有读取到可上传的相册内容")
                }
                await model.finishPhotoLibraryUpload(preparation, sourceURL: stagedURL)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "相册文件导入失败"
                await model.failPhotoLibraryUpload(preparation, message: message)
                model.reportError(message)
            }
        }
    }

    private func stagedPickedMedia(
        _ item: PhotosPickerItem,
        index: Int,
        isVideo: Bool
    ) async throws -> URL? {
        precondition(!isVideo, "本地相册视频必须走零副本流式上传")
        guard let image = try await item.loadTransferable(type: DrivePickedImageFile.self) else { return nil }
        let ext = image.url.pathExtension.isEmpty ? "jpg" : image.url.pathExtension
        return try await ChatAttachmentStaging.renameTransferredFile(
            image.url,
            preferredFileName: "照片 \(index + 1).\(ext)"
        )
    }

    private func loadThumbnail(for entry: DriveFileEntry) async {
        guard entry.isFile, isImage(entry) || isVideo(entry) else { return }
        let key = thumbnailKey(for: entry)
        guard thumbnails[key] == nil, !loadingThumbnailKeys.contains(key) else { return }
        loadingThumbnailKeys.insert(key)
        defer { loadingThumbnailKeys.remove(key) }

        if let cached = await DriveThumbnailCache.shared.data(for: key), let image = UIImage(data: cached) {
            thumbnails[key] = image
            return
        }

        let kind: DriveThumbnailKind = isImage(entry) ? .image : .video
        guard let data = await thumbnailLoader.data(for: entry, kind: kind, cacheKey: key),
              !Task.isCancelled,
              let image = UIImage(data: data) else { return }
        thumbnails[key] = image
    }

    private func thumbnailKey(for entry: DriveFileEntry) -> String {
        DriveThumbnailCacheKey(
            serverScopeID: serverScopeID,
            userId: userId,
            fileId: entry.id
        ).rawValue
    }

    @MainActor
    private func invalidateThumbnail(for entry: DriveFileEntry) async {
        guard entry.isFile else { return }
        let key = thumbnailKey(for: entry)
        thumbnails.removeValue(forKey: key)
        await DriveThumbnailCache.shared.remove(key: key)
    }

    private func downloadLocation() -> (url: URL, bookmark: Data?, access: TransferScopedURLAccess?) {
        if !downloadDirectoryBookmarkBase64.isEmpty {
            guard let bookmark = Data(base64Encoded: downloadDirectoryBookmarkBase64),
                  let access = try? TransferDestinationResolver.directoryAccess(bookmarkData: bookmark) else {
                // [修改] bookmark 失效时清除坏配置并明确告知用户，避免每次下载都静默落到另一个目录。
                downloadDirectoryBookmarkBase64 = ""
                model.reportError("原下载位置授权已失效，已恢复默认下载目录")
                return defaultDownloadLocation()
            }
            do {
                try FileManager.default.createDirectory(at: access.url, withIntermediateDirectories: true)
                if let refreshedBookmark = access.refreshedBookmarkData {
                    // [修改] 文件提供器返回过期 bookmark 时更新设置，后续下载直接使用新授权。
                    downloadDirectoryBookmarkBase64 = refreshedBookmark.base64EncodedString()
                    return (access.url, refreshedBookmark, access)
                }
                return (access.url, bookmark, access)
            } catch {
                // [修改] 外部目录已不可写时同样清理授权，后续下载使用可用的应用目录。
                downloadDirectoryBookmarkBase64 = ""
                model.reportError("原下载位置不可写，已恢复默认下载目录")
            }
        }
        return defaultDownloadLocation()
    }

    private func defaultDownloadLocation() -> (url: URL, bookmark: Data?, access: TransferScopedURLAccess?) {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChatStorage/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, nil, nil)
    }

    private func nextDownloadURL(for fileName: String, directory: URL? = nil) -> URL? {
        let directory = directory ?? downloadLocation().url
        // [修改] 单文件下载和批量下载共用本地文件名净化，远端路径片段不会影响目标目录。
        let safeFileName = TransferFileName.safeLocalName(fileName, fallback: "download")
        let source = safeFileName as NSString
        let stem = source.deletingPathExtension
        let fileExtension = source.pathExtension
        var candidate = safeFileName
        var index = 1
        while isDownloadNameOccupied(candidate, in: directory) {
            candidate = fileExtension.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(fileExtension)"
            index += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    private func isDownloadNameOccupied(_ name: String, in directory: URL) -> Bool {
        let destination = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: destination.path)
            || FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path)
    }

    private func icon(for entry: DriveFileEntry) -> String {
        if !entry.isFile { return "folder.fill" }
        switch DriveFileOpenRules.fileExtension(for: entry) {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo.fill"
        case "mp4", "mov", "m4v", "mkv", "avi", "webm": return "video.fill"
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z": return "archivebox.fill"
        default: return "doc.fill"
        }
    }

    private func entrySubtitle(_ entry: DriveFileEntry) -> String {
        if !entry.isFile {
            return entry.children.isEmpty ? "文件夹" : "文件夹 · \(entry.children.count) 项"
        }
        let size = ByteCountFormatter.string(fromByteCount: entry.size ?? 0, countStyle: .file)
        let date = formatDate(entry.modifiedAt ?? entry.createdAt)
        return date.isEmpty ? size : "\(size) · \(date)"
    }

    private func formatDate(_ value: Int64?) -> String {
        guard let value else { return "" }
        let seconds = value > 10_000_000_000 ? Double(value) / 1_000 : Double(value)
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }

    private func isImage(_ entry: DriveFileEntry) -> Bool {
        DriveFileOpenRules.isImage(entry)
    }

    private func isVideo(_ entry: DriveFileEntry) -> Bool {
        DriveFileOpenRules.isVideo(entry)
    }
}

private enum DriveDisplayMode: String {
    case list
    case grid
}

enum DrivePreviewKind: String {
    case image
    case video
    case downloaded
}

enum DrivePreviewSharePolicy {
    // [修改] 视频的远程 URL 带短期 token，只允许分享已经下载到本地的文件。
    static func canShareDirectly(url: URL, isVideo: Bool) -> Bool {
        !isVideo || url.isFileURL
    }
}

private struct DrivePreview: Identifiable {
    let entry: DriveFileEntry
    let url: URL
    let kind: DrivePreviewKind
    let playback: MediaPlayback?
    let refreshPlayback: (@MainActor () async throws -> MediaPlayback)?
    let localShareProvider: (@MainActor () async -> DriveSharePayload?)?
    // [修改] 外部目录文件预览期间持续持有 security-scoped access。
    let access: TransferScopedURLAccess?
    var id: String { "\(entry.id)-\(kind.rawValue)-\(url.absoluteString)" }

    init(
        entry: DriveFileEntry,
        url: URL,
        kind: DrivePreviewKind,
        playback: MediaPlayback? = nil,
        refreshPlayback: (@MainActor () async throws -> MediaPlayback)? = nil,
        localShareProvider: (@MainActor () async -> DriveSharePayload?)? = nil,
        access: TransferScopedURLAccess? = nil
    ) {
        self.entry = entry
        self.url = url
        self.kind = kind
        self.playback = playback
        self.refreshPlayback = refreshPlayback
        self.localShareProvider = localShareProvider
        self.access = access
    }
}

private struct DriveSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    // [修改] 保留外部目录的安全作用域，覆盖系统分享 sheet 的整个生命周期。
    let access: TransferScopedURLAccess?
}

private struct DrivePreviewView: View {
    let preview: DrivePreview
    @State private var videoController: DriveVideoPlaybackController
    @State private var showsFullscreenVideo = false
    @State private var isPreparingShare = false
    @State private var sharePayload: DriveSharePayload?

    init(preview: DrivePreview) {
        self.preview = preview
        if let playback = preview.playback,
           let refreshPlayback = preview.refreshPlayback {
            _videoController = State(initialValue: DriveVideoPlaybackController(
                playback: playback,
                refreshPlayback: refreshPlayback
            ))
        } else if preview.kind == .video,
                  let refreshPlayback = preview.refreshPlayback {
            _videoController = State(initialValue: DriveVideoPlaybackController(
                refreshPlayback: refreshPlayback
            ))
        } else {
            _videoController = State(initialValue: DriveVideoPlaybackController(url: preview.url))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch preview.kind {
                case .video:
                    if let player = videoController.player {
                        videoContent(player: player, fullscreen: false)
                    } else {
                        pendingVideoContent
                    }
                case .image:
                    imageContent
                case .downloaded:
                    DriveQuickLookPreview(url: preview.url)
                        .accessibilityIdentifier("drive.quicklook")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(preview.kind == .image ? 0.04 : 0))
            .navigationTitle(preview.entry.name)
            .navigationBarTitleDisplayMode(.inline)
            // [修改] 预览容器不能覆盖播放、停止、进度和全屏等子控件的独立标识。
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityLabel("文件预览")
                    .accessibilityIdentifier("drive.preview")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { shareToolbarItem }
            }
            .task {
                guard preview.kind == .video else { return }
                await videoController.start(autoplay: true)
            }
            .onDisappear {
                showsFullscreenVideo = false
                AppOrientationController.setVideoFullscreen(false)
                videoController.invalidate()
            }
            .onChange(of: showsFullscreenVideo) { _, isFullscreen in
                AppOrientationController.setVideoFullscreen(isFullscreen)
            }
        }
        .sheet(item: $sharePayload) { payload in
            DriveShareSheet(items: payload.urls, access: payload.access)
        }
        .fullScreenCover(isPresented: $showsFullscreenVideo) {
            if let player = videoController.player {
                videoContent(player: player, fullscreen: true)
                    .background(Color.black.ignoresSafeArea())
                    .statusBarHidden(true)
                    // [修改] 全屏容器标识单独放在透明节点上，避免覆盖退出、播放和停止按钮标识。
                    .overlay(alignment: .topLeading) {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityLabel("视频全屏播放")
                            .accessibilityIdentifier("drive.video.fullscreen-view")
                    }
            }
        }
    }

    @ViewBuilder
    private func videoContent(player: AVPlayer, fullscreen: Bool) -> some View {
        VStack(spacing: 0) {
            if fullscreen || !showsFullscreenVideo {
                DriveVideoSurface(player: player)
                    .frame(maxWidth: .infinity, maxHeight: fullscreen ? .infinity : nil)
                    // 竖屏、方形和 4:3 视频均使用 AVPlayerItem 已处理旋转方向后的展示尺寸；
                    // 不再被错误塞进固定的 16:9 画框。
                    .aspectRatio(
                        fullscreen ? nil : DriveVideoLayout.aspectRatio(
                            for: player.currentItem?.presentationSize ?? .zero
                        ),
                        contentMode: .fit
                    )
            } else {
                // [修改] 全屏时卸载内嵌 AVPlayerLayer，避免同一播放器同时维持两份输出层。
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
            }
            videoControls(player: player, fullscreen: fullscreen)
        }
        .background(Color.black)
        .overlay { videoStatusOverlay }
    }

    private var pendingVideoContent: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { videoStatusOverlay }
            .accessibilityIdentifier("drive.video.loading-surface")
    }

    private func videoControls(player: AVPlayer, fullscreen: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(Self.formattedTime(videoController.playbackState.currentTime))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { videoController.playbackState.currentTime },
                        set: { videoController.updateScrubbing(to: $0) }
                    ),
                    in: 0...videoController.playbackState.sliderUpperBound,
                    onEditingChanged: { editing in
                        if editing {
                            videoController.beginScrubbing()
                        } else {
                            Task { await videoController.endScrubbing() }
                        }
                    }
                )
                .disabled(videoController.playbackState.duration <= 0)
                .tint(AppTheme.primaryGreen)
                .accessibilityLabel("播放进度")
                .accessibilityIdentifier("drive.video.progress")

                Text(Self.formattedTime(videoController.playbackState.duration))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42, alignment: .leading)
            }

            HStack(spacing: 18) {
                Button { Task { await videoController.togglePlayback() } } label: {
                    Image(systemName: videoController.playbackState.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 32)
                }
                .accessibilityLabel(videoController.playbackState.isPlaying ? "暂停" : "播放")
                .accessibilityIdentifier("drive.video.play-pause")

                Button { Task { await videoController.stop() } } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 36, height: 32)
                }
                .accessibilityLabel("停止")
                .accessibilityIdentifier("drive.video.stop")

                Spacer()

                if videoController.phase == .waiting {
                    ProgressView().tint(.white).accessibilityLabel("视频缓冲中")
                }

                Button { showsFullscreenVideo = !fullscreen } label: {
                    Image(systemName: fullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 36, height: 32)
                }
                .accessibilityLabel(fullscreen ? "退出全屏" : "全屏播放")
                .accessibilityIdentifier(fullscreen ? "drive.video.exit-fullscreen" : "drive.video.fullscreen")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.94))
    }

    @ViewBuilder
    private var videoStatusOverlay: some View {
        switch videoController.phase {
        case .loading:
            ProgressView("加载视频").tint(.white).foregroundStyle(.white)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
                Text(message).font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                Button("重新加载") { Task { await videoController.retry() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("drive.video.retry")
            }
            .padding(20)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        case .ended:
            Label("播放结束", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.58), in: Capsule())
        case .idle, .ready, .waiting:
            EmptyView()
        }
    }

    @ViewBuilder
    private var shareToolbarItem: some View {
        if DrivePreviewSharePolicy.canShareDirectly(url: preview.url, isVideo: preview.kind == .video) {
            ShareLink(item: preview.url)
        } else if preview.localShareProvider != nil {
            Button {
                Task { await prepareLocalShare() }
            } label: {
                if isPreparingShare { ProgressView() }
                else { Image(systemName: "square.and.arrow.up") }
            }
            .disabled(isPreparingShare)
            .accessibilityLabel("下载并分享")
            .accessibilityIdentifier("drive.video.download-share")
        }
    }

    private func prepareLocalShare() async {
        guard let provider = preview.localShareProvider, !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        sharePayload = await provider()
    }

    private static func formattedTime(_ value: TimeInterval) -> String {
        let seconds = max(Int(value.rounded(.down)), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image = UIImage(contentsOfFile: preview.url.path) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image).resizable().scaledToFit().padding()
            }
        } else {
            ContentUnavailableView("无法预览图片", systemImage: "photo", description: Text(preview.entry.name))
        }
    }
}

// [修改] 网盘和聊天视频共用无系统控件的 AVPlayerLayer，播放、停止、进度和全屏由 SwiftUI 控制条管理。
struct SecureVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Void) {
        view.playerLayer.player = nil
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

private typealias DriveVideoSurface = SecureVideoSurface

// [修改] iOS 普通文件使用系统 Quick Look，支持 PDF、Office、文本、压缩包等系统可识别格式。
private struct DriveQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

private struct DriveFileDetailView: View {
    let entry: DriveFileEntry

    var body: some View {
        NavigationStack {
            List {
                detailRow("名称", entry.name)
                detailRow("类型", entry.isFile ? (entry.fileType.isEmpty ? "文件" : entry.fileType) : "文件夹")
                if let size = entry.size { detailRow("大小", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                if let path = nonBlank(entry.path) { detailRow("路径", path) }
                if let parent = entry.parentDirectoryName { detailRow("所在目录", parent) }
                if let md5 = entry.md5 { detailRow("MD5", md5) }
                if let created = entry.createdAt { detailRow("创建时间", formatDate(created)) }
                if let modified = entry.modifiedAt { detailRow("修改时间", formatDate(modified)) }
            }
            .navigationTitle("文件详情")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("drive.detail")
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value).textSelection(.enabled)
    }

    private func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func formatDate(_ value: Int64) -> String {
        let seconds = value > 10_000_000_000 ? Double(value) / 1_000 : Double(value)
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }
}

private struct DriveDirectoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expandedDirectoryIDs: Set<Int64> = []
    let title: String
    let roots: [DriveFileEntry]
    let excludedIDs: Set<Int64>
    let selectedID: Int64?
    let loadingDirectoryIDs: Set<Int64>
    let onExpand: (Int64) async -> Void
    let onSelect: (Int64) -> Void

    var body: some View {
        NavigationStack {
            List {
                if roots.isEmpty {
                    ContentUnavailableView("没有可用文件夹", systemImage: "folder")
                } else {
                    ForEach(roots.filter { !$0.isFile }) { directory in
                        DriveDirectoryTreeNode(
                            directory: directory,
                            excludedIDs: excludedIDs,
                            selectedID: selectedID,
                            loadingDirectoryIDs: loadingDirectoryIDs,
                            expandedDirectoryIDs: $expandedDirectoryIDs,
                            onExpand: onExpand,
                            onSelect: { id in
                                onSelect(id)
                                dismiss()
                            }
                        )
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("取消") { dismiss() } }
            }
            .accessibilityIdentifier("drive.tree.sheet")
        }
    }
}

private struct DriveDirectoryTreeNode: View {
    let directory: DriveFileEntry
    let excludedIDs: Set<Int64>
    let selectedID: Int64?
    let loadingDirectoryIDs: Set<Int64>
    @Binding var expandedDirectoryIDs: Set<Int64>
    let onExpand: (Int64) async -> Void
    let onSelect: (Int64) -> Void

    private var directoryChildren: [DriveFileEntry] { directory.children.filter { !$0.isFile } }
    private var canExpand: Bool { directory.hasChildren || !directoryChildren.isEmpty }

    var body: some View {
        if canExpand {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(directoryChildren) { child in
                    DriveDirectoryTreeNode(
                        directory: child,
                        excludedIDs: excludedIDs,
                        selectedID: selectedID,
                        loadingDirectoryIDs: loadingDirectoryIDs,
                        expandedDirectoryIDs: $expandedDirectoryIDs,
                        onExpand: onExpand,
                        onSelect: onSelect
                    )
                }
            } label: {
                selectionButton
            }
            .task(id: expandedDirectoryIDs.contains(directory.id)) {
                guard expandedDirectoryIDs.contains(directory.id), directoryChildren.isEmpty else { return }
                await onExpand(directory.id)
            }
        } else {
            selectionButton
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandedDirectoryIDs.contains(directory.id) },
            set: { expanded in
                if expanded { expandedDirectoryIDs.insert(directory.id) }
                else { expandedDirectoryIDs.remove(directory.id) }
            }
        )
    }

    private var selectionButton: some View {
        Button { onSelect(directory.id) } label: {
            HStack {
                Image(systemName: AppSystemSymbols.directory)
                    .foregroundStyle(excludedIDs.contains(directory.id) ? .secondary : AppTheme.primaryGreen)
                Text(directory.name)
                Spacer()
                if loadingDirectoryIDs.contains(directory.id) { ProgressView().controlSize(.small) }
                if excludedIDs.contains(directory.id) { Text("不可用").font(.caption).foregroundStyle(.secondary) }
                if directory.id == selectedID {
                    // [修改] 使用独立勾选徽标表达当前目录，替代不存在的 checkmark.folder.fill。
                    Image(systemName: AppSystemSymbols.selectedDirectoryBadge)
                        .foregroundStyle(AppTheme.documentBlue)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(excludedIDs.contains(directory.id))
    }
}

private struct DriveShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    private let access: TransferScopedURLAccess?

    init(items: [URL], access: TransferScopedURLAccess? = nil) {
        self.items = items
        self.access = access
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        _ = access
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

actor DriveThumbnailCache {
    static let shared = DriveThumbnailCache()
    private let memory = NSCache<NSString, NSData>()
    private let rootURL: URL
    private let maximumDiskBytes: Int64

    init(rootURL: URL? = nil, maximumDiskBytes: Int64 = 64 * 1024 * 1024) {
        let root = rootURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChatStorage/DriveThumbnails", isDirectory: true)
        self.rootURL = root
        self.maximumDiskBytes = max(1, maximumDiskBytes)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        memory.countLimit = 160
    }

    func data(for key: String) -> Data? {
        let memoryKey = NSString(string: key)
        let url = rootURL.appendingPathComponent(safeFileName(key)).appendingPathExtension("jpg")
        // [修改] 磁盘缓存被用户清理后同步淘汰内存项，避免继续显示已经清掉的旧缩略图。
        if let value = memory.object(forKey: memoryKey) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                memory.removeObject(forKey: memoryKey)
                return nil
            }
            touch(url)
            return Data(value)
        }
        guard let value = try? Data(contentsOf: url) else { return nil }
        touch(url)
        memory.setObject(value as NSData, forKey: memoryKey)
        return value
    }

    // [修改] 远端文件重命名或删除后同时淘汰内存和磁盘缩略图。
    func remove(key: String) {
        memory.removeObject(forKey: NSString(string: key))
        let url = rootURL.appendingPathComponent(safeFileName(key)).appendingPathExtension("jpg")
        try? FileManager.default.removeItem(at: url)
    }

    func store(_ data: Data, for key: String) {
        guard !data.isEmpty else { return }
        let memoryKey = NSString(string: key)
        let url = rootURL.appendingPathComponent(safeFileName(key)).appendingPathExtension("jpg")
        do {
            // [修改] 清理操作会删除整个目录，下一次拉取必须先重建目录再恢复两级缓存。
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            touch(url)
            memory.setObject(data as NSData, forKey: memoryKey)
            // [修改] 缩略图磁盘缓存按最近使用时间自动收敛到固定容量。
            prune(keeping: url)
        } catch {
            memory.removeObject(forKey: memoryKey)
        }
    }

    private func safeFileName(_ key: String) -> String {
        key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func prune(keeping protectedURL: URL) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var totalBytes: Int64 = 0
        var candidates: [(url: URL, bytes: Int64, modifiedAt: Date)] = []
        let protectedPath = protectedURL.standardizedFileURL.path
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            totalBytes += bytes
            if url.standardizedFileURL.path != protectedPath {
                candidates.append((url, bytes, values.contentModificationDate ?? .distantPast))
            }
        }
        for candidate in candidates.sorted(by: { $0.modifiedAt < $1.modifiedAt }) where totalBytes > maximumDiskBytes {
            guard (try? fileManager.removeItem(at: candidate.url)) != nil else { continue }
            totalBytes -= candidate.bytes
        }
    }
}

enum DriveThumbnailKind: Sendable {
    case image
    case video
}

// [修改] 缩略图加载统一经过一个三并发入口，SwiftUI 行取消会继续传给预览下载或视频抽帧。
actor DriveThumbnailLoader {
    static let maximumRemoteImageBytes: Int64 = 8 * 1024 * 1024
    private let transferManager: (any DriveTransferManaging)?
    private let mediaRepository: (any MediaPlaybackProviding)?
    private let username: String
    private let limiter: DriveThumbnailLoadLimiter

    init(
        transferManager: (any DriveTransferManaging)?,
        mediaRepository: (any MediaPlaybackProviding)?,
        username: String,
        maxConcurrent: Int = 3
    ) {
        self.transferManager = transferManager
        self.mediaRepository = mediaRepository
        self.username = username
        self.limiter = DriveThumbnailLoadLimiter(maxConcurrent: maxConcurrent)
    }

    func data(for entry: DriveFileEntry, kind: DriveThumbnailKind, cacheKey: String) async -> Data? {
        if let cached = await DriveThumbnailCache.shared.data(for: cacheKey) { return cached }

        let transferManager = transferManager
        let mediaRepository = mediaRepository
        let username = username
        do {
            let data: Data? = try await limiter.withPermit {
                try Task.checkCancellation()
                switch kind {
                case .image:
                    guard let transferManager else { return nil }
                    let sourceData = try await transferManager.thumbnailData(
                        remoteFileId: entry.id,
                        fileName: entry.name,
                        fileSize: entry.size ?? 0,
                        maximumBytes: Self.maximumRemoteImageBytes
                    )
                    try Task.checkCancellation()
                    return await DriveThumbnailRenderer.jpegData(
                        from: sourceData,
                        isFinal: entry.size.map { Int64(sourceData.count) >= $0 } ?? false,
                        maxPixelSize: 360
                    )
                case .video:
                    guard mediaRepository != nil || transferManager != nil else { return nil }
                    return try await Self.videoThumbnailData(
                        entry: entry,
                        mediaRepository: mediaRepository,
                        transferManager: transferManager,
                        username: username
                    )
                }
            }
            try Task.checkCancellation()
            if let data { await DriveThumbnailCache.shared.store(data, for: cacheKey) }
            return data
        } catch {
            return nil
        }
    }

    private static func videoThumbnailData(
        entry: DriveFileEntry,
        mediaRepository: (any MediaPlaybackProviding)?,
        transferManager: (any DriveTransferManaging)?,
        username: String
    ) async throws -> Data? {
        if let mediaRepository,
           let playback = try? await mediaRepository.playback(fileId: entry.id, username: username),
           let pinnedMediaAsset = PinnedMediaAsset(url: playback.playURL),
           let data = try? await generateVideoThumbnail(asset: pinnedMediaAsset.asset) {
            withExtendedLifetime(pinnedMediaAsset) {}
            return data
        }

        guard let transferManager,
              let fileSize = entry.size,
              fileSize > 0,
              let assetURL = URL(string: "chatstorage-thumbnail://video/\(entry.id)") else {
            return nil
        }
        let asset = AVURLAsset(url: assetURL)
        let loader = DriveVideoThumbnailResourceLoader(
            fileId: entry.id,
            fileSize: fileSize,
            fileName: entry.name,
            fetchRange: { offset, length in
                try await transferManager.thumbnailRangeData(
                    remoteFileId: entry.id,
                    fileName: entry.name,
                    fileSize: fileSize,
                    startOffset: offset,
                    length: length
                )
            }
        )
        let loaderQueue = DispatchQueue(label: "com.alibaba.chatstorage.video-thumbnail.\(entry.id)")
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
        let data = try await generateVideoThumbnail(asset: asset)
        withExtendedLifetime(loader) {}
        return data
    }

    private static func generateVideoThumbnail(asset: AVAsset) async throws -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        let generatorBox = DriveThumbnailImageGeneratorBox(generator)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        return try await withTaskCancellationHandler {
            for second in [0.0, 1.0, 2.0] {
                try Task.checkCancellation()
                do {
                    let result = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
                    try Task.checkCancellation()
                    return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.82)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            return nil
        } onCancel: {
            generatorBox.value.cancelAllCGImageGeneration()
        }
    }
}

// HTTP 媒体地址不可用时，直接把 AVFoundation 的字节请求桥接到现有
// range_pull v2。单窗口限制为 4MB，并预取头尾以兼容 moov 位于文件尾部的视频。
final class DriveVideoThumbnailResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    struct ByteRange: Equatable, Sendable {
        let offset: Int64
        let length: Int64
    }

    private struct CachedSegment {
        let offset: Int64
        let data: Data
        var endOffset: Int64 { offset + Int64(data.count) }
    }

    private final class LoadingRequestBox: @unchecked Sendable {
        let value: AVAssetResourceLoadingRequest
        init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
    }

    private let fileId: Int64
    private let fileSize: Int64
    private let fileName: String
    private let fetchRange: @Sendable (Int64, Int64) async throws -> Data
    private let lock = NSLock()
    private var cachedSegments: [CachedSegment] = []
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private static let maximumRangeBytes: Int64 = 4 * 1024 * 1024

    init(
        fileId: Int64,
        fileSize: Int64,
        fileName: String,
        fetchRange: @escaping @Sendable (Int64, Int64) async throws -> Data
    ) {
        self.fileId = fileId
        self.fileSize = fileSize
        self.fileName = fileName
        self.fetchRange = fetchRange
    }

    deinit {
        tasksAndClear().forEach { $0.cancel() }
    }

    static func prefetchRanges(fileSize: Int64, maximumRangeBytes: Int64 = maximumRangeBytes) -> [ByteRange] {
        guard fileSize > 0, maximumRangeBytes > 0 else { return [] }
        let length = min(fileSize, maximumRangeBytes)
        let head = ByteRange(offset: 0, length: length)
        guard fileSize > length else { return [head] }
        return [head, ByteRange(offset: fileSize - length, length: length)]
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentLength = fileSize
            info.isByteRangeAccessSupported = true
            info.contentType = contentType
            if loadingRequest.dataRequest == nil {
                loadingRequest.finishLoading()
                return true
            }
        }
        guard let dataRequest = loadingRequest.dataRequest else { return false }
        let offset = max(0, dataRequest.requestedOffset)
        let available = max(0, fileSize - offset)
        let requestedLength = dataRequest.requestsAllDataToEndOfResource
            ? min(Self.maximumRangeBytes, available)
            : min(Int64(dataRequest.requestedLength), Self.maximumRangeBytes, available)
        guard requestedLength > 0 else {
            loadingRequest.finishLoading()
            return true
        }

        let key = ObjectIdentifier(loadingRequest)
        let box = LoadingRequestBox(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            await ensureHeadAndTailPrefetched()
            do {
                try Task.checkCancellation()
                let data: Data
                if let cached = cachedData(offset: offset, length: requestedLength) {
                    data = cached
                } else {
                    data = try await fetchAndCache(offset: offset, length: requestedLength)
                }
                try Task.checkCancellation()
                box.value.dataRequest?.respond(with: data)
                box.value.finishLoading()
            } catch is CancellationError {
                // AVFoundation 已取消请求时不再回调 finishLoading。
            } catch {
                box.value.finishLoading(with: error)
            }
            removeTask(for: key)
        }
        store(task: task, for: key)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        takeTask(for: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func ensureHeadAndTailPrefetched() async {
        let task = existingOrCreatePrefetchTask()
        await task.value
    }

    private func existingOrCreatePrefetchTask() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let prefetchTask { return prefetchTask }
        let task = Task { [weak self] in
            guard let self else { return }
            for range in Self.prefetchRanges(fileSize: fileSize) {
                if cachedData(offset: range.offset, length: range.length) != nil { continue }
                _ = try? await fetchAndCache(offset: range.offset, length: range.length)
            }
        }
        prefetchTask = task
        return task
    }

    private func fetchAndCache(offset: Int64, length: Int64) async throws -> Data {
        let data = try await fetchRange(offset, length)
        guard !data.isEmpty else { throw FileTransferError.incompleteTransfer(expected: length, actual: 0) }
        cache(data, offset: offset)
        return data
    }

    private func cache(_ data: Data, offset: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if !cachedSegments.contains(where: { $0.offset == offset && $0.data.count == data.count }) {
            cachedSegments.append(CachedSegment(offset: offset, data: data))
            if cachedSegments.count > 8 { cachedSegments.removeFirst(cachedSegments.count - 8) }
        }
    }

    private func cachedData(offset: Int64, length: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let segment = cachedSegments.first(where: {
            offset >= $0.offset && offset + length <= $0.endOffset
        }) else { return nil }
        let start = Int(offset - segment.offset)
        return segment.data.subdata(in: start..<(start + Int(length)))
    }

    private func store(task: Task<Void, Never>, for key: ObjectIdentifier) {
        lock.lock(); activeTasks[key] = task; lock.unlock()
    }

    private func takeTask(for key: ObjectIdentifier) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return activeTasks.removeValue(forKey: key)
    }

    private func removeTask(for key: ObjectIdentifier) {
        _ = takeTask(for: key)
    }

    private func tasksAndClear() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        let tasks = Array(activeTasks.values) + [prefetchTask].compactMap { $0 }
        activeTasks.removeAll()
        prefetchTask = nil
        return tasks
    }

    private var contentType: String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mov": return "com.apple.quicktime-movie"
        case "avi": return "public.avi"
        case "mkv": return "org.matroska.mkv"
        default: return "public.mpeg-4"
        }
    }
}

// [修改] AVAssetImageGenerator 的取消方法是线程安全入口，用窄范围包装满足 Swift 6 Sendable 检查。
private final class DriveThumbnailImageGeneratorBox: @unchecked Sendable {
    let value: AVAssetImageGenerator

    init(_ value: AVAssetImageGenerator) {
        self.value = value
    }
}

actor DriveThumbnailLoadLimiter {
    private let maxConcurrent: Int
    private var activeCount = 0
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(maxConcurrent: Int = 3) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func withPermit<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiterOrder.append(waiterID)
                waiters[waiterID] = continuation
            }
            do {
                try Task.checkCancellation()
            } catch {
                // [修改] 空位刚交给本任务时如果它已取消，必须立刻把空位继续交给下一位。
                release()
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while !waiterOrder.isEmpty {
            let waiterID = waiterOrder.removeFirst()
            guard let continuation = waiters.removeValue(forKey: waiterID) else { continue }
            continuation.resume()
            return
        }
        activeCount = max(0, activeCount - 1)
    }
}

enum DriveThumbnailRenderer {
    static func jpegData(at url: URL, maxPixelSize: Int = 360) async -> Data? {
        let task = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(
                    url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                  ) else { return nil }
            return renderJPEG(source: source, maxPixelSize: maxPixelSize)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // [修改] 支持 range_pull 返回的不完整图片前缀；ImageIO 能解码时直接生成小图，不能解码就回退文件图标。
    static func jpegData(from data: Data, isFinal: Bool, maxPixelSize: Int = 360) async -> Data? {
        let task = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled, !data.isEmpty else { return nil }
            if let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ), let rendered = renderJPEG(source: source, maxPixelSize: maxPixelSize) {
                return rendered
            }
            guard !Task.isCancelled else { return nil }
            let source = CGImageSourceCreateIncremental(nil)
            CGImageSourceUpdateData(source, data as CFData, isFinal)
            return renderJPEG(source: source, maxPixelSize: maxPixelSize)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func renderJPEG(source: CGImageSource, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard !Task.isCancelled,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
    }
}

private extension DriveFileEntry {
    var directoryChildren: [DriveFileEntry]? {
        let directories = children.filter { !$0.isFile }
        return directories.isEmpty ? nil : directories
    }
}

// 相册照片维持既有文件表示；网盘视频由上方 Photos 资源流直接上传，不经过此暂存类型。
private enum DrivePhotoLibraryAccess {
    static func requestReadAccessIfNeeded() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let updated = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return updated == .authorized || updated == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

private struct DrivePickedImageFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(url: try ChatAttachmentStaging.copyTransferredFile(received.file, fallbackExtension: "jpg"))
        }
    }
}

enum DriveAddDestination: Equatable {
    case createDirectory
    case photos
    case files
}

// [修改] 先完整关闭「添加」Sheet，再展示相册/文件/新建弹层，禁止两个系统弹层重叠。
struct DriveAddPresentationState: Equatable {
    private(set) var isSourcePickerPresented = false
    private(set) var presentedDestination: DriveAddDestination?
    private var pendingDestination: DriveAddDestination?

    mutating func showSourcePicker() {
        guard presentedDestination == nil else { return }
        pendingDestination = nil
        isSourcePickerPresented = true
    }

    mutating func setSourcePickerPresented(_ isPresented: Bool) {
        if isPresented {
            showSourcePicker()
        } else {
            isSourcePickerPresented = false
        }
    }

    mutating func select(_ destination: DriveAddDestination) {
        pendingDestination = destination
        isSourcePickerPresented = false
    }

    mutating func sourcePickerDidDismiss() {
        guard presentedDestination == nil, let pendingDestination else { return }
        self.pendingDestination = nil
        presentedDestination = pendingDestination
    }

    mutating func setDestinationPresented(
        _ isPresented: Bool,
        destination: DriveAddDestination
    ) {
        if isPresented {
            guard !isSourcePickerPresented else { return }
            pendingDestination = nil
            presentedDestination = destination
        } else if presentedDestination == destination {
            presentedDestination = nil
        }
    }
}

private struct DriveAddSourcePicker: View {
    let onSelect: (DriveAddDestination) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(.createDirectory)
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Button {
                    onSelect(.photos)
                } label: {
                    Label("从相册选择", systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    onSelect(.files)
                } label: {
                    Label("从文件选择", systemImage: "folder.fill")
                }
            }
            .navigationTitle("添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}
