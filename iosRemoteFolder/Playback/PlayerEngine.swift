import AVFoundation
import Foundation
import MediaPlayer
import Observation

@MainActor
protocol PlayerEngine: AnyObject {
    var player: AVPlayer { get }
    func load(url: URL)
    func play()
    func pause()
}

@MainActor
final class AVPlayerEngine: PlayerEngine {
    let player = AVPlayer()

    func load(url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }
}

/// Owns Foundation notification tokens without exposing their non-Sendable
/// representation to `AVMediaPlayerEngine`'s nonisolated deinitializer.
private final class NotificationObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    func append(_ observer: NSObjectProtocol) {
        lock.lock()
        observers.append(observer)
        lock.unlock()
    }

    func removeAll() {
        let removedObservers: [NSObjectProtocol]
        lock.lock()
        removedObservers = observers
        observers.removeAll()
        lock.unlock()

        for observer in removedObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    deinit {
        removeAll()
    }
}

/// AVPlayer bridge for both bounded in-memory media and session-backed Range media.
/// Source adapters, URLs and credentials remain behind `ResourceContentSession`.
@MainActor
@Observable
final class AVMediaPlayerEngine {
    enum PlaybackState: Equatable, Sendable {
        case preparing
        case waiting
        case playing
        case paused
        case failed(ResourceSourceError)
        case ended
        case stopped
    }

    /// 整个媒体准备流程（asset 属性加载 + item 就绪，含流式分片读取）的
    /// 默认总时限。超时给出可重试的明确错误，而不是无限等待。
    static let defaultPreparationTimeoutSeconds: TimeInterval = 120

    private(set) var playbackState: PlaybackState = .preparing

    @ObservationIgnored let player: AVPlayer

    @ObservationIgnored private let asset: AVURLAsset
    @ObservationIgnored private let resourceLoader: MediaResourceLoaderBridge
    @ObservationIgnored private var preparedDuration: TimeInterval = 0
    @ObservationIgnored private var isPrepared = false
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var didReachEnd = false
    @ObservationIgnored private var runtimeFailure: ResourceSourceError?
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var monitoringGeneration = UUID()
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var preparationWatchdog: Task<Void, Never>?
    @ObservationIgnored private var didHitPreparationDeadline = false
    @ObservationIgnored private let notificationObservers = NotificationObserverBag()

    convenience init(data: Data, metadata: ResourceMetadata, resourcePath: String) throws {
        guard !data.isEmpty else { throw ResourceSourceError.invalidResponse }
        let loader = MediaResourceLoaderBridge(
            data: data,
            contentTypes: MediaResourceLoaderBridge.contentTypes(
                metadata: metadata,
                resourcePath: resourcePath
            )
        )
        try self.init(loader: loader, resourcePath: resourcePath)
    }

    convenience init(
        session: ResourceContentSession,
        metadata: ResourceMetadata,
        resourcePath: String
    ) throws {
        guard let byteSize = metadata.byteSize,
              byteSize > 0,
              metadata.acceptsRanges else {
            throw ResourceSourceError.capabilityUnavailable
        }
        let loader = MediaResourceLoaderBridge(
            session: session,
            contentLength: byteSize,
            contentTypes: MediaResourceLoaderBridge.contentTypes(
                metadata: metadata,
                resourcePath: resourcePath
            )
        )
        try self.init(loader: loader, resourcePath: resourcePath)
    }

    private init(loader: MediaResourceLoaderBridge, resourcePath: String) throws {
        let url = try MediaResourceLoaderBridge.assetURL(resourcePath: resourcePath)
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        self.asset = asset
        self.resourceLoader = loader
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player.automaticallyWaitsToMinimizeStalling = false
        startRuntimeMonitoring()
    }

    var duration: TimeInterval {
        if preparedDuration > 0 { return preparedDuration }
        guard let duration = player.currentItem?.duration,
              duration.isNumeric else { return 0 }
        return max(0, duration.seconds)
    }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    var isPlaying: Bool {
        playbackState == .playing
    }

