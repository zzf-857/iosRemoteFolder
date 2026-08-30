import SwiftUI

@MainActor
enum BrowseSourceActivation {
    static func activate(
        selectedSourceID: UUID?,
        store: SourcesStore
    ) -> UUID? {
        if let selectedSourceID,
           let selectedEntry = store.entries.first(where: { $0.id == selectedSourceID }) {
            if selectedEntry.hasAdapter {
                store.ensureConnected(selectedSourceID)
            }
            return selectedSourceID
        }

        guard let fallbackSourceID = store.entries.first(where: \.hasAdapter)?.id else {
            return nil
        }
        store.ensureConnected(fallbackSourceID)
        return fallbackSourceID
    }
}

enum BrowseResourceFilter {
    static func filter(
        _ items: [ResourceItem],
        selectedKind: ResourceKind?
    ) -> [ResourceItem] {
        guard let selectedKind else { return items }
        // Directories stay reachable while a file-type filter is active.
        return items.filter {
            let resolvedKind = $0.resolvedContentType.kind
            return resolvedKind == .folder || resolvedKind == selectedKind
        }
    }
}

struct BrowseView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        NavigationStack {
            BrowseContentView(
                store: appModel.sourcesStore,
                selectedSourceID: $appModel.selectedBrowseSourceID
            )
                .navigationTitle("浏览")
                .navigationDestination(for: ResourceItem.self) { resource in
                    // 只有文件进入查看器；文件夹通过 store 状态切换下钻，不会误入此处。
                    ResourceViewerHost(resource: resource)
                }
        }
    }
}

private struct BrowseContentView: View {
    let store: SourcesStore

    @Binding var selectedSourceID: UUID?
    @State private var selectedKind: ResourceKind?

    private var selectedEntry: SourcesStore.Entry? {
        guard let id = selectedSourceID else { return nil }
        return store.entries.first { $0.id == id }
    }

    private var availableSourceIDs: [UUID] {
        store.entries.filter(\.hasAdapter).map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker
            if let entry = selectedEntry, case .ready = entry.state {
                locationBar(entry: entry)
            }
            listing
        }
        .ambientScreenBackground()
        .navigationTitle("浏览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .glassNavigationBar()
        .task {
            activateSelectedSource()
        }
        .onChange(of: selectedSourceID) { _, _ in
            activateSelectedSource()
        }
        .onChange(of: availableSourceIDs) { _, _ in
            activateSelectedSource()
        }
    }

    private func activateSelectedSource() {
        selectedSourceID = BrowseSourceActivation.activate(
            selectedSourceID: selectedSourceID,
            store: store
        )
    }

