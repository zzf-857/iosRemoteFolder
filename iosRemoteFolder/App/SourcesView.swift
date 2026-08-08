import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var appModel

    private var store: SourcesStore { appModel.sourcesStore }

    var body: some View {
        @Bindable var appModel = appModel
        NavigationStack {
            List {
                Section {
                    Button(action: {}) {
                        Label("添加来源", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                    .tint(AppTheme.accent)
                }

                Section("我的来源") {
                    ForEach(store.entries) { entry in
                        SourceConnectionRow(entry: entry) {
                            store.retry(entry.id)
                        }
                    }
                }
            }
            .navigationTitle("来源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("发现局域网", systemImage: "dot.radiowaves.left.and.right") {}
                }
            }
            .task {
                store.connectAll()
            }
        }
    }
}

/// 来源连接行：复用 `SourceRowView` 的身份与状态展示，再按实时连接状态
/// 附加连接中、失败原因与重试入口。UI 只消费 `SourcesStore` 的状态。
private struct SourceConnectionRow: View {
    let entry: SourcesStore.Entry
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceRowView(source: displaySource)

            switch entry.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在连接…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button(action: retry) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(AppTheme.accent)
                }
            case .disconnected where !entry.hasAdapter:
                Text("适配器开发中，即将支持")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .disconnected, .ready:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private var displaySource: ResourceSource {
        var source = entry.source
        switch entry.state {
        case .disconnected:
            source.status = .disconnected
        case .connecting:
            source.status = .connecting
        case .ready:
            source.status = .connected
        case .failed:
            source.status = .needsAttention
        }
        return source
    }
}