    /// 统一 deadline 覆盖从 asset 属性加载到 item 就绪的完整准备流程；
    /// 到期由 watchdog 取消 asset 加载并映射为 `.timedOut`，保留失败重试。
    /// 调用方不传 deadline 时使用默认总时限。
    func prepare(
        expectedMediaType: AVMediaType,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        playbackState = .preparing
        let preparationDeadline = deadline
            ?? ContinuousClock().now + .seconds(Self.defaultPreparationTimeoutSeconds)
        startPreparationWatchdog(deadline: preparationDeadline)
        defer {
            preparationWatchdog?.cancel()
            preparationWatchdog = nil
        }
        do {
            try ensureActive()
            try ensureWithinDeadline(preparationDeadline)
            let isPlayable = try await asset.load(.isPlayable)
            try ensureActive()
            try ensureWithinDeadline(preparationDeadline)
            guard isPlayable else { throw ResourceSourceError.invalidResponse }
            let tracks = try await asset.load(.tracks)
            try ensureActive()
            try ensureWithinDeadline(preparationDeadline)
            guard tracks.contains(where: { $0.mediaType == expectedMediaType }) else {
                throw ResourceSourceError.invalidResponse
            }
            let duration = try await asset.load(.duration)
            try ensureActive()
            try ensureWithinDeadline(preparationDeadline)
            guard duration.isNumeric, duration.seconds > 0 else {
                throw ResourceSourceError.invalidResponse
            }
            preparedDuration = duration.seconds
            try await waitUntilReadyToPlay(deadline: preparationDeadline)
            try ensureActive()
            isPrepared = true
            refreshPlaybackState()
        } catch {
            // 调用方取消优先于 deadline；watchdog 取消 asset 加载产生的
            // cancellation 不得伪装成用户取消。
            if Task.isCancelled || isStopped {
                stop()
                throw ResourceSourceError.cancelled
            }
            if didHitPreparationDeadline
                || ResourceSourceError.mapping(error) == .timedOut {
                runtimeFailure = .timedOut
                playbackState = .failed(.timedOut)
                throw ResourceSourceError.timedOut
            }
            let mapped = ResourceSourceError.mapping(error)
            if mapped == .cancelled {
                stop()
                throw ResourceSourceError.cancelled
            }
            runtimeFailure = mapped
            playbackState = .failed(mapped)
            throw mapped
        }
    }

    @discardableResult
    func play() -> Bool {
        guard isPrepared, !isStopped else { return false }
        if case .failed = playbackState { return false }
        if playbackState == .ended {
            didReachEnd = false
            player.seek(to: .zero)
        }
        player.play()
        refreshPlaybackState()
        return true
    }

    func pause() {
        guard isPrepared, !isStopped else { return }
        if case .failed = playbackState { return }
        player.pause()
        refreshPlaybackState()
    }

    func seek(to time: TimeInterval) {
        seek(to: time, completion: nil)
    }

