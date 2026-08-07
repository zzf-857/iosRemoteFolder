import SwiftUI

struct OfflineView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("设备空间")
                                .font(.headline)
                            Text("12.4 GB 可用 · 1.8 GB 缓存")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProgressView(value: 0.14)
                            .tint(AppTheme.accent)
                            .frame(width: 72)
                    }
                    .padding(.vertical, 6)
                }

                Section("可离线内容") {
                    ForEach(appModel.resources.prefix(3)) { resource in
                        HStack {
                            ResourceRowView(resource: resource)
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.accent)
                        }
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

