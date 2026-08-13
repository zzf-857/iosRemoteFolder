import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HomeHeader()
                    ContinueSection(resources: Array(appModel.homeResources.prefix(3)))
                    RecentSection(resources: appModel.homeResources)
                    SourceAttentionSection(sources: appModel.sources)
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .ambientScreenBackground()
            .navigationTitle("首页")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ResourceSearchView()
                    } label: {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                }
            }
            // 整个 NavigationStack 只注册一次 ResourceItem 目的地，
            // 消除子区段重复注册导致的运行时警告。
            .navigationDestination(for: ResourceItem.self) { resource in
                ResourceViewerHost(resource: resource)
            }
            .glassNavigationBar()
        }
    }
}

struct ResourceSearchView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedKind: ResourceKind?
    @State private var selectedSourceID: UUID?
    @State private var results: [ResourceItem] = []
    @State private var indexedResourceCount = 0
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var retryRevision = 0

    private var request: ResourceSearchRequest {
        ResourceSearchRequest(
            query: query,
            kind: selectedKind,
            sourceID: selectedSourceID,
            retryRevision: retryRevision
        )
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView {
                    Label("搜索不可用", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { retryRevision += 1 }
                }
            } else if trimmedQuery.isEmpty {
                ContentUnavailableView {
                    Label(
                        indexedResourceCount == 0 ? "暂无已浏览资源" : "搜索资源",
                        systemImage: "doc.text.magnifyingglass"
                    )
                } description: {
                    if let indexWarning = appModel.resourceIndexError {
                        Text("\(indexWarning)。返回浏览页刷新对应目录后会再次更新。")
                    } else if indexedResourceCount > 0 {
                        Text("搜索范围仅限你已浏览过的目录，当前已索引 \(indexedResourceCount) 个资源。")
                    } else {
                        Text("搜索只覆盖你浏览过的目录。先到浏览页打开来源目录，再回来搜索。")
                    }
                }
            } else if isSearching {
                ProgressView("正在搜索…")
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label("没有找到 “\(trimmedQuery)”", systemImage: "magnifyingglass")
                } description: {
                    Text("搜索范围仅限你已浏览过的目录；未浏览过的目录不会出现在结果中。")
                }
            } else {
                List {
                    Section {
                        ForEach(results) { resource in
                            resultRow(for: resource)
                        }
                    } footer: {
                        Text("结果仅来自你已浏览过的目录。")
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索已浏览目录（名称或路径）")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
        .task(id: request) {
            await performSearch()
        }
        .onChange(of: appModel.sources.map(\.id)) { _, sourceIDs in
            if let selectedSourceID, !sourceIDs.contains(selectedSourceID) {
                self.selectedSourceID = nil
            }
            retryRevision += 1
        }
    }

    @ViewBuilder
    private func resultRow(for resource: ResourceItem) -> some View {
        let row = ResourceSearchResultRow(
            resource: resource,
            sourceName: appModel.sourceName(for: resource.sourceID)
        )

        if resource.kind == .folder {
            Button {
                dismiss()
                appModel.openIndexedFolder(resource)
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: resource) {
                row
            }
            .buttonStyle(.plain)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("来源", selection: $selectedSourceID) {
                Text("全部来源").tag(UUID?.none)
                ForEach(appModel.sources) { source in
                    Text(source.name).tag(UUID?.some(source.id))
                }
            }
            Picker("类型", selection: $selectedKind) {
                Text("全部类型").tag(ResourceKind?.none)
                ForEach(ResourceKind.allCases) { kind in
                    Text(kind.title).tag(ResourceKind?.some(kind))
                }
            }
        } label: {
            Image(
                systemName: selectedKind == nil && selectedSourceID == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .accessibilityLabel("筛选搜索结果")
    }

    private func refreshIndexedResourceCount() async {
        do {
            // 与结果的来源过滤一致：只统计当前注册来源，已移除来源的
            // 残留记录不计入"已索引 N 个资源"。
            var total = 0
            for source in appModel.sources {
                total += try await appModel.resourceIndexStore.indexedResourceCount(
                    sourceID: source.id
                )
            }
            indexedResourceCount = total
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performSearch() async {
        let term = trimmedQuery
        guard !term.isEmpty else {
            results = []
            isSearching = false
            await refreshIndexedResourceCount()
            return
        }

        isSearching = true
        errorMessage = nil
        do {
            try await Task.sleep(for: .milliseconds(180))
            try Task.checkCancellation()
            let matches = try await appModel.resourceIndexStore.search(
                term,
                kind: selectedKind,
                sourceID: selectedSourceID
            )
            try Task.checkCancellation()
            // 读取侧命名空间守卫：即使清理写入失败留下旧记录，已移除来源的
            // 结果也不会出现在界面上。
            let registeredIDs = Set(appModel.sources.map(\.id))
            results = matches.filter { registeredIDs.contains($0.sourceID) }
            await refreshIndexedResourceCount()
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct ResourceSearchRequest: Hashable {
    let query: String
    let kind: ResourceKind?
    let sourceID: UUID?
    let retryRevision: Int
}

private struct ResourceSearchResultRow: View {
    let resource: ResourceItem
    let sourceName: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedLayout
            } else {
                ViewThatFits(in: .horizontal) {
                    compactLayout
                    stackedLayout
                }
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(resource.name)
        .accessibilityValue("\(resource.kind.title)，\(sourceName)，\(resource.path)")
        .accessibilityHint(resource.kind == .folder ? "打开文件夹" : "打开资源")
    }

    private var compactLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            details
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                icon
                Text(resource.name)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            contextText
        }
        .padding(.vertical, 6)
    }

    private var icon: some View {
        ResourceIconTile(kind: resource.kind, side: 40)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(resource.name)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            contextText
        }
    }

    private var contextText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(sourceName) · \(resource.kind.title)")
            Text(resource.path)
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HomeHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("你的资源台")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.primary, .primary.opacity(0.75)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Text("从上次停下的位置继续。")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ContinueSection: View {
    let resources: [ResourceItem]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ModernSectionHeader(title: "继续")
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
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct ContinueCard: View {
    let resource: ResourceItem
    let fillsWidth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 类型渐变横幅：内容层的视觉锚点。
            ZStack {
                resource.kind.gradient
                Image(systemName: resource.kind.systemImage)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            }
            .frame(height: 96)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(resource.name)
                    .font(.headline)
                    .fontDesign(.rounded)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(resource.kind.title) · \(ResourceMetadataFormatter.modified(for: resource.metadata))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            minWidth: fillsWidth ? 0 : 200,
            maxWidth: fillsWidth ? .infinity : 260,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .modernCard(cornerRadius: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(resource.name))
        .accessibilityValue(Text("\(resource.kind.title)，\(ResourceMetadataFormatter.modified(for: resource.metadata))"))
        .accessibilityHint(Text("继续查看"))
    }
}

private struct RecentSection: View {
    let resources: [ResourceItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ModernSectionHeader(title: "最近打开")
            VStack(spacing: 0) {
                ForEach(Array(resources.enumerated()), id: \.element.id) { index, resource in
                    NavigationLink(value: resource) {
                        ResourceRowView(
                            resource: resource,
                            interaction: .actionable(
                                resultHint: resource.kind == .folder ? "进入文件夹" : "打开资源"
                            ),
                            disclosureOwnership: .resourceRow
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    if index < resources.count - 1 {
                        Divider()
                            .padding(.leading, 70)
                    }
                }
            }
            .padding(.vertical, 6)
            .modernCard(cornerRadius: 22)
        }
    }
}

private struct SourceAttentionSection: View {
    let sources: [ResourceSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ModernSectionHeader(title: "来源状态")
            VStack(spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    SourceRowView(source: source)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    if index < sources.count - 1 {
                        Divider()
                            .padding(.leading, 74)
                    }
                }
            }
            .padding(.vertical, 6)
            .modernCard(cornerRadius: 22)
        }
    }
}