    func seek(
        to time: TimeInterval,
        completion: (@MainActor @Sendable (_ finished: Bool) -> Void)?
    ) {
        guard isPrepared, !isStopped, duration > 0 else {
            completion?(false)
            return
        }
        if case .failed = playbackState {
            completion?(false)
            return
        }
        seekGeneration &+= 1
        let generation = seekGeneration
        let clamped = min(max(time, 0), duration)
        if clamped < duration {
            didReachEnd = false
        }
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completionHandler: { [weak self] finished in
                Task { @MainActor in
                    guard let self else {
                        completion?(false)
                        return
                    }
                    completion?(
                        finished
                            && !self.isStopped
                            && self.seekGeneration == generation
                    )
                }
            }
        )
        refreshPlaybackState()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        isPrepared = false
        didReachEnd = false
        runtimeFailure = nil
        seekGeneration &+= 1
        monitoringGeneration = UUID()
        monitoringTask?.cancel()
        monitoringTask = nil
        preparationWatchdog?.cancel()
        preparationWatchdog = nil
        removeNotificationObservers()
        asset.cancelLoading()
        resourceLoader.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playbackState = .stopped
    }

    deinit {
        monitoringTask?.cancel()
        preparationWatchdog?.cancel()
        notificationObservers.removeAll()
        asset.cancelLoading()
        resourceLoader.invalidate()
    }

    private func ensureActive() throws {
        guard !isStopped, !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }
    }

    private func ensureWithinDeadline(_ deadline: ContinuousClock.Instant) throws {
        guard !didHitPreparationDeadline, ContinuousClock().now < deadline else {
            throw ResourceSourceError.timedOut
        }
    }

    /// Deadline watchdog：到期后取消 asset 加载，让挂起的 `load(...)` 与
    /// 分片读取立即返回；`prepare` 的 catch 依据标志映射为 `.timedOut`。
    private func startPreparationWatchdog(deadline: ContinuousClock.Instant) {
        preparationWatchdog?.cancel()
        didHitPreparationDeadline = false
        preparationWatchdog = Task { @MainActor [weak self] in
            try? await ContinuousClock().sleep(until: deadline)
            guard !Task.isCancelled,
                  let self,
                  !self.isStopped,
                  !self.isPrepared else { return }
            self.didHitPreparationDeadline = true
            self.asset.cancelLoading()
        }
    }

    private func waitUntilReadyToPlay(deadline: ContinuousClock.Instant) async throws {
        guard let item = player.currentItem else {
            throw ResourceSourceError.invalidResponse
        }
        let clock = ContinuousClock()

        while clock.now < deadline, !didHitPreparationDeadline {
            try ensureActive()
            guard player.currentItem === item else {
                throw ResourceSourceError.cancelled
            }
            switch item.status {
            case .readyToPlay:
                try ensureActive()
                return
            case .failed:
                throw mappedItemError(item)
            case .unknown:
                break
            @unknown default:
                throw ResourceSourceError.invalidResponse
            }

            do {
                try await clock.sleep(for: .milliseconds(100))
            } catch {
                try ensureActive()
                throw ResourceSourceError.mapping(error)
            }
        }

        try ensureActive()
        throw ResourceSourceError.timedOut
    }

    private func startRuntimeMonitoring() {
        guard let item = player.currentItem else { return }
        let generation = UUID()
        monitoringGeneration = generation

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          !self.isStopped,
                          self.monitoringGeneration == generation,
                          self.runtimeFailure == nil else { return }
                    self.didReachEnd = true
                    self.playbackState = .ended
                }
            }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] notification in
                let underlyingError = notification.userInfo?[
                    AVPlayerItemFailedToPlayToEndTimeErrorKey
                ] as? any Error
                let mapped = underlyingError.map {
                    ResourceSourceError.mapping($0)
                } ?? .invalidResponse
                MainActor.assumeIsolated {
                    guard let self,
                          !self.isStopped,
                          self.monitoringGeneration == generation else { return }
                    self.runtimeFailure = mapped
                    self.playbackState = .failed(mapped)
                }
            }
        )

        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self,
                      !self.isStopped,
                      self.monitoringGeneration == generation else { return }
                self.refreshPlaybackState()
            }
        }
    }

    private func refreshPlaybackState() {
        guard !isStopped else {
            playbackState = .stopped
            return
        }
        guard let item = player.currentItem else {
            playbackState = .failed(.invalidResponse)
            return
        }
        if item.status == .failed {
            let mapped = mappedItemError(item)
            runtimeFailure = mapped
            playbackState = .failed(mapped)
            return
        }
        if let runtimeFailure {
            playbackState = .failed(runtimeFailure)
            return
        }
        guard isPrepared else {
            playbackState = .preparing
            return
        }
        if didReachEnd {
            playbackState = .ended
            return
        }

        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            playbackState = .waiting
        case .playing:
            playbackState = .playing
        case .paused:
            playbackState = .paused
        @unknown default:
            playbackState = .paused
        }
    }

    private func mappedItemError(_ item: AVPlayerItem) -> ResourceSourceError {
        item.error.map { ResourceSourceError.mapping($0) } ?? .invalidResponse
    }

    private func removeNotificationObservers() {
        notificationObservers.removeAll()
    }

}

/// 系统媒体集成：AVAudioSession 播放会话、Now Playing 信息与锁屏/耳机远程控制。
///
/// 只有真正呈现给用户的播放器视图才持有并激活本控制器；缓存校验、内容
/// 探测等临时引擎不注册系统媒体状态。音频在后台继续播放（配合
/// `UIBackgroundModes: audio`）；视频遵循系统默认的后台暂停行为，但同样
/// 获得静音开关下有声与耳机线控。
/// Owns remote command targets behind a lock so cleanup stays safe even from
/// a nonisolated deinitializer; the normal path is an explicit `deactivate()`.
private final class RemoteCommandTargetBag: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [(command: MPRemoteCommand, target: Any)] = []

    func append(_ command: MPRemoteCommand, target: Any) {
        lock.lock()
        targets.append((command, target))
        lock.unlock()
    }

    func removeAll() {
        let removed: [(command: MPRemoteCommand, target: Any)]
        lock.lock()
        removed = targets
        targets.removeAll()
        lock.unlock()
        for entry in removed {
            entry.command.removeTarget(entry.target)
        }
    }

    deinit {
        removeAll()
    }
}

