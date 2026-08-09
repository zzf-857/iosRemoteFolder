import Foundation
import Observation

enum AppTab: String, CaseIterable, Hashable, Identifiable {
    case home
    case browse
    case sources
    case offline

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    var currentTab: AppTab = .home
    var searchText = ""
    var selectedKind: ResourceKind?
    var resources: [ResourceItem]
    /// 来源连接与浏览状态的唯一仓库，由应用级状态持有。
    var sourcesStore: SourcesStore
    /// 来源列表是 Store 的实时投影，Home 与 Sources 不维护第二份来源状态。
    var sources: [ResourceSource] { sourcesStore.entries.map(\.source) }
    /// 最近一次来源配置操作的可见错误；错误文本不包含 bookmark 解析后的 URL。
    var sourceActionError: String?

    @ObservationIgnored let resourceAccessService: ResourceAccessService
    @ObservationIgnored private let registry: SourceRegistry
    @ObservationIgnored private let configurationStore: LocalSourceConfigurationStore
    /// UI 操作通过这个可取消、可追踪的任务串行执行 registry actor mutation，
    /// 不把异步操作丢成未跟踪的 fire-and-forget Task。
    @ObservationIgnored private var sourceMutationTask: Task<Void, Never>?

    init(configurationStore: LocalSourceConfigurationStore? = nil) {
        let store = configurationStore ?? LocalSourceConfigurationStore()
        self.configurationStore = store

        var restoredConfigurations: [LocalSourceConfiguration] = []
        var startupError: String?
        do {
            restoredConfigurations = try store.load()
        } catch {
            startupError = error.localizedDescription
        }

        let demoSources = SampleData.sources
        var allSources = demoSources
        var adapters = Self.makeDemoAdapters(for: demoSources)
        var startupFailures: [UUID: ResourceSourceError] = [:]
        var sourceIDs = Set(demoSources.map(\.id))

        for configuration in restoredConfigurations {
            // demo 来源与持久化来源不能共享 ID；保留 demo 并把冲突显示为配置错误，
            // 不静默覆盖 registry 中已有 adapter。
            guard sourceIDs.insert(configuration.id).inserted else {
                startupError = LocalSourceConfigurationError.duplicateSourceID(configuration.id)
                    .localizedDescription
                continue
            }

            let source = configuration.resourceSource
            allSources.append(source)
            do {
                adapters.append(
                    try LocalFilesSourceAdapter(source: source, location: configuration.location)
                )
            } catch {
                let mapped = ResourceSourceError.mapping(error)
                startupFailures[configuration.id] = mapped
            }
        }

        let registry: SourceRegistry
        do {
            registry = try SourceRegistry(sources: allSources, adapters: adapters)
        } catch {
            // demo 接线是固定代码；如果它自身无效，继续启动会破坏唯一 registry
            // 契约，因此保持原有明确失败行为。
            fatalError("来源接线无效：\(error.localizedDescription)")
        }

        self.resources = SampleData.resources
        self.registry = registry
        self.sourcesStore = SourcesStore(registry: registry)
        self.resourceAccessService = ResourceAccessService(registry: registry)
        self.sourceActionError = startupError
        self.sourcesStore.synchronize(
            with: registry.initialSnapshots,
            failures: startupFailures
        )
    }

    var filteredResources: [ResourceItem] {
        resources.filter { resource in
            let matchesKind = selectedKind == nil || resource.kind == selectedKind
            let matchesSearch = searchText.isEmpty || resource.name.localizedCaseInsensitiveContains(searchText)
            return matchesKind && matchesSearch
        }
    }

    func resetFilters() {
        selectedKind = nil
        searchText = ""
    }

    func dismissSourceError() {
        sourceActionError = nil
    }

    func isManagedLocalSource(_ sourceID: UUID) -> Bool {
        configurationStore.configuration(for: sourceID) != nil
    }

    /// 添加 Files 目录。目录 bookmark 与配置先在 composition root 创建，UI 不接触
    /// adapter 或绝对路径；完成 registry 注册后才让 Store 连接并列举根目录。
    func addLocalSource(directoryURL: URL) {
        scheduleMutation { [weak self] in
            guard let self else { return }
            await self.performAddLocalSource(directoryURL: directoryURL)
        }
    }

    /// 对 stale/失效来源重新授权；source ID 保持不变，仅替换 bookmark 与 adapter。
    func reauthorizeLocalSource(sourceID: UUID, directoryURL: URL) {
        scheduleMutation { [weak self] in
            guard let self else { return }
            await self.performReauthorize(sourceID: sourceID, directoryURL: directoryURL)
        }
    }

    /// 只移除应用配置、registry 与 Store 状态，不调用任何文件删除 API。
    func removeLocalSource(sourceID: UUID) {
        scheduleMutation { [weak self] in
            guard let self else { return }
            await self.performRemove(sourceID: sourceID)
        }
    }

    // MARK: - Composition-root mutations

