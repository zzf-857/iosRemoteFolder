import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

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
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}

