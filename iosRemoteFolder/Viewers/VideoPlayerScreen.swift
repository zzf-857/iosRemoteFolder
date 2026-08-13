import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 沉浸式视频查看器：可见按钮覆盖所有核心操作，手势作为快捷路径。
/// 左双击后退、右双击前进是 VLC/Infuse 等常见 iOS 播放器约定。
@MainActor
struct VideoPlayerScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    let resource: ResourceItem
    let metadata: ResourceMetadata
    let engine: AVMediaPlayerEngine
    let onRetry: () -> Void

    @State private var restoredPosition = false
    @State private var nowPlaying = MediaNowPlayingController()
    @State private var orientationPolicy = OrientationPolicy.shared
    @State private var controlsVisible = true
    @State private var isLocked = false
    @State private var lockHintVisible = false
    @State private var gestureAdjustment: GestureAdjustment?
    @State private var scrubStartTime: TimeInterval = 0
    @State private var scrubPreviewTime: TimeInterval?
    @State private var brightnessStart: CGFloat = 0
    @State private var videoVolumeStart: Float = 1
    @State private var playerScene: UIWindowScene?
    @State private var playbackScreen: UIScreen?
    @State private var entryBrightness: CGFloat?
    @State private var didAdjustBrightness = false
    @State private var feedback: PlayerFeedback?
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var lockHintTask: Task<Void, Never>?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var pendingSeekTime: TimeInterval?
    @State private var seekGeneration = 0
    @State private var playbackIntentRevision = 0
    @State private var isSliderScrubbing = false
    @State private var isPresented = false
    @State private var didBeginOrientationPolicy = false

    fileprivate enum GestureAdjustment: Equatable {
        case brightness(CGFloat)
        case volume(Float)
        case scrub(target: TimeInterval, delta: TimeInterval)
    }

    fileprivate struct PlayerFeedback: Equatable {
        enum Kind: Equatable { case backward, forward, brightness, volume, scrub, locked, error }
        let kind: Kind
        let value: String
        let revision: Int
    }

    private var scene: UIWindowScene? { playerScene }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            GeometryReader { proxy in
                ZStack {
                    Color.black.ignoresSafeArea()
                    VideoSurfaceView(player: engine.player, onSceneChange: handleSceneChange)
                        .ignoresSafeArea()
                        .accessibilityLabel("\(resource.name)，视频画面")
                        .accessibilityAction(named: "提高亮度") {
                            adjustBrightness(by: 0.1)
                        }
                        .accessibilityAction(named: "降低亮度") {
                            adjustBrightness(by: -0.1)
                        }
                        .accessibilityAction(named: "提高视频音量") {
                            adjustVideoVolume(by: 0.1)
                        }
                        .accessibilityAction(named: "降低视频音量") {
                            adjustVideoVolume(by: -0.1)
                        }

                    if isLocked {
                        lockedInteractionLayer(safeArea: proxy.safeAreaInsets)
                    } else {
                        gestureLayer(size: proxy.size)
                        if controlsVisible {
                            controlsOverlay(safeArea: proxy.safeAreaInsets)
                        }
                    }

                    if let gestureAdjustment, gestureAdjustment.showsHUD {
                        AdjustmentHUD(adjustment: gestureAdjustment, duration: engine.duration)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if let feedback {
                        PlayerFeedbackHUD(feedback: feedback)
                            .id(feedback.revision)
                            .allowsHitTesting(false)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controlsVisible)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isLocked)
            }
        }
        .background(Color.black)
        .statusBarHidden(!controlsVisible || isLocked)
        .persistentSystemOverlays((controlsVisible && !isLocked) ? .automatic : .hidden)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar, .tabBar)
        .onAppear {
            isPresented = true
            activatePlayerSceneIfNeeded()
            nowPlaying.activate(title: resource.name, engine: engine, isVideo: true)
            restorePositionIfNeeded()
            scheduleControlsAutoHide()
        }
        .onDisappear {
            isPresented = false
            controlsHideTask?.cancel()
            lockHintTask?.cancel()
            feedbackTask?.cancel()
            savePosition()
            restoreBrightnessIfNeeded()
            engine.stop()
            nowPlaying.deactivate()
            if didBeginOrientationPolicy {
                orientationPolicy.end(in: scene)
                didBeginOrientationPolicy = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                savePosition()
                restoreBrightnessIfNeeded()
            }
        }
        .onChange(of: engine.playbackState) { _, state in
            nowPlaying.refresh()
            if state == .playing, controlsVisible, !isLocked, !voiceOverEnabled {
                scheduleControlsAutoHide()
            }
            if state.disablesControls {
                isSliderScrubbing = false
                scrubPreviewTime = nil
                gestureAdjustment = nil
            }
            if case .failed(let error) = state {
                seekGeneration &+= 1
                pendingSeekTime = nil
                restoreBrightnessIfNeeded()
                controlsVisible = true
                isLocked = false
                orientationPolicy.unlock(in: scene)
                showFeedback(.error, value: error.localizedDescription)
            }
        }
        .onChange(of: orientationPolicy.errorDescription(in: scene)) { _, message in
            guard let message else { return }
            if isLocked, !orientationPolicy.isLocked(in: scene) {
                isLocked = false
                lockHintVisible = false
                lockHintTask?.cancel()
                controlsVisible = true
                scheduleControlsAutoHide()
            }
            showFeedback(.error, value: message)
            orientationPolicy.clearError(in: scene)
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled {
                controlsHideTask?.cancel()
                lockHintTask?.cancel()
                if isLocked {
                    lockHintVisible = true
                } else {
                    controlsVisible = true
                }
            } else if isLocked {
                showLockHint()
            } else {
                scheduleControlsAutoHide()
            }
        }
    }

    private func lockedInteractionLayer(safeArea: EdgeInsets) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { showLockHint() }
                .accessibilityElement()
                .accessibilityLabel("播放器已锁定")
                .accessibilityHint("轻点屏幕显示解除锁定按钮")
                .accessibilityAction { showLockHint() }

            if lockHintVisible {
                Button {
                    unlockPlayer()
                } label: {
                    Label("解除锁定", systemImage: "lock.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.top, max(8, safeArea.top + 8))
                .padding(.leading, max(8, safeArea.leading + 8))
                .accessibilityLabel("解除播放器锁定")
                .accessibilityHint("恢复播放器手势和旋转")
            }
        }
    }

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .exclusively(before: SpatialTapGesture(count: 1))
                    .onEnded { result in
                        switch result {
                        case .first(let event):
                            handleDoubleTap(at: event.location, width: size.width)
                        case .second:
                            toggleControls()
                        }
                    }
            )
            .simultaneousGesture(adjustmentGesture(size: size))
            .accessibilityHidden(true)
    }

    private func handleSceneChange(_ newScene: UIWindowScene?) {
        guard let newScene else { return }
        if playerScene !== newScene {
            restoreBrightnessIfNeeded()
            if let playerScene, didBeginOrientationPolicy {
                orientationPolicy.end(in: playerScene)
                didBeginOrientationPolicy = false
            }
            playerScene = newScene
            let screen = newScene.screen
            playbackScreen = screen === UIScreen.main ? screen : nil
            entryBrightness = playbackScreen?.brightness
            didAdjustBrightness = false
        }
        activatePlayerSceneIfNeeded()
    }

    private func activatePlayerSceneIfNeeded() {
        guard isPresented, let playerScene, !didBeginOrientationPolicy else { return }
        orientationPolicy.begin(in: playerScene)
        didBeginOrientationPolicy = true
    }

    private func adjustmentGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard engine.duration > 0 else { return }
                if gestureAdjustment == nil {
                    let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.35
                    let vertical = abs(value.translation.height) > abs(value.translation.width) * 1.35
                    guard horizontal || vertical else { return }
                    if horizontal {
                        scrubStartTime = pendingSeekTime ?? engine.currentTime
                        updateScrub(value.translation.width, width: size.width)
                    } else if value.startLocation.x < size.width / 2 {
                        guard let playbackScreen else { return }
                        brightnessStart = playbackScreen.brightness
                        updateBrightness(value.translation.height, height: size.height)
                    } else {
                        videoVolumeStart = engine.player.volume
                        updateVolume(value.translation.height, height: size.height)
                    }
                } else {
                    switch gestureAdjustment {
                    case .brightness: updateBrightness(value.translation.height, height: size.height)
                    case .volume: updateVolume(value.translation.height, height: size.height)
                    case .scrub: updateScrub(value.translation.width, width: size.width)
                    case nil: break
                    }
                }
            }
            .onEnded { _ in
                guard let adjustment = gestureAdjustment else { return }
                if case .scrub(let target, _) = adjustment {
                    commitSeek(target)
                }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    gestureAdjustment = nil
                }
                scheduleControlsAutoHide()
            }
    }

    private func updateScrub(_ translation: CGFloat, width: CGFloat) {
        let span = min(engine.duration, 240)
        let delta = TimeInterval(translation / max(width, 1)) * span
        let target = min(max(scrubStartTime + delta, 0), engine.duration)
        gestureAdjustment = .scrub(target: target, delta: target - scrubStartTime)
    }

    private func updateBrightness(_ translation: CGFloat, height: CGFloat) {
        guard let playbackScreen else { return }
        let value = min(max(brightnessStart - translation / max(height, 1) * 1.2, 0), 1)
        playbackScreen.brightness = value
        didAdjustBrightness = true
        gestureAdjustment = .brightness(value)
    }

    private func updateVolume(_ translation: CGFloat, height: CGFloat) {
        let value = min(max(videoVolumeStart - Float(translation / max(height, 1) * 1.2), 0), 1)
        engine.player.volume = value
        gestureAdjustment = .volume(value)
    }

    private func adjustBrightness(by delta: CGFloat) {
        guard let playbackScreen else {
            showFeedback(.error, value: "当前屏幕不支持亮度调节")
            return
        }
        let value = min(max(playbackScreen.brightness + delta, 0), 1)
        playbackScreen.brightness = value
        didAdjustBrightness = true
        showFeedback(.brightness, value: "亮度 \(Int(value * 100))%")
    }

    private func adjustVideoVolume(by delta: Float) {
        let value = min(max(engine.player.volume + delta, 0), 1)
        engine.player.volume = value
        showFeedback(.volume, value: "视频音量 \(Int(value * 100))%")
    }

    private func handleDoubleTap(at location: CGPoint, width: CGFloat) {
        if location.x < width / 3 {
            let shouldResume = engine.playbackState.showsPauseControl
            commitSeek((pendingSeekTime ?? engine.currentTime) - 10, resumeAfterSeek: shouldResume)
            showFeedback(.backward, value: "后退 10 秒")
        } else if location.x > width * 2 / 3 {
            let shouldResume = engine.playbackState.showsPauseControl
            commitSeek((pendingSeekTime ?? engine.currentTime) + 10, resumeAfterSeek: shouldResume)
            showFeedback(.forward, value: "前进 10 秒")
        } else {
            togglePlayback()
        }
    }

    private func commitSeek(_ target: TimeInterval, resumeAfterSeek: Bool = true) {
        let clamped = min(max(target, 0), engine.duration)
        seekGeneration &+= 1
        let generation = seekGeneration
        let intentRevision = playbackIntentRevision
        pendingSeekTime = clamped
        engine.seek(to: clamped) { finished in
            guard seekGeneration == generation else { return }
            pendingSeekTime = nil
            guard isPresented else { return }
            if finished,
               playbackIntentRevision == intentRevision,
               resumeAfterSeek,
               engine.play() {
                scheduleControlsAutoHide()
            }
            nowPlaying.refresh()
        }
    }

    private func togglePlayback() {
        playbackIntentRevision &+= 1
        if engine.playbackState.showsPauseControl { engine.pause() } else { _ = engine.play() }
        nowPlaying.refresh()
        scheduleControlsAutoHide()
    }

    private func toggleControls() {
        guard !isLocked else { showLockHint(); return }
        controlsVisible.toggle()
        if controlsVisible { scheduleControlsAutoHide() } else { controlsHideTask?.cancel() }
    }

    private func scheduleControlsAutoHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !voiceOverEnabled,
                  controlsVisible, !isLocked,
                  engine.playbackState == .playing else { return }
            controlsVisible = false
        }
    }

    private func showLockHint() {
        lockHintTask?.cancel()
        lockHintVisible = true
        guard !voiceOverEnabled else {
            showFeedback(.locked, value: "播放器已锁定")
            return
        }
        lockHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            lockHintVisible = false
        }
        showFeedback(.locked, value: "播放器已锁定")
    }

    private func lockPlayer() {
        guard orientationPolicy.lockCurrentOrientation(in: scene) else {
            controlsVisible = true
            showFeedback(.error, value: "当前窗口尚未准备好，无法锁定方向")
            return
        }
        isLocked = true
        controlsVisible = false
        showLockHint()
    }

    private func unlockPlayer() {
        isLocked = false
        lockHintVisible = false
        lockHintTask?.cancel()
        controlsVisible = true
        orientationPolicy.unlock(in: scene)
        scheduleControlsAutoHide()
    }

    private func controlsOverlay(safeArea: EdgeInsets) -> some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.58), .clear, .clear, .black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("返回")
                    Text(resource.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Button { lockPlayer() } label: {
                        Image(systemName: "lock.open.fill")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("锁定播放器，禁用手势与旋转")
                }
                .foregroundStyle(.white)
                .padding(.leading, 16 + safeArea.leading)
                .padding(.trailing, 16 + safeArea.trailing)
                .padding(.top, max(8, safeArea.top + 4))

                Spacer()
                ViewThatFits(in: .horizontal) {
                    transportControls(spacing: 48, playButtonSize: 72)
                    transportControls(spacing: 16, playButtonSize: 60)
                }

                Spacer()
                VStack(spacing: 8) {
                    statusLine
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            currentTimeLabel
                            progressSlider
                            durationLabel
                            orientationButton
                        }
                        VStack(spacing: 2) {
                            progressSlider
                            HStack(spacing: 8) {
                                currentTimeLabel
                                Spacer(minLength: 8)
                                durationLabel
                                orientationButton
                            }
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.leading, 16 + safeArea.leading)
                .padding(.trailing, 16 + safeArea.trailing)
                .padding(.bottom, max(10, safeArea.bottom + 4))
            }
        }
    }

    private func transportControls(spacing: CGFloat, playButtonSize: CGFloat) -> some View {
        HStack(spacing: spacing) {
            transportButton("gobackward.10", label: "后退 10 秒") {
                commitSeek((pendingSeekTime ?? engine.currentTime) - 10)
            }
            Button { togglePlayback() } label: {
                Image(
                    systemName: engine.playbackState.showsPauseControl
                        ? "pause.circle.fill"
                        : "play.circle.fill"
                )
                .font(.system(size: playButtonSize))
                .frame(minWidth: 60, minHeight: 60)
            }
            .accessibilityLabel(engine.playbackState.showsPauseControl ? "暂停" : "播放")
            transportButton("goforward.10", label: "前进 10 秒") {
                commitSeek((pendingSeekTime ?? engine.currentTime) + 10)
            }
        }
        .foregroundStyle(.white)
        .disabled(engine.playbackState.disablesControls)
    }

    private var progressSlider: some View {
        Slider(
            value: Binding(
                get: { displayedTime },
                set: { value in
                    if isSliderScrubbing {
                        scrubPreviewTime = value
                    } else {
                        scrubPreviewTime = nil
                        commitSeek(value)
                    }
                }
            ),
            in: 0...max(engine.duration, 0.001),
            onEditingChanged: { editing in
                isSliderScrubbing = editing
                guard !editing, let target = scrubPreviewTime else { return }
                scrubPreviewTime = nil
                commitSeek(target)
            }
        )
        .tint(AppTheme.accent)
        .accessibilityLabel("播放进度")
        .accessibilityValue(
            "\(Self.timeLabel(displayedTime)) / \(Self.timeLabel(engine.duration))"
        )
    }

    private var currentTimeLabel: some View {
        Text(Self.timeLabel(displayedTime))
            .font(.caption.monospacedDigit())
            .lineLimit(1)
    }

    private var durationLabel: some View {
        Text(Self.timeLabel(engine.duration))
            .font(.caption.monospacedDigit())
            .lineLimit(1)
    }

    private var orientationButton: some View {
        Button { orientationPolicy.toggle(in: scene) } label: {
            Image(systemName: "rotate.right")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("切换竖屏或横屏")
    }

    private func transportButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 56, height: 56)
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder private var statusLine: some View {
        switch engine.playbackState {
        case .preparing: ProgressView("正在准备播放").tint(.white)
        case .waiting: ProgressView("正在缓冲").tint(.white)
        case .failed(let error):
            VStack(spacing: 6) {
                Text(error.localizedDescription).font(.caption).multilineTextAlignment(.center)
                Button("重试", systemImage: "arrow.clockwise") { savePosition(); engine.stop(); onRetry() }.buttonStyle(.borderedProminent)
            }
        case .ended: Text("播放结束").font(.caption)
        case .stopped, .playing, .paused: EmptyView()
        }
    }

    private var displayedTime: TimeInterval { scrubPreviewTime ?? (gestureAdjustment.flatMap { if case .scrub(let target, _) = $0 { target } else { nil } } ?? pendingSeekTime ?? engine.currentTime) }

    private func showFeedback(_ kind: PlayerFeedback.Kind, value: String) {
        let revision = (feedback?.revision ?? 0) + 1
        feedback = PlayerFeedback(kind: kind, value: value, revision: revision)
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            if feedback?.revision == revision { feedback = nil }
        }
    }

    private func restorePositionIfNeeded() {
        guard !restoredPosition else { return }
        guard engine.duration > 0 else { return }
        restoredPosition = true
        if case .seconds(let seconds) = appModel.resumePosition(for: resource, metadata: metadata) {
            commitSeek(seconds)
        } else if engine.play() {
            nowPlaying.refresh()
        }
    }

    private func savePosition() {
        guard engine.playbackState != .stopped, engine.duration > 0 else { return }
        let current = pendingSeekTime ?? engine.currentTime
        if current >= max(engine.duration - 0.5, 0) { appModel.clearResumePosition(for: resource) }
        else { appModel.recordResumePosition(.seconds(current), for: resource, metadata: metadata) }
    }

    private func restoreBrightnessIfNeeded() {
        guard didAdjustBrightness, let entryBrightness, let playbackScreen else { return }
        playbackScreen.brightness = entryBrightness
        didAdjustBrightness = false
    }

    private static func timeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded(.down)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct VideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer
    let onSceneChange: @MainActor (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.player = player
        view.onSceneChange = onSceneChange
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.player = player
        view.onSceneChange = onSceneChange
    }
}