    private func performAddLocalSource(directoryURL: URL) async {
        sourceActionError = nil
        do {
            try Task.checkCancellation()
            let location = try LocalSourceLocation(directoryURL: directoryURL)
            let configuration = LocalSourceConfiguration(
                displayName: Self.displayName(for: directoryURL),
                endpointDescription: "Files 文件夹",
                location: location
            )
            guard !configurationStore.contains(location: location) else {
                throw LocalSourceConfigurationError.duplicateLocation
            }

            let source = configuration.resourceSource
            let adapter = try LocalFilesSourceAdapter(source: source, location: location)
            try Task.checkCancellation()
            try configurationStore.insert(configuration)
            do {
                // Once persistence starts, finish the paired registry mutation even
                // when the caller cancels. The scheduler serializes the next
                // mutation, so this critical section cannot leave split ownership.
                try await registry.register(source: source, adapter: adapter)
            } catch {
                _ = try? configurationStore.remove(sourceID: source.id)
                throw error
            }
            await synchronizeStore()
            guard !Task.isCancelled else { return }
            sourcesStore.connect(source.id)
        } catch {
            reportSourceError(error)
        }
    }

    private func performReauthorize(sourceID: UUID, directoryURL: URL) async {
        sourceActionError = nil
        do {
            try Task.checkCancellation()
            guard let oldConfiguration = configurationStore.configuration(for: sourceID) else {
                throw LocalSourceConfigurationError.sourceNotFound(sourceID)
            }
            let location = try LocalSourceLocation(directoryURL: directoryURL)
            let configuration = LocalSourceConfiguration(
                id: oldConfiguration.id,
                displayName: Self.displayName(for: directoryURL),
                endpointDescription: oldConfiguration.endpointDescription,
                location: location
            )
            let source = configuration.resourceSource
            let adapter = try LocalFilesSourceAdapter(source: source, location: location)
            try Task.checkCancellation()
            try configurationStore.replace(configuration)
            do {
                // Configuration and registry replacement form one commit point;
                // do not stop between them after the new bookmark is persisted.
                try await registry.replace(source: source, adapter: adapter)
            } catch {
                _ = try? configurationStore.replace(oldConfiguration)
                throw error
            }
            await synchronizeStore()
            guard !Task.isCancelled else { return }
            sourcesStore.connect(sourceID)
        } catch {
            reportSourceError(error)
        }
    }

    private func performRemove(sourceID: UUID) async {
        sourceActionError = nil
        do {
            try Task.checkCancellation()
            let removedConfiguration = try configurationStore.remove(sourceID: sourceID)
            do {
                // Complete the paired removal after persistence begins. If the
                // registry rejects it, restore the configuration below.
                try await registry.remove(sourceID: sourceID)
            } catch {
                // Persisted configuration is restored if registry mutation is
                // rejected, keeping the two ownership boundaries consistent.
                _ = try? configurationStore.insert(removedConfiguration)
                throw error
            }
            await synchronizeStore()
        } catch {
            reportSourceError(error)
        }
    }

    private func synchronizeStore() async {
        let snapshots = await registry.currentSnapshots()
        sourcesStore.synchronize(with: snapshots)
    }

    private func reportSourceError(_ error: any Error) {
        guard !Task.isCancelled else { return }
        sourceActionError = error.localizedDescription
    }

    private func scheduleMutation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let previousTask = sourceMutationTask
        sourceMutationTask?.cancel()
        sourceMutationTask = Task { @MainActor in
            // Mutations are latest-wins but serialized. A cancelled operation is
            // allowed to finish its in-flight commit/rollback before the next one
            // touches the same configuration and registry.
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private static func displayName(for directoryURL: URL) -> String {
        let name = directoryURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "本地文件夹" : name
    }

    /// 演示来源的装配只属于 composition root；SourcesStore 不创建 adapter。
    private static func makeDemoAdapters(
        for sources: [ResourceSource]
    ) -> [any ResourceSourceAdapter] {
        var adapters: [any ResourceSourceAdapter] = []
        for source in sources {
            switch source.kind {
            case .local:
                adapters.append(
                    LocalFilesSourceAdapter(source: source, rootURL: URL.documentsDirectory)
                )
            case .http:
                adapters.append(
                    HTTPSourceAdapter(source: source, descriptors: demoHTTPDescriptors)
                )
            case .alist, .webdav, .lan:
                break
            }
        }
        return adapters
    }

    private static let demoHTTPDescriptors: [HTTPResourceDescriptor] = [
        HTTPResourceDescriptor(
            path: "/示例/产品手册.pdf",
            name: "产品手册.pdf",
            kind: .pdf,
            url: URL(string: "http://127.0.0.1:48080/files/product-handbook.pdf")!
        ),
        HTTPResourceDescriptor(
            path: "/示例/团队合影.jpg",
            name: "团队合影.jpg",
            kind: .image,
            url: URL(string: "http://127.0.0.1:48080/files/team-photo.jpg")!
        )
    ]
}
