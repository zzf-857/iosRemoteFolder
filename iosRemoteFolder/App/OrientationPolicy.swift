import Observation
import UIKit

/// Scene-scoped orientation policy used only while the immersive video viewer is visible.
/// The system can reject geometry requests (for example in iPad multitasking), so callers
/// keep the current layout usable and surface scene-scoped errors as feedback.
@MainActor
@Observable
final class OrientationPolicy {
    static let shared = OrientationPolicy()

    private(set) var supportedOrientations: UIInterfaceOrientationMask
    private(set) var sceneErrorDescriptions: [String: String] = [:]

    @ObservationIgnored private weak var activeScene: UIWindowScene?
    @ObservationIgnored private var sceneStates: [String: SceneState] = [:]
    @ObservationIgnored private var latestLifecycleIDs: [String: UUID] = [:]
    @ObservationIgnored private var pendingExitRequests: [String: ExitRequest] = [:]
    @ObservationIgnored private var requestSequence: UInt64 = 0

    private struct SceneState {
        let lifecycleID: UUID
        let entryOrientation: UIInterfaceOrientation?
        var stableMask: UIInterfaceOrientationMask
        var effectiveMask: UIInterfaceOrientationMask
        var requestToken: UInt64
        var requestSnapshot: RequestSnapshot?
        var transientRestoreTask: Task<Void, Never>?
    }

    private struct RequestSnapshot {
        let token: UInt64
        let stableMask: UIInterfaceOrientationMask
        let effectiveMask: UIInterfaceOrientationMask
        let isTransient: Bool
    }

    private struct ExitRequest: Equatable {
        let lifecycleID: UUID
        let token: UInt64
    }

    private init() {
        supportedOrientations = Self.defaultOrientations
    }

    func begin(in scene: UIWindowScene?) {
        guard let scene else { return }
        let sceneID = scene.session.persistentIdentifier

        activeScene = scene
        if let state = sceneStates[sceneID] {
            supportedOrientations = state.effectiveMask
            return
        }

        let lifecycleID = UUID()
        let defaultMask = Self.defaultOrientations
        sceneStates[sceneID] = SceneState(
            lifecycleID: lifecycleID,
            entryOrientation: Self.interfaceOrientation(for: scene),
            stableMask: defaultMask,
            effectiveMask: defaultMask,
            requestToken: nextRequestToken(),
            requestSnapshot: nil,
            transientRestoreTask: nil
        )
        latestLifecycleIDs[sceneID] = lifecycleID
        pendingExitRequests.removeValue(forKey: sceneID)
        supportedOrientations = defaultMask
        sceneErrorDescriptions.removeValue(forKey: sceneID)
        refreshSupportedOrientations(in: scene)
    }

    @discardableResult
    func lockCurrentOrientation(in scene: UIWindowScene?) -> Bool {
        guard let scene = scene ?? activeScene else { return false }
        let sceneID = scene.session.persistentIdentifier
        guard var state = sceneStates[sceneID],
              let mask = Self.interfaceOrientation(for: scene).mask else {
            return false
        }

        activeScene = scene
        normalizeTransientRequest(in: &state)
        let token = nextRequestToken()
        state.requestToken = token
        state.requestSnapshot = RequestSnapshot(
            token: token,
            stableMask: state.stableMask,
            effectiveMask: state.effectiveMask,
            isTransient: false
        )
        state.stableMask = mask
        state.effectiveMask = mask
        sceneStates[sceneID] = state
        supportedOrientations = mask
        sceneErrorDescriptions.removeValue(forKey: sceneID)
        refreshSupportedOrientations(in: scene)
        request(
            mask,
            in: scene,
            sceneID: sceneID,
            lifecycleID: state.lifecycleID,
            token: token
        )
        return true
    }

    func unlock(in scene: UIWindowScene?) {
        guard let scene = scene ?? activeScene else { return }
        let sceneID = scene.session.persistentIdentifier
        guard var state = sceneStates[sceneID] else { return }

        activeScene = scene
        state.transientRestoreTask?.cancel()
        state.transientRestoreTask = nil
        state.requestToken = nextRequestToken()
        state.requestSnapshot = nil
        state.stableMask = Self.defaultOrientations
        state.effectiveMask = Self.defaultOrientations
        sceneStates[sceneID] = state
        supportedOrientations = state.effectiveMask
        sceneErrorDescriptions.removeValue(forKey: sceneID)
        refreshSupportedOrientations(in: scene)
    }

