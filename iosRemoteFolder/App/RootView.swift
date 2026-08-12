import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, phase in
            // 弱网/断网后回到前台时，自动恢复因瞬时网络失败的来源连接。
            guard phase == .active else { return }
            appModel.sourcesStore.reconnectFailedSources()
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}

