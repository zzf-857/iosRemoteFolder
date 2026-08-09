import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @Environment(AppModel.self) private var appModel

    @State private var isShowingFolderImporter = false
    @State private var reauthorizationSourceID: UUID?
    @State private var pendingAction: SourceAction?

    private var store: SourcesStore { appModel.sourcesStore }

    private enum SourceAction: Hashable {
        case add(URL)
        case reauthorize(UUID, URL)
        case remove(UUID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        appModel.dismissSourceError()
                        reauthorizationSourceID = nil
                        isShowingFolderImporter = true
                    } label: {
                        Label("添加本地文件夹", systemImage: "folder.badge.plus")
                            .font(.headline)
                    }
                    .tint(AppTheme.accent)
                }

                if let error = appModel.sourceActionError {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("来源操作失败", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.headline)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("关闭") {
                                appModel.dismissSourceError()
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("我的来源") {
                    ForEach(store.entries) { entry in
                        SourceConnectionRow(
                            entry: entry,
                            retry: { store.retry(entry.id) },
                            reauthorize: canReauthorize(entry) ? {
                                appModel.dismissSourceError()
                                reauthorizationSourceID = entry.id
                                isShowingFolderImporter = true
                            } : nil,
                            remove: appModel.isManagedLocalSource(entry.id) ? {
                                pendingAction = .remove(entry.id)
                            } : nil
                        )
                    }
                }
            }
            .navigationTitle("来源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("发现局域网", systemImage: "dot.radiowaves.left.and.right") {}
                }
            }
            .fileImporter(
                isPresented: $isShowingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderImportResult(result)
            }
            .task {
                store.connectAll()
            }
            .task(id: pendingAction) {
                guard let pendingAction else { return }
                defer { self.pendingAction = nil }
                switch pendingAction {
                case .add(let url):
                    appModel.addLocalSource(directoryURL: url)
                case .reauthorize(let sourceID, let url):
                    appModel.reauthorizeLocalSource(sourceID: sourceID, directoryURL: url)
                case .remove(let sourceID):
                    appModel.removeLocalSource(sourceID: sourceID)
                }
            }
        }
    }

    private func canReauthorize(_ entry: SourcesStore.Entry) -> Bool {
        guard appModel.isManagedLocalSource(entry.id),
              case .failed(let error) = entry.state else {
            return false
        }
        switch error {
        case .authorizationRequired, .invalidReference, .permissionDenied, .notFound:
            return true
        default:
            return false
        }
    }

    private func handleFolderImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            appModel.dismissSourceError()
            guard let url = urls.first else {
                appModel.sourceActionError = ResourceSourceError.invalidReference.localizedDescription
                reauthorizationSourceID = nil
                return
            }
            if let sourceID = reauthorizationSourceID {
                pendingAction = .reauthorize(sourceID, url)
            } else {
                pendingAction = .add(url)
            }
            reauthorizationSourceID = nil
        case .failure(let error):
            reauthorizationSourceID = nil
            guard !Self.isUserCancellation(error) else {
                appModel.dismissSourceError()
                return
            }
            appModel.sourceActionError = ResourceSourceError.mapping(error).localizedDescription
        }
    }

    private static func isUserCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
    }
}

/// 来源连接行：复用 `SourceRowView` 的身份与状态展示，再按实时连接状态
/// 附加连接中、失败原因、重试和重新授权入口。UI 只消费 `SourcesStore` 的状态。
private struct SourceConnectionRow: View {
    let entry: SourcesStore.Entry
    let retry: () -> Void
    let reauthorize: (() -> Void)?
    let remove: (() -> Void)?

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
                .frame(minHeight: 44, alignment: .leading)
            case .failed(let error):
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reauthorize {
                        Button(action: reauthorize) {
                            Label("重新授权", systemImage: "folder.badge.gearshape")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.accent)
                        .frame(minHeight: 44)
                    } else {
                        Button(action: retry) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.accent)
                        .frame(minHeight: 44)
                    }
                }
            case .disconnected where !entry.hasAdapter:
                Text("适配器开发中，即将支持")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .leading)
            case .disconnected, .ready:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let remove {
                Button(role: .destructive, action: remove) {
                    Label("移除来源", systemImage: "trash")
                }
            }
        }
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
