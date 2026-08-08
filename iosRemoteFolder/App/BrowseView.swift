import SwiftUI

struct BrowseView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        NavigationStack {
            BrowseContentView(store: appModel.sourcesStore)
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

    @State private var selectedSourceID: UUID?
    @State private var selectedKind: ResourceKind?
    @State private var searchText: String = ""

    private var selectedEntry: SourcesStore.Entry? {
        guard let id = selectedSourceID else { return nil }
        return store.entries.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker
            Divider()
            listing
        }
        .navigationTitle("浏览")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索当前目录")
        .toolbar { toolbarContent }
        .task { store.connectAll() }
        .onChange(of: selectedSourceID) { _, newID in
            guard let newID else { return }
            store.ensureConnected(newID)
        }
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
            Picker("类型", selection: $selectedKind) {
                Text("全部").tag(ResourceKind?.none)
                Text("PDF").tag(ResourceKind?.some(.pdf))
                Text("Markdown").tag(ResourceKind?.some(.markdown))
                Text("TXT").tag(ResourceKind?.some(.text))
                Text("图片").tag(ResourceKind?.some(.image))
                Text("视频").tag(ResourceKind?.some(.video))
                Text("音乐").tag(ResourceKind?.some(.audio))
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - 列表与状态

    @ViewBuilder
    private var listing: some View {
        if selectedEntry == nil {
            ContentUnavailableView(
                "选择来源",
                systemImage: "externaldrive",
                description: Text("从上方选择一个来源开始浏览")
            )
        } else if let entry = selectedEntry {
            switch entry.state {
            case .connecting:
                ProgressView("正在连接…")
            case .disconnected:
                if !entry.hasAdapter {
                    ContentUnavailableView(
                        "适配器开发中",
                        systemImage: "wrench",
                        description: Text("该来源类型暂未接入")
                    )
                } else {
                    ContentUnavailableView {
                        Label("尚未连接", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("点击重试以连接此来源")
                    } actions: {
                        Button("重试") { store.connect(entry.id) }
                    }
                }
            case .failed(let error):
                ContentUnavailableView {
                    Label("连接失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("重试") { store.retry(entry.id) }
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
        } else if let error = browse.error {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("重试") { store.loadDirectory(entry.id, at: browse.currentPath) }
            }
        } else if browse.isEmpty {
            ContentUnavailableView(
                "此文件夹为空",
                systemImage: "folder",
                description: Text("没有可显示的资源")
            )
        } else {
            List {
                breadcrumbSection(entry: entry, browse: browse)
                ForEach(filteredItems(browse.items)) { item in
                    row(for: item, entry: entry)
                }
            }
        }
    }

    private func filteredItems(_ items: [ResourceItem]) -> [ResourceItem] {
        items.filter { item in
            let matchesKind = selectedKind == nil || item.kind == selectedKind
            let matchesSearch = searchText.isEmpty
                || item.name.localizedCaseInsensitiveContains(searchText)
            return matchesKind && matchesSearch
        }
    }

    @ViewBuilder
    private func row(for item: ResourceItem, entry: SourcesStore.Entry) -> some View {
        if item.kind == .folder {
            // 文件夹下钻：改变当前目录状态，不进入查看器。
            Button {
                store.enter(entry.id, folder: item)
            } label: {
                ResourceRowView(resource: item)
            }
            .buttonStyle(.plain)
        } else {
            // 文件进入查看器占位入口。
            NavigationLink(value: item) {
                ResourceRowView(resource: item)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 面包屑

    private func breadcrumbSection(entry: SourcesStore.Entry, browse: SourcesStore.SourceBrowse) -> some View {
        let path = browse.currentPath
        return Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    Button {
                        store.loadDirectory(entry.id, at: .root)
                    } label: {
                        Label("根目录", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)
                    ForEach(Array(path.components.enumerated()), id: \.offset) { index, component in
                        let prefix = "/" + path.components.prefix(index + 1).joined(separator: "/")
                        Text("/")
                            .foregroundStyle(.secondary)
                        Button {
                            if let crumb = ResourcePath(rawValue: prefix) {
                                store.loadDirectory(entry.id, at: crumb)
                            }
                        } label: {
                            Text(component)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("当前位置")
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
            Label(source.name, systemImage: source.kind.systemImage)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected ? AppTheme.accent.opacity(0.18) : Color(.secondarySystemFill),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? AppTheme.accent : .clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .tint(AppTheme.accent)
        .opacity(hasAdapter ? 1 : 0.6)
    }
}