    // MARK: - 来源选择

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.entries) { entry in
                    SourceChip(
                        source: entry.source,
                        isSelected: entry.id == selectedSourceID,
                        hasAdapter: entry.hasAdapter
                    ) {
                        selectedSourceID = entry.id
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let entry = selectedEntry, !entry.browse.currentPath.isRoot {
                Button {
                    store.goUp(entry.id)
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // 唯一搜索入口：进入全局深搜索并预选当前来源。
            NavigationLink {
                ResourceSearchView(initialSourceID: selectedSourceID)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("搜索资源")
        }
        ToolbarItem(placement: .topBarTrailing) {
            // 纯图标筛选菜单：激活时以实心图标提示，不再占用文字宽度。
            Menu {
                Picker("类型", selection: $selectedKind) {
                    Label("全部", systemImage: "square.grid.2x2").tag(ResourceKind?.none)
                    ForEach(
                        [ResourceKind.pdf, .markdown, .text, .image, .video, .audio],
                        id: \.self
                    ) { kind in
                        Label(kind.title, systemImage: kind.systemImage)
                            .tag(ResourceKind?.some(kind))
                    }
                }
            } label: {
                Image(
                    systemName: selectedKind == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .accessibilityLabel("按类型筛选")
            .accessibilityValue(Text(selectedKind?.title ?? "全部"))
        }
    }

    // MARK: - 列表与状态

    @ViewBuilder
    private var listing: some View {
        if selectedEntry == nil {
            statusScroll {
                ContentUnavailableView(
                    "选择来源",
                    systemImage: "externaldrive",
                    description: Text("从上方选择一个来源开始浏览")
                )
            }
        } else if let entry = selectedEntry {
            switch entry.state {
            case .connecting:
                statusScroll {
                    ProgressView("正在连接…")
                }
            case .disconnected:
                if !entry.hasAdapter {
                    statusScroll {
                        ContentUnavailableView(
                            "适配器开发中",
                            systemImage: "wrench",
                            description: Text("该来源类型暂未接入")
                        )
                    }
                } else {
                    statusScroll {
                        ContentUnavailableView {
                            Label("尚未连接", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("点击重试以连接此来源")
                        } actions: {
                            Button("重试") { store.connect(entry.id) }
                        }
                    }
                }
            case .failed(let error):
                statusScroll {
                    ContentUnavailableView {
                        Label("连接失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error.localizedDescription)
                    } actions: {
                        Button("重试") { store.retry(entry.id) }
                    }
                }
            case .ready:
                directoryListing(entry: entry)
            }
        }
    }

    @ViewBuilder
    private func directoryListing(entry: SourcesStore.Entry) -> some View {
        let browse = entry.browse
        if browse.isLoading && browse.items.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = browse.error {
            statusScroll {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("重试") { store.loadDirectory(entry.id, at: browse.currentPath) }
                }
            }
        } else if browse.isEmpty {
            statusScroll {
                ContentUnavailableView(
                    "此文件夹为空",
                    systemImage: "folder",
                    description: Text("没有可显示的资源")
                )
            }
        } else {
            let visibleItems = filteredItems(browse.items)
            List {
                if visibleItems.isEmpty {
                    ContentUnavailableView {
                        Label("没有符合筛选的项目", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("当前目录没有「\(selectedKind?.title ?? "全部")」类型的资源。")
                    } actions: {
                        Button("清除筛选") { selectedKind = nil }
                    }
                } else {
                    ForEach(visibleItems) { item in
                        row(for: item, entry: entry)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func statusScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, minHeight: 180)
                .padding()
        }
    }

    private func filteredItems(_ items: [ResourceItem]) -> [ResourceItem] {
        BrowseResourceFilter.filter(items, selectedKind: selectedKind)
    }

    @ViewBuilder
    private func row(for item: ResourceItem, entry: SourcesStore.Entry) -> some View {
        if item.resolvedContentType.kind == .folder {
            // 文件夹下钻：改变当前目录状态，不进入查看器。
            Button {
                store.enter(entry.id, folder: item)
            } label: {
                ResourceRowView(
                    resource: item,
                    interaction: .actionable(resultHint: "进入文件夹"),
                    disclosureOwnership: .resourceRow
                )
            }
            .buttonStyle(.plain)
        } else {
            // 文件进入查看器占位入口。
            NavigationLink(value: item) {
                ResourceRowView(
                    resource: item,
                    interaction: .actionable(resultHint: "打开资源"),
                    disclosureOwnership: .container
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 固定路径栏

    private func locationBar(entry: SourcesStore.Entry) -> some View {
        let path = entry.browse.currentPath
        return VStack(alignment: .leading, spacing: 2) {
            Text("当前位置")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    let isRootSelected = path.isRoot
                    Button {
                        store.loadDirectory(entry.id, at: .root)
                    } label: {
                        Label("根目录", systemImage: "house.fill")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(minWidth: 44, minHeight: 36)
                            .background {
                                if isRootSelected {
                                    Capsule().fill(AppTheme.accent.opacity(0.12))
                                } else {
                                    Capsule().fill(.ultraThinMaterial)
                                }
                            }
                            .foregroundStyle(isRootSelected ? AppTheme.accent : Color.primary)
                            .overlay(
                                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityHint("切换到根目录")
                    .accessibilityAddTraits(isRootSelected ? .isSelected : [])
                    ForEach(Array(path.components.enumerated()), id: \.offset) { index, component in
                        let prefix = "/" + path.components.prefix(index + 1).joined(separator: "/")
                        let isCurrent = index == path.components.count - 1
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Button {
                            if let crumb = ResourcePath(rawValue: prefix) {
                                store.loadDirectory(entry.id, at: crumb)
                            }
                        } label: {
                            Text(component)
                                .font(.footnote.weight(.medium))
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 12)
                                .frame(minWidth: 44, minHeight: 36)
                                .background {
                                    if isCurrent {
                                        Capsule().fill(AppTheme.accent.opacity(0.12))
                                    } else {
                                        Capsule().fill(.ultraThinMaterial)
                                    }
                                }
                                .foregroundStyle(isCurrent ? AppTheme.accent : Color.primary)
                                .overlay(
                                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityHint("切换到路径 \(prefix)")
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SourceChip: View {
    let source: ResourceSource
    let isSelected: Bool
    let hasAdapter: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: source.kind.systemImage)
                    .font(.footnote.weight(.semibold))
                Text(source.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                Circle()
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.9)
                            : AppTheme.statusColor(for: source.status)
                    )
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    Capsule().fill(AppTheme.brandGradient)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? .clear : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .shadow(
                color: isSelected ? AppTheme.accent.opacity(0.35) : .clear,
                radius: 10,
                y: 4
            )
        }
        .buttonStyle(.plain)
        .opacity(hasAdapter ? 1 : 0.55)
        .frame(minHeight: 44)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(
            Text(
                hasAdapter
                    ? (isSelected ? "已选中，\(source.status.title)" : source.status.title)
                    : "适配器未接入"
            )
        )
    }
}
