import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UniformTypeIdentifiers

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
    @ObservationIgnored private let resourceLoader: SessionAssetResourceLoader
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
        let loader = SessionAssetResourceLoader(
            data: data,
            contentTypes: Self.contentTypes(metadata: metadata, resourcePath: resourcePath)
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
        let loader = SessionAssetResourceLoader(
            session: session,
            contentLength: byteSize,
            contentTypes: Self.contentTypes(metadata: metadata, resourcePath: resourcePath)
        )
        try self.init(loader: loader, resourcePath: resourcePath)
    }

    private init(loader: SessionAssetResourceLoader, resourcePath: String) throws {
        let url = try Self.assetURL(resourcePath: resourcePath)
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

    private static func contentTypes(
        metadata: ResourceMetadata,
        resourcePath: String
    ) -> [String] {
        var identifiers: [String] = []
        func append(_ type: UTType?) {
            guard let identifier = type?.identifier,
                  !identifiers.contains(identifier) else { return }
            identifiers.append(identifier)
        }

        if let identifier = metadata.typeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty {
            append(UTType(identifier))
        }
        if let mimeType = metadata.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mimeType.isEmpty {
            append(UTType(mimeType: mimeType))
        }
        let pathExtension = URL(fileURLWithPath: resourcePath).pathExtension
        if !pathExtension.isEmpty {
            append(UTType(filenameExtension: pathExtension))
        }
        if identifiers.isEmpty {
            identifiers.append(UTType.data.identifier)
        }
        return identifiers
    }

    private static func assetURL(resourcePath: String) throws -> URL {
        let pathExtension = URL(fileURLWithPath: resourcePath)
            .pathExtension
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        var components = URLComponents()
        components.scheme = "iosremotefolder-media"
        components.host = "asset"
        components.path = "/\(UUID().uuidString)\(suffix)"
        guard let url = components.url else {
            throw ResourceSourceError.invalidReference
        }
        return url
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

private final class SessionAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let chunkByteBudget: Int64 = 4 * 1024 * 1024

    private enum Backing: Sendable {
        case memory(Data)
        case session(ResourceContentSession)
    }

    /// Queue-confined state. The Objective-C request never crosses into a Swift Task.
    private final class LoadingState {
        let token = UUID()
        let request: AVAssetResourceLoadingRequest
        let endOffset: Int64
        var nextOffset: Int64
        var task: Task<Void, Never>?
        var isTerminal = false

        init(
            request: AVAssetResourceLoadingRequest,
            nextOffset: Int64,
            endOffset: Int64
        ) {
            self.request = request
            self.nextOffset = nextOffset
            self.endOffset = endOffset
        }
    }

    let queue = DispatchQueue(label: "iosRemoteFolder.media-resource-loader")

    private let backing: Backing
    private let contentLength: Int64
    private let contentTypes: [String]
    private var invalidated = false
    private var loadingStates: [ObjectIdentifier: LoadingState] = [:]

    init(data: Data, contentTypes: [String]) {
        self.backing = .memory(data)
        self.contentLength = Int64(data.count)
        self.contentTypes = contentTypes
    }

    init(
        session: ResourceContentSession,
        contentLength: Int64,
        contentTypes: [String]
    ) {
        self.backing = .session(session)
        self.contentLength = contentLength
        self.contentTypes = contentTypes
    }

    var isSessionBacked: Bool {
        if case .session = backing { return true }
        return false
    }

    func invalidate() {
        queue.async { [self] in
            invalidateOnQueue()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !invalidated else {
            loadingRequest.finishLoading(with: Self.cancelledError)
            return true
        }

        if let contentInformationRequest = loadingRequest.contentInformationRequest {
            guard let negotiatedType = negotiatedContentType(
                allowedTypes: contentInformationRequest.allowedContentTypes
            ) else {
                loadingRequest.finishLoading(with: Self.unsupportedContentTypeError)
                return true
            }
            contentInformationRequest.contentType = negotiatedType
            contentInformationRequest.contentLength = contentLength
            contentInformationRequest.isByteRangeAccessSupported = true
            contentInformationRequest.isEntireLengthAvailableOnDemand = !isSessionBacked
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let identifier = ObjectIdentifier(loadingRequest)
        guard loadingStates[identifier] == nil else {
            loadingRequest.finishLoading(with: Self.invalidRangeError)
            return true
        }
        do {
            let bounds = try requestedBounds(for: dataRequest)
            let state = LoadingState(
                request: loadingRequest,
                nextOffset: bounds.lowerBound,
                endOffset: bounds.upperBound
            )
            loadingStates[identifier] = state
            startNextChunkOnQueue(identifier: identifier, token: state.token)
        } catch {
            loadingRequest.finishLoading(
                with: ResourceSourceError.mapping(error) as NSError
            )
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let identifier = ObjectIdentifier(loadingRequest)
        guard let state = loadingStates.removeValue(forKey: identifier),
              !state.isTerminal else { return }
        state.isTerminal = true
        state.task?.cancel()
        state.task = nil
    }

    private func requestedBounds(
        for dataRequest: AVAssetResourceLoadingDataRequest
    ) throws -> Range<Int64> {
        dispatchPrecondition(condition: .onQueue(queue))
        let requestedOffset = dataRequest.requestedOffset
        let currentOffset = dataRequest.currentOffset
        let startOffset = currentOffset == 0 ? requestedOffset : currentOffset
        guard requestedOffset >= 0,
              startOffset >= requestedOffset,
              startOffset <= contentLength else {
            throw ResourceSourceError.invalidResponse
        }

        let endOffset: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            endOffset = contentLength
        } else {
            guard let requestedLength = Int64(exactly: dataRequest.requestedLength),
                  requestedLength >= 0 else {
                throw ResourceSourceError.invalidResponse
            }
            let (requestedEnd, overflow) = requestedOffset.addingReportingOverflow(requestedLength)
            guard !overflow, requestedEnd >= requestedOffset else {
                throw ResourceSourceError.invalidResponse
            }
            endOffset = min(requestedEnd, contentLength)
        }
        guard startOffset <= endOffset else {
            throw ResourceSourceError.invalidResponse
        }
        return startOffset..<endOffset
    }

    private func startNextChunkOnQueue(
        identifier: ObjectIdentifier,
        token: UUID
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let state = loadingStates[identifier],
              state.token == token,
              !state.isTerminal else { return }
        guard !invalidated else {
            completeOnQueue(
                identifier: identifier,
                token: token,
                error: .cancelled
            )
            return
        }
        guard !state.request.isCancelled, !state.request.isFinished else {
            abandonOnQueue(identifier: identifier, token: token)
            return
        }
        guard state.nextOffset < state.endOffset else {
            completeOnQueue(identifier: identifier, token: token, error: nil)
            return
        }

        let remaining = state.endOffset - state.nextOffset
        let length = min(Self.chunkByteBudget, remaining)
        let range = ResourceByteRange(
            lowerBound: state.nextOffset,
            upperBound: state.nextOffset + length - 1
        )

        switch backing {
        case .memory(let data):
            let result: Result<Data, ResourceSourceError>
            if let lowerBound = Int(exactly: range.lowerBound),
               let upperBound = Int(exactly: range.upperBound + 1),
               lowerBound >= 0,
               upperBound <= data.count {
                result = .success(data.subdata(in: lowerBound..<upperBound))
            } else {
                result = .failure(.invalidResponse)
            }
            receiveChunkOnQueue(
                result,
                range: range,
                identifier: identifier,
                token: token
            )

        case .session(let session):
            let deliveryQueue = queue
            let task = Task { [weak self] in
                let result: Result<Data, ResourceSourceError>
                do {
                    try Task.checkCancellation()
                    let data = try await session.readData(
                        range: range,
                        maximumBytes: Self.chunkByteBudget
                    )
                    try Task.checkCancellation()
                    result = .success(data)
                } catch {
                    result = .failure(
                        Task.isCancelled || error is CancellationError
                            ? .cancelled
                            : ResourceSourceError.mapping(error)
                    )
                }
                deliveryQueue.async { [weak self] in
                    self?.receiveChunkOnQueue(
                        result,
                        range: range,
                        identifier: identifier,
                        token: token
                    )
                }
            }
            state.task = task
        }
    }

    private func receiveChunkOnQueue(
        _ result: Result<Data, ResourceSourceError>,
        range: ResourceByteRange,
        identifier: ObjectIdentifier,
        token: UUID
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let state = loadingStates[identifier],
              state.token == token,
              !state.isTerminal else { return }
        state.task = nil
        guard !invalidated else {
            completeOnQueue(
                identifier: identifier,
                token: token,
                error: .cancelled
            )
            return
        }
        guard !state.request.isCancelled, !state.request.isFinished else {
            abandonOnQueue(identifier: identifier, token: token)
            return
        }

        switch result {
        case .failure(let error):
            completeOnQueue(identifier: identifier, token: token, error: error)

        case .success(let data):
            guard let expectedLength = range.validatedLength,
                  Int64(data.count) == expectedLength,
                  let dataRequest = state.request.dataRequest else {
                completeOnQueue(
                    identifier: identifier,
                    token: token,
                    error: .invalidResponse
                )
                return
            }
            let currentOffset = dataRequest.currentOffset == 0
                ? dataRequest.requestedOffset
                : dataRequest.currentOffset
            guard currentOffset == range.lowerBound else {
                completeOnQueue(
                    identifier: identifier,
                    token: token,
                    error: .invalidResponse
                )
                return
            }

            dataRequest.respond(with: data)
            let expectedNextOffset = range.upperBound + 1
            guard dataRequest.currentOffset == expectedNextOffset else {
                completeOnQueue(
                    identifier: identifier,
                    token: token,
                    error: .invalidResponse
                )
                return
            }
            state.nextOffset = expectedNextOffset
            startNextChunkOnQueue(identifier: identifier, token: token)
        }
    }

    private func completeOnQueue(
        identifier: ObjectIdentifier,
        token: UUID,
        error: ResourceSourceError?
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let state = loadingStates[identifier],
              state.token == token,
              !state.isTerminal else { return }
        state.isTerminal = true
        state.task?.cancel()
        state.task = nil
        loadingStates.removeValue(forKey: identifier)

        guard !state.request.isCancelled, !state.request.isFinished else { return }
        if let error {
            state.request.finishLoading(with: error as NSError)
        } else {
            state.request.finishLoading()
        }
    }

    private func abandonOnQueue(identifier: ObjectIdentifier, token: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let state = loadingStates[identifier],
              state.token == token,
              !state.isTerminal else { return }
        state.isTerminal = true
        state.task?.cancel()
        state.task = nil
        loadingStates.removeValue(forKey: identifier)
    }

    private func invalidateOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !invalidated else { return }
        invalidated = true

        for (identifier, state) in Array(loadingStates) {
            completeOnQueue(
                identifier: identifier,
                token: state.token,
                error: .cancelled
            )
        }
        if case .session(let session) = backing {
            Task { await session.close() }
        }
    }

    private func negotiatedContentType(allowedTypes: [String]?) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let allowedTypes, !allowedTypes.isEmpty else {
            return contentTypes.first
        }

        for contentType in contentTypes where allowedTypes.contains(contentType) {
            return contentType
        }
        for allowedIdentifier in allowedTypes {
            guard let allowedType = UTType(allowedIdentifier) else { continue }
            for contentIdentifier in contentTypes {
                guard let actualType = UTType(contentIdentifier) else { continue }
                if actualType == allowedType || actualType.conforms(to: allowedType) {
                    return allowedIdentifier
                }
            }
        }
        return nil
    }

    private static let cancelledError = NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorCancelled
    )

    private static let unsupportedContentTypeError = ResourceSourceError
        .capabilityUnavailable as NSError

    private static let invalidRangeError = ResourceSourceError.invalidResponse as NSError

}