    func toggle(in scene: UIWindowScene?) {
        guard let scene = scene ?? activeScene else { return }
        let sceneID = scene.session.persistentIdentifier
        guard var state = sceneStates[sceneID] else { return }

        activeScene = scene
        normalizeTransientRequest(in: &state)
        let current = Self.interfaceOrientation(for: scene)
        let target: UIInterfaceOrientationMask = current.isLandscape ? .portrait : .landscape
        let token = nextRequestToken()
        state.requestToken = token
        state.requestSnapshot = RequestSnapshot(
            token: token,
            stableMask: state.stableMask,
            effectiveMask: state.effectiveMask,
            isTransient: true
        )
        state.effectiveMask = target
        sceneStates[sceneID] = state
        supportedOrientations = target
        sceneErrorDescriptions.removeValue(forKey: sceneID)
        refreshSupportedOrientations(in: scene)
        request(
            target,
            in: scene,
            sceneID: sceneID,
            lifecycleID: state.lifecycleID,
            token: token
        )
        scheduleTransientRestore(
            in: scene,
            sceneID: sceneID,
            lifecycleID: state.lifecycleID,
            token: token
        )
    }

    func end(in scene: UIWindowScene?) {
        guard let scene = scene ?? activeScene else { return }
        let sceneID = scene.session.persistentIdentifier
        guard var state = sceneStates[sceneID] else { return }

        state.transientRestoreTask?.cancel()
        let exitToken = nextRequestToken()
        state.requestToken = exitToken
        sceneStates.removeValue(forKey: sceneID)
        pendingExitRequests[sceneID] = ExitRequest(
            lifecycleID: state.lifecycleID,
            token: exitToken
        )

        if activeScene === scene {
            activeScene = nil
            supportedOrientations = Self.defaultOrientations
        }
        sceneErrorDescriptions.removeValue(forKey: sceneID)
        refreshSupportedOrientations(in: scene)

        let restorationMask = state.entryOrientation?.mask ?? Self.defaultOrientations
        requestRestoration(
            restorationMask,
            in: scene,
            sceneID: sceneID,
            lifecycleID: state.lifecycleID,
            token: exitToken
        )
    }

    func errorDescription(in scene: UIWindowScene?) -> String? {
        guard let scene = scene ?? activeScene else { return nil }
        return sceneErrorDescriptions[scene.session.persistentIdentifier]
    }

    func clearError(in scene: UIWindowScene?) {
        guard let scene = scene ?? activeScene else { return }
        sceneErrorDescriptions.removeValue(forKey: scene.session.persistentIdentifier)
    }

    func isLocked(in scene: UIWindowScene?) -> Bool {
        guard let scene = scene ?? activeScene,
              let state = sceneStates[scene.session.persistentIdentifier] else {
            return false
        }
        return state.stableMask.isSingleOrientation
    }

    func orientations(for scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        guard let scene else { return Self.defaultOrientations }
        return sceneStates[scene.session.persistentIdentifier]?.effectiveMask
            ?? Self.defaultOrientations
    }

    private func request(
        _ mask: UIInterfaceOrientationMask,
        in scene: UIWindowScene,
        sceneID: String,
        lifecycleID: UUID,
        token: UInt64
    ) {
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(preferences) { [weak self, weak scene] error in
            let message = "当前窗口无法切换方向：\(error.localizedDescription)"
            Task { @MainActor in
                self?.handleRequestFailure(
                    in: scene,
                    sceneID: sceneID,
                    lifecycleID: lifecycleID,
                    token: token,
                    message: message
                )
            }
        }
    }

