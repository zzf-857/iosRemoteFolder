import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HomeHeader()
                    ContinueSection(resources: Array(appModel.resources.prefix(3)))
                    RecentSection(resources: appModel.resources)
                    SourceAttentionSection(sources: appModel.sources)
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .navigationTitle("首页")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("搜索", systemImage: "magnifyingglass") {
                        appModel.currentTab = .browse
                    }
                }
            }
            // 整个 NavigationStack 只注册一次 ResourceItem 目的地，
            // 消除子区段重复注册导致的运行时警告。
            .navigationDestination(for: ResourceItem.self) { resource in
                ResourceViewerHost(resource: resource)
            }
        }
    }
}

private struct HomeHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("你的资源台")
                .font(.largeTitle.bold())
            Text("从上次停下的位置继续。")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ContinueSection: View {
    let resources: [ResourceItem]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "继续")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 14) {
                    ForEach(resources) { resource in
                        NavigationLink(value: resource) {
                            ContinueCard(resource: resource, fillsWidth: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(resources) { resource in
                            NavigationLink(value: resource) {
                                ContinueCard(resource: resource, fillsWidth: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct ContinueCard: View {
    let resource: ResourceItem
    let fillsWidth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: resource.kind.systemImage)
                .font(.title)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 58, height: 58)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            Text(resource.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(ResourceMetadataFormatter.modified(for: resource.metadata))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(
            minWidth: fillsWidth ? 0 : 180,
            maxWidth: fillsWidth ? .infinity : 280,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(resource.name))
        .accessibilityValue(Text("\(resource.kind.title)，\(ResourceMetadataFormatter.modified(for: resource.metadata))"))
        .accessibilityHint(Text("继续查看"))
    }
}

private struct RecentSection: View {
    let resources: [ResourceItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "最近打开")
            ForEach(resources) { resource in
                NavigationLink(value: resource) {
                    ResourceRowView(
                        resource: resource,
                        interaction: .actionable(
                            resultHint: resource.kind == .folder ? "进入文件夹" : "打开资源"
                        ),
                        disclosureOwnership: .resourceRow
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SourceAttentionSection: View {
    let sources: [ResourceSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "来源状态")
            ForEach(sources) { source in
                SourceRowView(source: source)
            }
        }
    }
}

private struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.bold())
    }
}
