import SwiftUI

struct OfflineView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            List {
                Section { OfflineStorageSummary() }

                Section("可离线内容") {
                    ForEach(appModel.resources.prefix(3)) { resource in
                        OfflineResourceRow(resource: resource)
                    }
                }
            }
            .navigationTitle("离线")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("清理预览缓存", systemImage: "sparkles") {}
                        Button("管理存储", systemImage: "internaldrive") {}
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

private struct OfflineStorageSummary: View {
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
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("设备空间"))
        .accessibilityValue(Text("12.4 GB 可用，1.8 GB 缓存，已使用 14%"))
    }

    private var storageText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设备空间")
                .font(.headline)
            Text("12.4 GB 可用 · 1.8 GB 缓存")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progress: some View {
        ProgressView(value: 0.14)
            .tint(AppTheme.accent)
            .frame(minWidth: 72, idealWidth: 96, maxWidth: 120)
            .frame(minHeight: 44)
            .accessibilityHidden(true)
    }

    private var compactLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            storageText
                .layoutPriority(1)
            Spacer(minLength: 0)
            progress
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            storageText
            ProgressView(value: 0.14)
                .tint(AppTheme.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(resource.name)，\(resource.kind.title)，\(ResourceMetadataFormatter.modified(for: resource.metadata))，已离线"))
    }

    private var offlineLabel: some View {
        Label("已离线", systemImage: "checkmark.circle.fill")
            .foregroundStyle(AppTheme.accent)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
    }

    private var compactLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            ResourceRowView(resource: resource)
                .layoutPriority(1)
            offlineLabel
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            ResourceRowView(resource: resource)
            offlineLabel
        }
    }
}
