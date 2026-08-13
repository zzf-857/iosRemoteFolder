import Network
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var networkRecoveryObserver = NetworkRecoveryObserver()

    var body: some View {
        @Bindable var appModel = appModel

        TabView(selection: $appModel.currentTab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house") }
                .tag(AppTab.home)

            BrowseView()
                .tabItem { Label("浏览", systemImage: "square.grid.2x2") }
                .tag(AppTab.browse)

            SourcesView()
                .tabItem { Label("来源", systemImage: "externaldrive") }
                .tag(AppTab.sources)

            OfflineView()
                .tabItem { Label("离线", systemImage: "arrow.down.circle") }
                .tag(AppTab.offline)
        }
        .tint(AppTheme.accent)
        .glassTabBar()
        .onAppear {
            guard scenePhase == .active else { return }
            startNetworkRecoveryObserver()
        }
        .onDisappear {
            networkRecoveryObserver.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                startNetworkRecoveryObserver()
                appModel.sourcesStore.recoverTransientFailures()
            case .background:
                networkRecoveryObserver.stop()
            case .inactive:
                break
            @unknown default:
                networkRecoveryObserver.stop()
            }
        }
    }

    private func startNetworkRecoveryObserver() {
        networkRecoveryObserver.start {
            appModel.sourcesStore.recoverTransientFailures()
        }
    }
}

/// 将路径事件收敛成“确实断网后首次恢复”触发，避免初始或重复 satisfied
/// 在应用启动时无条件重发来源请求。
struct NetworkRecoveryTransitionState {
    private(set) var hasObservedUnsatisfied = false

    mutating func consume(_ status: NWPath.Status) -> Bool {
        if status == .unsatisfied {
            hasObservedUnsatisfied = true
            return false
        }
        guard status == .satisfied, hasObservedUnsatisfied else { return false }
        hasObservedUnsatisfied = false
        return true
    }
}

@MainActor
final class NetworkRecoveryObserver: ObservableObject {
    private var monitor: NWPathMonitor?
    private var generation: UInt64 = 0
    private var transitionState = NetworkRecoveryTransitionState()
    private var onRecovery: (@MainActor () -> Void)?
    private let queue = DispatchQueue(label: "com.zzf857.iosRemoteFolder.network-recovery")

    func start(onRecovery: @escaping @MainActor () -> Void) {
        stop()
        generation &+= 1
        let currentGeneration = generation
        transitionState = NetworkRecoveryTransitionState()
        self.onRecovery = onRecovery

        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor [weak self] in
                self?.consume(status, generation: currentGeneration)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        generation &+= 1
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        transitionState = NetworkRecoveryTransitionState()
        onRecovery = nil
    }

    private func consume(_ status: NWPath.Status, generation: UInt64) {
        guard generation == self.generation,
              transitionState.consume(status) else { return }
        onRecovery?()
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