    private func handleRequestFailure(
        in scene: UIWindowScene?,
        sceneID: String,
        lifecycleID: UUID,
        token: UInt64,
        message: String
    ) {
        guard latestLifecycleIDs[sceneID] == lifecycleID,
              var state = sceneStates[sceneID],
              state.lifecycleID == lifecycleID,
              state.requestToken == token,
              let snapshot = state.requestSnapshot,
              snapshot.token == token else {
            return
        }

        state.transientRestoreTask?.cancel()
        state.transientRestoreTask = nil
        state.stableMask = snapshot.stableMask
        state.effectiveMask = snapshot.effectiveMask
        state.requestSnapshot = nil
        sceneStates[sceneID] = state
        if activeScene?.session.persistentIdentifier == sceneID {
            supportedOrientations = state.effectiveMask
        }
        sceneErrorDescriptions[sceneID] = message
        if let scene {
            refreshSupportedOrientations(in: scene)
        }
    }

    private func requestRestoration(
        _ mask: UIInterfaceOrientationMask,
        in scene: UIWindowScene,
        sceneID: String,
        lifecycleID: UUID,
        token: UInt64
    ) {
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(preferences) { [weak self] error in
            let message = "当前窗口无法恢复进入播放器前的方向：\(error.localizedDescription)"
            Task { @MainActor in
                self?.handleRestorationFailure(
                    sceneID: sceneID,
                    lifecycleID: lifecycleID,
                    token: token,
                    message: message
                )
            }
        }
    }

    private func handleRestorationFailure(
        sceneID: String,
        lifecycleID: UUID,
        token: UInt64,
        message: String
    ) {
        let expectedRequest = ExitRequest(lifecycleID: lifecycleID, token: token)
        guard latestLifecycleIDs[sceneID] == lifecycleID,
              pendingExitRequests[sceneID] == expectedRequest,
              sceneStates[sceneID] == nil else {
            return
        }

        pendingExitRequests.removeValue(forKey: sceneID)
        sceneErrorDescriptions[sceneID] = message
    }

    private func scheduleTransientRestore(
        in scene: UIWindowScene,
        sceneID: String,
        lifecycleID: UUID,
        token: UInt64
    ) {
        let task = Task { @MainActor [weak self, weak scene] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.restoreStableOrientations(
                in: scene,
                sceneID: sceneID,
                lifecycleID: lifecycleID,
                token: token
            )
        }
        guard var state = sceneStates[sceneID],
              state.lifecycleID == lifecycleID,
              state.requestToken == token else {
            task.cancel()
            return
        }
        state.transientRestoreTask = task
        sceneStates[sceneID] = state
    }

    private func restoreStableOrientations(
        in scene: UIWindowScene?,
        sceneID: String,
        lifecycleID: UUID,
        token: UInt64
    ) {
        guard latestLifecycleIDs[sceneID] == lifecycleID,
              var state = sceneStates[sceneID],
              state.lifecycleID == lifecycleID,
              state.requestToken == token,
              state.requestSnapshot?.isTransient == true else {
            return
        }

        state.effectiveMask = state.stableMask
        state.transientRestoreTask = nil
        sceneStates[sceneID] = state
        if activeScene?.session.persistentIdentifier == sceneID {
            supportedOrientations = state.effectiveMask
        }
        if let scene {
            refreshSupportedOrientations(in: scene)
        }
    }

    private func normalizeTransientRequest(in state: inout SceneState) {
        state.transientRestoreTask?.cancel()
        state.transientRestoreTask = nil
        if state.requestSnapshot?.isTransient == true {
            state.effectiveMask = state.stableMask
        }
    }

    private func nextRequestToken() -> UInt64 {
        requestSequence += 1
        return requestSequence
    }

    private func refreshSupportedOrientations(in scene: UIWindowScene) {
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private static var defaultOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    private static func interfaceOrientation(for scene: UIWindowScene) -> UIInterfaceOrientation {
        if #available(iOS 26.0, *) {
            return scene.effectiveGeometry.interfaceOrientation
        }
        return scene.interfaceOrientation
    }
}

private extension UIInterfaceOrientation {
    var mask: UIInterfaceOrientationMask? {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .unknown: nil
        @unknown default: nil
        }
    }
}

private extension UIInterfaceOrientationMask {
    var isSingleOrientation: Bool {
        self == .portrait
            || self == .portraitUpsideDown
            || self == .landscapeLeft
            || self == .landscapeRight
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationPolicy.shared.orientations(for: window?.windowScene)
    }
}