@MainActor
final class MediaNowPlayingController {
    /// 当前持有全局 Now Playing 信息的控制器；注销时只有持有者才允许
    /// 清空全局状态，防止视图交叠时后激活者被先注销者清场。
    private static weak var activeOwner: MediaNowPlayingController?

    private weak var engine: AVMediaPlayerEngine?
    private let commandTargets = RemoteCommandTargetBag()
    private let sessionObservers = NotificationObserverBag()
    private var isActive = false
    private var didActivateAudioSession = false
    private var title = ""
    private var isVideo = false

    func activate(title: String, engine: AVMediaPlayerEngine, isVideo: Bool) {
        deactivate()
        self.engine = engine
        self.title = title
        self.isVideo = isVideo
        isActive = true
        Self.activeOwner = self

        // 只设置类别；会话激活推迟到真正开始播放，
        // 打开查看器页面不打断其他 App 正在播放的音频。
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: isVideo ? .moviePlayback : .default
        )

        registerCommands()
        observeSessionNotifications()
        refresh()
    }

    /// 播放状态或进度跳变后同步锁屏信息；系统按 rate 自行推进 elapsed，
    /// 因此只需要在状态变化和 seek 后调用，不需要按帧刷新。
    func refresh() {
        guard isActive, let engine, Self.activeOwner === self else { return }
        if engine.isPlaying, !didActivateAudioSession {
            didActivateAudioSession = true
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: (isVideo
                ? MPNowPlayingInfoMediaType.video
                : MPNowPlayingInfoMediaType.audio).rawValue
        ]
        if engine.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = engine.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func deactivate() {
        commandTargets.removeAll()
        sessionObservers.removeAll()
        guard isActive else { return }
        isActive = false
        engine = nil
        if Self.activeOwner === self {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            Self.activeOwner = nil
        }
        if didActivateAudioSession {
            didActivateAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        register(center.playCommand) { engine in
            engine.play() ? .success : .commandFailed
        }
        register(center.pauseCommand) { engine in
            engine.pause()
            return .success
        }
        register(center.togglePlayPauseCommand) { engine in
            if engine.isPlaying {
                engine.pause()
                return .success
            }
            return engine.play() ? .success : .commandFailed
        }

        center.skipForwardCommand.preferredIntervals = [10]
        register(center.skipForwardCommand) { engine in
            engine.seek(to: engine.currentTime + 10)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        register(center.skipBackwardCommand) { engine in
            engine.seek(to: engine.currentTime - 10)
            return .success
        }
        register(center.changePlaybackPositionCommand) { engine, event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            engine.seek(to: positionEvent.positionTime)
            return .success
        }
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping @MainActor (AVMediaPlayerEngine) -> MPRemoteCommandHandlerStatus
    ) {
        register(command) { engine, _ in handler(engine) }
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping @MainActor (AVMediaPlayerEngine, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget { [weak self] event in
            // MPRemoteCommandCenter 在主线程回调。
            MainActor.assumeIsolated {
                guard let self, self.isActive, let engine = self.engine else {
                    return .noActionableNowPlayingItem
                }
                let status = handler(engine, event)
                self.refresh()
                return status
            }
        }
        commandTargets.append(command, target: target)
    }

    // MARK: - Session notifications

    private func observeSessionNotifications() {
        sessionObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let userInfo = notification.userInfo
                let typeValue = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsValue = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self, self.isActive, let engine = self.engine else { return }
                    switch typeValue.flatMap(AVAudioSession.InterruptionType.init) {
                    case .began:
                        engine.pause()
                    case .ended:
                        let options = AVAudioSession.InterruptionOptions(
                            rawValue: optionsValue ?? 0
                        )
                        if options.contains(.shouldResume) {
                            _ = engine.play()
                        }
                    default:
                        break
                    }
                    self.refresh()
                }
            }
        )
        sessionObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self, self.isActive, let engine = self.engine else { return }
                    // 拔出耳机等旧输出设备不可用时暂停，避免外放泄漏。
                    if reasonValue.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable {
                        engine.pause()
                        self.refresh()
                    }
                }
            }
        )
    }
}
