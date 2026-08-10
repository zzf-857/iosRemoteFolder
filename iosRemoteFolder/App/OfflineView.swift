import SwiftUI

struct OfflineView: View {
    @Environment(AppModel.self) private var appModel

    private var cachedResources: [ResourceItem] {
        var seen = Set<ResourceIdentity>()
        return (appModel.recentResources + appModel.resources).filter { resource in
            appModel.offlineResourceIDs.contains(resource.id)
                && seen.insert(resource.id).inserted
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    OfflineStorageSummary(
                        cachedByteCount: appModel.offlineByteCount,
                        hasCachedContent: !appModel.offlineResourceIDs.isEmpty
                    )
                }

                Section("已缓存内容") {
                    if cachedResources.isEmpty {
                        ContentUnavailableView(
                            "暂无缓存内容",
                            systemImage: "internaldrive",
                            description: Text("打开资源后会在这里显示可复用的内容缓存")
                        )
                    } else {
                        ForEach(cachedResources) { resource in
                            NavigationLink {
                                ResourceViewerHost(
                                    resource: resource,
                                    mode: .offline
                                )
                            } label: {
                                OfflineResourceRow(resource: resource)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("离线")
            .task {
                await appModel.refreshOfflineCache()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("清理预览缓存", systemImage: "trash") {
                            Task {
                                await appModel.clearOfflineCache()
                            }
                        }
                        .disabled(appModel.offlineResourceIDs.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .glassNavigationBar()
        }
    }
}

private struct OfflineStorageSummary: View {
    let cachedByteCount: Int64
    let hasCachedContent: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var cachedSizeDescription: String {
        ByteCountFormatter.string(
            fromByteCount: max(cachedByteCount, 0),
            countStyle: .file
        )
    }

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
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("内容缓存"))
        .accessibilityValue(
            Text(
                hasCachedContent
                    ? "已占用 \(cachedSizeDescription)"
                    : "暂无缓存内容"
            )
        )
    }

    private var storageText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("内容缓存")
                .font(.headline)
            Text(
                hasCachedContent
                    ? "已占用 \(cachedSizeDescription)"
                    : "暂无缓存内容"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var compactLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            storageText
                .layoutPriority(1)
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            storageText
        }
    }
}

private struct OfflineResourceRow: View {
    let resource: ResourceItem
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "\(resource.name)，\(resource.kind.title)，"
                    + "\(ResourceMetadataFormatter.size(for: resource.metadata))，"
                    + "\(ResourceMetadataFormatter.modified(for: resource.metadata))，已离线"
            )
        )
        .accessibilityHint(Text("打开离线资源"))
    }

    private var offlineLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .accessibilityHidden(true)
            Text("已离线")
                .fixedSize(horizontal: false, vertical: true)
        }
            .foregroundStyle(AppTheme.accent)
            .frame(minHeight: 44, alignment: .leading)
            .layoutPriority(1)
    }

    private var compactLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            ResourceRowView(
                resource: resource,
                interaction: .actionable(resultHint: "打开离线资源"),
                disclosureOwnership: .container
            )
                .layoutPriority(1)
            offlineLabel
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            ResourceRowView(
                resource: resource,
                interaction: .actionable(resultHint: "打开离线资源"),
                disclosureOwnership: .container
            )
            offlineLabel
        }
    }
}