private final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? { get { playerLayer.player } set { playerLayer.player = newValue; playerLayer.videoGravity = .resizeAspect } }
    var onSceneChange: (@MainActor (UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onSceneChange?(window?.windowScene)
    }
}

private struct AdjustmentHUD: View {
    let adjustment: VideoPlayerScreen.GestureAdjustment
    let duration: TimeInterval

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title2.weight(.semibold))
            Text(label)
                .font(.headline.monospacedDigit())
            ProgressView(value: progress, total: 1)
                .tint(.white)
                .frame(width: 150)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var progress: Double {
        switch adjustment {
        case .brightness(let value): Double(value)
        case .volume(let value): Double(value)
        case .scrub(let target, _): target / max(duration, 0.001)
        }
    }

    private var iconName: String {
        switch adjustment {
        case .brightness: "sun.max.fill"
        case .volume(let value): value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .scrub(_, let delta): delta < 0 ? "gobackward.10" : "goforward.10"
        }
    }

    private var label: String {
        switch adjustment {
        case .brightness(let value): return "亮度 \(Int(value * 100))%"
        case .volume(let value): return "视频音量 \(Int(value * 100))%"
        case .scrub(let target, let delta):
            let direction = delta < 0 ? "后退" : "前进"
            return "\(direction) \(Self.timeLabel(abs(delta))) · \(Self.timeLabel(target)) / \(Self.timeLabel(duration))"
        }
    }

    private static func timeLabel(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded(.down)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private extension VideoPlayerScreen.GestureAdjustment {
    var showsHUD: Bool {
        switch self {
        case .brightness, .volume: true
        case .scrub(_, let delta): abs(delta) >= 0.5
        }
    }
}

private struct PlayerFeedbackHUD: View {
    let feedback: VideoPlayerScreen.PlayerFeedback

    var body: some View {
        Text(feedback.value)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.68), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(feedback.value)
    }
}

private extension AVMediaPlayerEngine.PlaybackState {
    var disablesControls: Bool {
        switch self { case .preparing, .failed, .stopped: true; case .waiting, .playing, .paused, .ended: false }
    }
    var showsPauseControl: Bool {
        switch self { case .waiting, .playing: true; case .preparing, .paused, .failed, .ended, .stopped: false }
    }
}
