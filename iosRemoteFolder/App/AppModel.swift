import Foundation
import Observation
import SwiftData

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
    #if DEBUG
    /// 仅调试构建：`-initialTab browse|sources|offline` 启动参数用于
    /// 自动化截图验证，不影响发布行为。
    var currentTab: AppTab = {
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "-initialTab"),
           arguments.indices.contains(flagIndex + 1),
           let tab = AppTab(rawValue: arguments[flagIndex + 1]) {
            return tab
        }
        return .home
    }()
    #else
    var currentTab: AppTab = .home
    #endif
    var searchText = ""
    var selectedKind: ResourceKind?
    /// Shared Browse selection so a folder search result can open its source.
    var selectedBrowseSourceID: UUID?
    var resources: [ResourceItem]
    /// 成功打开过的资源，按最近打开顺序投影给 Home。
    var recentResources: [ResourceItem]
    /// 已经写入内容缓存、可在 Offline 页面展示的资源身份。
    var offlineResourceIDs: Set<ResourceIdentity> = []
    /// 当前内容缓存实际占用的字节数。
    var offlineByteCount: Int64 = 0
    /// 来源连接与浏览状态的唯一仓库，由应用级状态持有。
    var sourcesStore: SourcesStore
    /// 来源列表是 Store 的实时投影，Home 与 Sources 不维护第二份来源状态。
    var sources: [ResourceSource] { sourcesStore.entries.map(\.source) }
    /// 最近一次来源配置操作的可见错误；错误文本不包含 bookmark 解析后的 URL。
    var sourceActionError: String?
    /// Last background index write failure. Search reads report their own error.
    var resourceIndexError: String?

    @ObservationIgnored let resourceAccessService: ResourceAccessService
    @ObservationIgnored let resourcePreviewPipeline: ResourcePreviewPipeline
    @ObservationIgnored let cacheCoordinator: CacheCoordinator
    @ObservationIgnored let resourceIndexStore: ResourceIndexStore
    @ObservationIgnored private let registry: SourceRegistry
    @ObservationIgnored private let configurationStore: LocalSourceConfigurationStore
    @ObservationIgnored private let remoteConfigurationStore: RemoteSourceConfigurationStore
    @ObservationIgnored private let credentialStore: RemoteCredentialStore
    @ObservationIgnored private let recentResourceStore: RecentResourceStore
    @ObservationIgnored private let resourceProgressStore: ResourceProgressStore
    @ObservationIgnored private let resourceReadingStore: ResourceReadingStore
    /// 只保存可管理来源的 ID；adapter 仍由唯一 SourceRegistry 持有。
    @ObservationIgnored private var managedRemoteSourceIDs: Set<UUID> = []
    /// UI 操作通过这个可取消、可追踪的任务串行执行 registry actor mutation，
    /// 不把异步操作丢成未跟踪的 fire-and-forget Task。
    @ObservationIgnored private var sourceMutationTask: Task<Void, Never>?
    /// mutation 任务代数；旧任务结束时不能清理已替换的新任务引用。
    @ObservationIgnored private var sourceMutationGeneration = 0

    init(
        configurationStore: LocalSourceConfigurationStore? = nil,
        remoteConfigurationStore: RemoteSourceConfigurationStore? = nil,
        credentialStore: RemoteCredentialStore? = nil,
        modelContainer: ModelContainer? = nil
    ) {
        let sharedContainer: ModelContainer?
        if let modelContainer {
            guard configurationStore == nil, remoteConfigurationStore == nil else {
                fatalError("显式 ModelContainer 不能与配置 store 混合注入")
            }
            sharedContainer = modelContainer
        } else if let configurationStore, let remoteConfigurationStore {
            guard ObjectIdentifier(configurationStore.modelContainer)
                    == ObjectIdentifier(remoteConfigurationStore.modelContainer) else {
                fatalError("本地和远端配置 store 必须共享同一个 ModelContainer")
            }
            sharedContainer = nil
        } else if let configurationStore {
            // 测试/预览只注入一侧时，另一侧必须复用已注入的容器，
            // 不能悄悄创建第二份持久化来源事实。
            sharedContainer = configurationStore.modelContainer
        } else if let remoteConfigurationStore {
            sharedContainer = remoteConfigurationStore.modelContainer
        } else {
            do {
                sharedContainer = try SourceConfigurationPersistence.makePersistentContainer()
            } catch {
                fatalError("无法创建来源配置容器：\(error.localizedDescription)")
            }
        }

        let store: LocalSourceConfigurationStore
        if let configurationStore {
            store = configurationStore
        } else if let sharedContainer {
            store = LocalSourceConfigurationStore(modelContainer: sharedContainer)
        } else {
            fatalError("本地来源配置缺少持久化容器")
        }

        let remoteStore: RemoteSourceConfigurationStore
        if let remoteConfigurationStore {
            remoteStore = remoteConfigurationStore
        } else if let sharedContainer {
            remoteStore = RemoteSourceConfigurationStore(modelContainer: sharedContainer)
        } else {
            fatalError("远端来源配置缺少持久化容器")
        }
        let resolvedCredentialStore = credentialStore ?? RemoteCredentialStore()
        self.configurationStore = store
        self.remoteConfigurationStore = remoteStore
        self.credentialStore = resolvedCredentialStore

        var restoredConfigurations: [LocalSourceConfiguration] = []
        var startupError: String?
        do {
            restoredConfigurations = try store.load()
        } catch {
            startupError = error.localizedDescription
        }

        var restoredRemoteConfigurations: [RemoteSourceConfiguration] = []
        do {
            restoredRemoteConfigurations = try remoteStore.load()
        } catch {
            startupError = startupError ?? error.localizedDescription
        }

        // 生产组合根只注册用户配置的来源（D-061）：演示来源退出生产
        // 启动路径，SampleData 仅保留给测试与受控 fixture 使用。
        var allSources: [ResourceSource] = []
        var adapters: [any ResourceSourceAdapter] = []
        var startupFailures: [UUID: ResourceSourceError] = [:]
        var sourceIDs = Set<UUID>()
        var restoredRemoteIDs: Set<UUID> = []

        for configuration in restoredConfigurations {
            // 持久化来源不能共享 ID；冲突显示为配置错误，
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

        for configuration in restoredRemoteConfigurations {
            guard sourceIDs.insert(configuration.id).inserted else {
                startupError = RemoteSourceConfigurationError.duplicateSourceID(configuration.id)
                    .localizedDescription
                continue
            }

            let source = configuration.resourceSource
            allSources.append(source)
            restoredRemoteIDs.insert(configuration.id)

            var storedCredentials: RemoteCredentials?
            if let reference = configuration.credentialReference {
                do {
                    storedCredentials = try resolvedCredentialStore.load(reference: reference)
                    if storedCredentials == nil {
                        startupFailures[configuration.id] = .authenticationRequired
                    }
                } catch {
                    storedCredentials = nil
                    startupFailures[configuration.id] = .authenticationRequired
                }
            }

            do {
                adapters.append(
                    try WebDAVSourceAdapter(
                        source: source,
                        endpoint: URL(string: configuration.endpoint)!,
                        username: storedCredentials?.username,
                        password: storedCredentials?.password
                    )
                )
            } catch {
                startupFailures[configuration.id] = ResourceSourceError.mapping(error)
            }
        }

        let registry: SourceRegistry
        do {
            registry = try SourceRegistry(sources: allSources, adapters: adapters)
        } catch {
            // 接线冲突已在上方按配置去重；此处失败意味着组合根自身矛盾，
            // 继续启动会破坏唯一 registry 契约，保持明确失败行为。
            fatalError("来源接线无效：\(error.localizedDescription)")
        }

        // 无演示数据：Home 的继续/最近区域完全由真实最近记录驱动。
        self.resources = []
        let recentStore = RecentResourceStore()
        recentStore.retain(sourceIDs: Set(allSources.map(\.id)))
        self.recentResourceStore = recentStore
        self.recentResources = recentStore.items
        let progressStore = ResourceProgressStore()
        progressStore.retain(sourceIDs: Set(allSources.map(\.id)))
        self.resourceProgressStore = progressStore
        let readingStore = ResourceReadingStore()
        readingStore.retain(sourceIDs: Set(allSources.map(\.id)))
        self.resourceReadingStore = readingStore
        self.registry = registry
        let cacheCoordinator = CacheCoordinator()
        self.cacheCoordinator = cacheCoordinator
        let resourceIndexStore = ResourceIndexStore(modelContainer: store.modelContainer)
        self.resourceIndexStore = resourceIndexStore
        self.sourcesStore = SourcesStore(registry: registry)
        let resourceAccessService = ResourceAccessService(
            registry: registry,
            cacheCoordinator: cacheCoordinator
        )
        self.resourceAccessService = resourceAccessService
        let resourcePreviewPipeline = ResourcePreviewPipeline(
            accessService: resourceAccessService
        )
        self.resourcePreviewPipeline = resourcePreviewPipeline
        self.managedRemoteSourceIDs = restoredRemoteIDs
        self.sourceActionError = startupError
        self.resourceIndexError = nil
        self.sourcesStore.onDirectorySnapshot = { [weak self] sourceID, path, items in
            guard let self else { return }
            await self.indexDirectory(sourceID: sourceID, path: path, items: items)
        }
        self.sourcesStore.synchronize(
            with: registry.initialSnapshots,
            failures: startupFailures
        )
        let initialSourceIDs = Set(allSources.map(\.id))
        Task { @MainActor [weak self, resourcePreviewPipeline, initialSourceIDs] in
            await resourcePreviewPipeline.retain(sourceIDs: initialSourceIDs)
            guard let self else { return }
            await self.retainResourceIndex(sourceIDs: initialSourceIDs)
        }
        #if DEBUG
        applyDebugSourcePrefillIfRequested()
        #endif
    }

    #if DEBUG
    /// 仅调试构建：从启动参数预填一个远端来源，免去真机验证时重复输入。
    ///
    /// 机制随代码提交，但凭证只存在于安装方的启动命令中（不进源码、
    /// fixture 或仓库历史），App 收到后走既有 addRemoteSource 流程——
    /// 配置进 SwiftData、凭证进 Keychain。同 endpoint 已存在时不重复添加。
    /// 参数：`-prefillSourceKind alist|webdav -prefillSourceName <名称>
    /// -prefillSourceEndpoint <URL> -prefillSourceUsername <用户名>
    /// -prefillSourcePassword <密码>`。
    private func applyDebugSourcePrefillIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
        guard let endpoint = value(after: "-prefillSourceEndpoint"),
              !endpoint.isEmpty else {
            return
        }
        guard !sources.contains(where: { $0.endpoint == endpoint }) else { return }

        let kind: ResourceSource.SourceKind =
            value(after: "-prefillSourceKind") == "webdav" ? .webdav : .alist
        addRemoteSource(
            name: value(after: "-prefillSourceName") ?? "我的 Alist",
            endpoint: endpoint,
            kind: kind,
            username: value(after: "-prefillSourceUsername") ?? "",
            password: value(after: "-prefillSourcePassword") ?? ""
        )
    }
    #endif

    var filteredResources: [ResourceItem] {
        resources.filter { resource in
            let matchesKind = selectedKind == nil || resource.kind == selectedKind
            let matchesSearch = searchText.isEmpty || resource.name.localizedCaseInsensitiveContains(searchText)
            return matchesKind && matchesSearch
        }
    }

    /// 在没有历史记录的首次启动上保留演示内容；一旦用户打开真实资源，
    /// Home 的继续/最近区域只显示最近记录，避免静态样例遮蔽真实路径。
    var homeResources: [ResourceItem] {
        recentResources.isEmpty ? resources : recentResources
    }

    /// 只有查看器已经完成 metadata/内容准备后才写入最近记录。
    /// 传入的 metadata 是本次会话最新事实，不复用列举时的旧值。
    func recordRecent(resource: ResourceItem, metadata: ResourceMetadata) {
        guard resource.kind != .folder,
              !metadata.isDirectory,
              let path = ResourcePath(rawValue: resource.path),
              path.normalized == resource.path else {
            return
        }
        let updated = ResourceItem(
            sourceID: resource.sourceID,
            logicalPath: path,
            name: resource.name,
            kind: resource.kind,
            metadata: metadata,
            capabilities: resource.capabilities,
            accent: resource.accent
        )
        recentResourceStore.record(updated)
        recentResources = recentResourceStore.items
    }

    /// Removes only the local recent-history entry. Reading/playback progress,
    /// content caches, preview caches and the source resource stay untouched.
    func removeRecent(identity: ResourceIdentity) {
        recentResourceStore.remove(identity: identity)
        recentResources = recentResourceStore.items
    }

    /// Returns a persisted media position only when the current resource facts
    /// still match the identity and known revision captured at save time.
    func resumePosition(
        for resource: ResourceItem,
        metadata: ResourceMetadata
    ) -> ResourceResumePosition? {
        resourceProgressStore.position(for: resource, metadata: metadata)
    }

    /// Saves a media position after the viewer has obtained current metadata.
    /// Unknown revisions and non-media resources are intentionally ignored.
    func recordResumePosition(
        _ position: ResourceResumePosition,
        for resource: ResourceItem,
        metadata: ResourceMetadata
    ) {
        resourceProgressStore.record(position, for: resource, metadata: metadata)
    }

    func clearResumePosition(for resource: ResourceItem) {
        resourceProgressStore.remove(for: resource)
    }

    func readingPosition(
        for resource: ResourceItem,
        metadata: ResourceMetadata
    ) -> ResourceReadingPosition? {
        resourceReadingStore.position(for: resource, metadata: metadata)
    }

    func recordReadingPosition(
        _ position: ResourceReadingPosition,
        for resource: ResourceItem,
        metadata: ResourceMetadata
    ) {
        resourceReadingStore.record(position, for: resource, metadata: metadata)
    }

    func clearReadingPosition(for resource: ResourceItem) {
        resourceReadingStore.remove(for: resource)
    }

    /// Refreshes the Offline projection from the persistent content cache.
    /// Only resources with a known revision can participate in the projection.
    func refreshOfflineCache() async {
        var candidates: [ResourceItem] = []
        var seen = Set<ResourceIdentity>()
        for resource in recentResources + resources where seen.insert(resource.id).inserted {
            candidates.append(resource)
        }

        var available = Set<ResourceIdentity>()
        for resource in candidates {
            guard let key = ResourceCacheKey(
                identity: resource.id,
                revision: resource.metadata.revision,
                variant: .content
            ) else {
                continue
            }

            if await cacheCoordinator.state(for: key) == .offlineAvailable {
                available.insert(resource.id)
            }
        }

        offlineResourceIDs = available
        offlineByteCount = await cacheCoordinator.storedByteCount()
    }

    /// 清理本 App 管理的内容与预览缓存，来源文件不受影响。
    func clearOfflineCache() async {
        await cacheCoordinator.removeAll()
        await resourcePreviewPipeline.removeAll()
        offlineResourceIDs.removeAll()
        offlineByteCount = 0
    }

    func resetFilters() {
        selectedKind = nil
        searchText = ""
    }

    /// Opens an indexed folder through the same SourcesStore browse state used
    /// by the Browse tab. Persisted search results never bypass the registry.
    func openIndexedFolder(_ resource: ResourceItem) {
        guard resource.kind == .folder,
              sources.contains(where: { $0.id == resource.sourceID }),
              let path = ResourcePath(rawValue: resource.path),
              path.normalized == resource.path else {
            return
        }
        selectedBrowseSourceID = resource.sourceID
        sourcesStore.openDirectory(resource.sourceID, at: path)
        currentTab = .browse
    }

    func sourceName(for sourceID: UUID) -> String {
        sources.first(where: { $0.id == sourceID })?.name ?? "未知来源"
    }

    func dismissSourceError() {
        sourceActionError = nil
    }

    func isManagedLocalSource(_ sourceID: UUID) -> Bool {
        configurationStore.configuration(for: sourceID) != nil
    }

    func isManagedSource(_ sourceID: UUID) -> Bool {
        isManagedLocalSource(sourceID)
            || remoteConfigurationStore.configuration(for: sourceID) != nil
            || managedRemoteSourceIDs.contains(sourceID)
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

    /// 修改本地来源展示名称；位置 bookmark 与 source ID 保持不变。
    func editLocalSource(sourceID: UUID, displayName: String) {
        scheduleMutation { [weak self] in
            guard let self else { return }
            await self.performEditLocalSource(sourceID: sourceID, displayName: displayName)
        }
    }

    /// 只移除应用配置、registry 与 Store 状态，不调用任何文件删除 API。
    func removeLocalSource(sourceID: UUID) {
        scheduleMutation { [weak self] in
            guard let self else { return }
            await self.performRemove(sourceID: sourceID)
        }
    }

    /// Adds a WebDAV or Alist `/dav/` source. The descriptor is persisted without
    /// secrets; credentials are written to Keychain before registry registration.
    func addRemoteSource(
        name: String,
        endpoint: String,
        kind: ResourceSource.SourceKind,
        username: String,
        password: String
    ) {
        scheduleMutation { [weak self] in
            guard let self else { return }
            await self.performAddRemoteSource(
                name: name,
                endpoint: endpoint,
                kind: kind,
                username: username,
                password: password
            )
        }
    }

    /// 修改远端来源描述。认证字段留空时保留原 Keychain 凭证，填写任一字段
    /// 则用同一 source ID 的新凭证替换现有凭证。
    func editRemoteSource(
        sourceID: UUID,
        name: String,
        endpoint: String,
        kind: ResourceSource.SourceKind,
        username: String,
        password: String
    ) {
        scheduleMutation { [weak self] in
            guard let self else { return }
            await self.performEditRemoteSource(
                sourceID: sourceID,
                name: name,
                endpoint: endpoint,
                kind: kind,
                username: username,
                password: password
            )
        }
    }

    func removeManagedSource(sourceID: UUID) {
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

    private func performAddRemoteSource(
        name: String,
        endpoint: String,
        kind: ResourceSource.SourceKind,
        username: String,
        password: String
    ) async {
        sourceActionError = nil
        do {
            try Task.checkCancellation()
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty,
                  kind == .webdav || kind == .alist,
                  let rawEndpoint = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw RemoteSourceConfigurationError.invalidEndpoint
            }
            let endpointURL = try WebDAVSourceAdapter.normalizedEndpoint(rawEndpoint)
            let sourceID = UUID()
            let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentialReference = (trimmedUsername.isEmpty && password.isEmpty)
                ? nil
                : sourceID.uuidString.lowercased()
            let source = ResourceSource(
                id: sourceID,
                name: displayName,
                kind: kind,
                endpoint: endpointURL.absoluteString,
                status: .disconnected,
                itemCountDescription: ""
            )
            let configuration = RemoteSourceConfiguration(
                id: sourceID,
                displayName: displayName,
                endpoint: endpointURL,
                kind: kind,
                credentialReference: credentialReference
            )
            let adapter = try WebDAVSourceAdapter(
                source: source,
                endpoint: endpointURL,
                username: trimmedUsername,
                password: password
            )
            try Task.checkCancellation()
            if let credentialReference {
                try credentialStore.save(
                    RemoteCredentials(username: trimmedUsername, password: password),
                    reference: credentialReference
                )
            }
            do {
                try remoteConfigurationStore.insert(configuration)
            } catch {
                if let credentialReference {
                    try? credentialStore.remove(reference: credentialReference)
                }
                throw error
            }
            do {
                // After descriptor persistence starts, finish paired registry
                // registration before honoring cancellation.
                try await registry.register(source: source, adapter: adapter)
            } catch {
                _ = try? remoteConfigurationStore.remove(sourceID: sourceID)
                if let credentialReference {
                    try? credentialStore.remove(reference: credentialReference)
                }
                throw error
            }
            managedRemoteSourceIDs.insert(source.id)
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
            let changesContentNamespace = !oldConfiguration.location
                .isSameResolvedLocation(as: location)
            let configuration = LocalSourceConfiguration(
                id: oldConfiguration.id,
                displayName: oldConfiguration.displayName,
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
            if changesContentNamespace {
                await invalidateDerivedContent(for: sourceID)
            }
            guard !Task.isCancelled else { return }
            sourcesStore.connect(sourceID)
        } catch {
            reportSourceError(error)
        }
    }

    private func performEditLocalSource(sourceID: UUID, displayName: String) async {
        sourceActionError = nil
        do {
            try Task.checkCancellation()
            guard let oldConfiguration = configurationStore.configuration(for: sourceID) else {
                throw LocalSourceConfigurationError.sourceNotFound(sourceID)
            }
            let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw LocalSourceConfigurationError.invalidDisplayName
            }

            let configuration = LocalSourceConfiguration(
                id: oldConfiguration.id,
                displayName: trimmedName,
                endpointDescription: oldConfiguration.endpointDescription,
                location: oldConfiguration.location
            )
            let source = configuration.resourceSource
            let adapter = try LocalFilesSourceAdapter(
                source: source,
                location: configuration.location
            )
            try Task.checkCancellation()
            try configurationStore.replace(configuration)
            do {
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

    private func performEditRemoteSource(
        sourceID: UUID,
        name: String,
        endpoint: String,
        kind: ResourceSource.SourceKind,
        username: String,
        password: String
    ) async {
        sourceActionError = nil
        do {
            try Task.checkCancellation()
            guard let oldConfiguration = remoteConfigurationStore.configuration(for: sourceID) else {
                throw RemoteSourceConfigurationError.sourceNotFound(sourceID)
            }
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else {
                throw RemoteSourceConfigurationError.invalidDisplayName
            }
            guard kind == .webdav || kind == .alist,
                  let rawEndpoint = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw RemoteSourceConfigurationError.invalidEndpoint
            }
            let endpointURL = try WebDAVSourceAdapter.normalizedEndpoint(rawEndpoint)
            let changesContentNamespace = oldConfiguration.kind != kind
                || oldConfiguration.endpoint != endpointURL.absoluteString
            let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasNewCredentials = !trimmedUsername.isEmpty || !password.isEmpty

            var oldCredentials: RemoteCredentials?
            if let oldReference = oldConfiguration.credentialReference {
                do {
                    oldCredentials = try credentialStore.load(reference: oldReference)
                } catch {
                    if !hasNewCredentials {
                        throw RemoteSourceConfigurationError.credentialUnavailable
                    }
                }
                if oldCredentials == nil, !hasNewCredentials {
                    throw RemoteSourceConfigurationError.credentialUnavailable
                }
            }

            let credentialReference: String?
            let credentials: RemoteCredentials?
            if hasNewCredentials {
                credentialReference = oldConfiguration.credentialReference
                    ?? sourceID.uuidString.lowercased()
                credentials = RemoteCredentials(
                    username: trimmedUsername,
                    password: password
                )
            } else {
                credentialReference = oldConfiguration.credentialReference
                credentials = oldCredentials
            }

            let source = ResourceSource(
                id: sourceID,
                name: displayName,
                kind: kind,
                endpoint: endpointURL.absoluteString,
                status: .disconnected,
                itemCountDescription: ""
            )
            let configuration = RemoteSourceConfiguration(
                id: sourceID,
                displayName: displayName,
                endpoint: endpointURL,
                kind: kind,
                credentialReference: credentialReference
            )
            let adapter = try WebDAVSourceAdapter(
                source: source,
                endpoint: endpointURL,
                username: credentials?.username,
                password: credentials?.password
            )
            try Task.checkCancellation()

            var didWriteCredentials = false
            var didPersistConfiguration = false
            do {
                if hasNewCredentials, let credentialReference, let credentials {
                    try credentialStore.save(credentials, reference: credentialReference)
                    didWriteCredentials = true
                }
                try remoteConfigurationStore.replace(configuration)
                didPersistConfiguration = true
                try await registry.replace(source: source, adapter: adapter)
            } catch {
                if didPersistConfiguration {
                    _ = try? remoteConfigurationStore.replace(oldConfiguration)
                }
                if didWriteCredentials, let credentialReference = credentialReference {
                    restoreRemoteCredentials(
                        reference: credentialReference,
                        oldReference: oldConfiguration.credentialReference,
                        oldCredentials: oldCredentials
                    )
                }
                throw error
            }

            managedRemoteSourceIDs.insert(sourceID)
            await synchronizeStore()
            if changesContentNamespace {
                await invalidateDerivedContent(for: sourceID)
            }
            guard !Task.isCancelled else { return }
            sourcesStore.connect(sourceID)
        } catch {
            reportSourceError(error)
        }
    }

    private func restoreRemoteCredentials(
        reference: String,
        oldReference: String?,
        oldCredentials: RemoteCredentials?
    ) {
        guard reference == oldReference else {
            try? credentialStore.remove(reference: reference)
            return
        }
        if let oldCredentials {
            try? credentialStore.save(oldCredentials, reference: reference)
        } else {
            try? credentialStore.remove(reference: reference)
        }
    }

    private func performRemove(sourceID: UUID) async {
        sourceActionError = nil
        do {
            try Task.checkCancellation()
            if configurationStore.configuration(for: sourceID) != nil {
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
            } else if remoteConfigurationStore.configuration(for: sourceID) != nil {
                let removedConfiguration = try remoteConfigurationStore.remove(sourceID: sourceID)
                do {
                    try await registry.remove(sourceID: sourceID)
                } catch {
                    _ = try? remoteConfigurationStore.insert(removedConfiguration)
                    throw error
                }
                managedRemoteSourceIDs.remove(sourceID)
                if let reference = removedConfiguration.credentialReference {
                    do {
                        try credentialStore.remove(reference: reference)
                    } catch {
                        sourceActionError = "来源已移除，但系统凭证清理失败"
                    }
                }
            } else {
                throw LocalSourceConfigurationError.sourceNotFound(sourceID)
            }
            await synchronizeStore()
        } catch {
            reportSourceError(error)
        }
    }

    private func synchronizeStore() async {
        let snapshots = await registry.currentSnapshots()
        sourcesStore.synchronize(with: snapshots)
        let sourceIDs = Set(snapshots.map(\.id))
        if let selectedBrowseSourceID, !sourceIDs.contains(selectedBrowseSourceID) {
            self.selectedBrowseSourceID = nil
        }
        recentResourceStore.retain(sourceIDs: sourceIDs)
        recentResources = recentResourceStore.items
        resourceProgressStore.retain(sourceIDs: sourceIDs)
        resourceReadingStore.retain(sourceIDs: sourceIDs)
        await cacheCoordinator.retain(sourceIDs: sourceIDs)
        await resourcePreviewPipeline.retain(sourceIDs: sourceIDs)
        await retainResourceIndex(sourceIDs: sourceIDs)
        await refreshOfflineCache()
    }

    /// A source ID can survive reauthorization or endpoint editing, but content
    /// derived from the old namespace cannot. Names and credentials alone do
    /// not call this path.
    private func invalidateDerivedContent(for sourceID: UUID) async {
        recentResourceStore.remove(sourceID: sourceID)
        recentResources = recentResourceStore.items
        resourceProgressStore.remove(sourceID: sourceID)
        resourceReadingStore.remove(sourceID: sourceID)
        await cacheCoordinator.remove(sourceID: sourceID)
        await resourcePreviewPipeline.remove(sourceID: sourceID)
        do {
            try await resourceIndexStore.remove(sourceID: sourceID)
            resourceIndexError = nil
        } catch {
            resourceIndexError = error.localizedDescription
        }
        await refreshOfflineCache()
    }

    private func indexDirectory(
        sourceID: UUID,
        path: ResourcePath,
        items: [ResourceItem]
    ) async {
        do {
            try await resourceIndexStore.replaceDirectory(
                sourceID: sourceID,
                parentPath: path,
                items: items
            )
            resourceIndexError = nil
        } catch {
            resourceIndexError = error.localizedDescription
        }
    }

    private func retainResourceIndex(sourceIDs: Set<UUID>) async {
        do {
            try await resourceIndexStore.retain(sourceIDs: sourceIDs)
            resourceIndexError = nil
        } catch {
            resourceIndexError = error.localizedDescription
        }
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
        sourceMutationGeneration += 1
        let generation = sourceMutationGeneration
        sourceMutationTask = Task { @MainActor in
            defer {
                self.finishSourceMutation(generation: generation)
            }
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

    private func finishSourceMutation(generation: Int) {
        guard sourceMutationGeneration == generation else { return }
        sourceMutationTask = nil
    }

    private static func displayName(for directoryURL: URL) -> String {
        let name = directoryURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "本地文件夹" : name
    }

}

/// 临时的最近资源窄存储。
///
/// D-032 接入 SwiftData 前只保存不敏感的稳定身份和展示 metadata；请求 URL、
/// headers、凭证、绝对文件 URL 和内容字节均不进入持久化 payload。
@MainActor
final class RecentResourceStore {
    private static let currentVersion = 1
    private static let storageKey = "recentResources.v1"
    private static let maximumItemCount = 20

    private struct Payload: Codable {
        let version: Int
        let items: [StoredItem]
    }

    private struct StoredItem: Codable {
        let identityKey: String
        let path: String
        let name: String
        let kind: String
        let byteSize: Int64?
        let modifiedAt: Date?
        let mimeType: String?
        let typeIdentifier: String?
        let isDirectory: Bool
        let acceptsRanges: Bool
        let revisionKind: String
        let revisionValue: String?
        let revisionDate: Date?
        let revisionByteSize: Int64?
        let capabilities: Int
        let accent: String

        init(resource: ResourceItem) {
            identityKey = resource.id.identityKey
            path = resource.path
            name = resource.name
            kind = resource.kind.rawValue
            byteSize = resource.metadata.byteSize
            modifiedAt = resource.metadata.modifiedAt
            mimeType = resource.metadata.mimeType
            typeIdentifier = resource.metadata.typeIdentifier
            isDirectory = resource.metadata.isDirectory
            acceptsRanges = resource.metadata.acceptsRanges
            switch resource.metadata.revision {
            case .etag(let value):
                revisionKind = "etag"
                revisionValue = value
                revisionDate = nil
                revisionByteSize = nil
            case .serverVersion(let value):
                revisionKind = "serverVersion"
                revisionValue = value
                revisionDate = nil
                revisionByteSize = nil
            case .modifiedAndSize(let modifiedAt, let byteSize):
                revisionKind = "modifiedAndSize"
                revisionValue = nil
                revisionDate = modifiedAt
                revisionByteSize = byteSize
            case .unknown:
                revisionKind = "unknown"
                revisionValue = nil
                revisionDate = nil
                revisionByteSize = nil
            }
            capabilities = resource.capabilities.rawValue
            accent = resource.accent.rawValue
        }

        func resource() -> ResourceItem? {
            guard let identity = ResourceIdentity(identityKey: identityKey),
                  let logicalPath = ResourcePath(rawValue: path),
                  logicalPath.normalized == path,
                  identity.logicalPath == path,
                  let kind = ResourceKind(rawValue: kind),
                  kind != .folder,
                  !isDirectory,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let accent = ResourceAccent(rawValue: accent) else {
                return nil
            }

            let revision: ResourceRevision
            switch revisionKind {
            case "etag":
                if let revisionValue, !revisionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    revision = .etag(revisionValue)
                } else {
                    revision = .unknown
                }
            case "serverVersion":
                if let revisionValue, !revisionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    revision = .serverVersion(revisionValue)
                } else {
                    revision = .unknown
                }
            case "modifiedAndSize":
                if let revisionDate, let revisionByteSize, revisionByteSize >= 0 {
                    revision = .modifiedAndSize(modifiedAt: revisionDate, byteSize: revisionByteSize)
                } else {
                    revision = .unknown
                }
            default:
                revision = .unknown
            }

            let metadata = ResourceMetadata(
                byteSize: byteSize,
                modifiedAt: modifiedAt,
                mimeType: mimeType,
                typeIdentifier: typeIdentifier,
                isDirectory: false,
                acceptsRanges: acceptsRanges,
                revision: revision
            )
            return ResourceItem(
                sourceID: identity.sourceID,
                logicalPath: logicalPath,
                name: name,
                kind: kind,
                metadata: metadata,
                capabilities: ResourceCapability(rawValue: capabilities),
                accent: accent
            )
        }
    }

    private let defaults: UserDefaults
    private(set) var items: [ResourceItem]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion else {
            self.items = []
            return
        }
        self.items = payload.items.compactMap { $0.resource() }
    }

    func record(_ resource: ResourceItem) {
        guard resource.kind != .folder,
              !resource.metadata.isDirectory,
              ResourcePath(rawValue: resource.path)?.normalized == resource.path else {
            return
        }
        let identity = resource.id
        items.removeAll { $0.id == identity }
        items.insert(resource, at: 0)
        if items.count > Self.maximumItemCount {
            items.removeLast(items.count - Self.maximumItemCount)
        }
        persist()
    }

    func retain(sourceIDs: Set<UUID>) {
        let retained = items.filter { sourceIDs.contains($0.sourceID) }
        guard retained.count != items.count else { return }
        items = retained
        persist()
    }

    func remove(sourceID: UUID) {
        let retained = items.filter { $0.sourceID != sourceID }
        guard retained.count != items.count else { return }
        items = retained
        persist()
    }

    func remove(identity: ResourceIdentity) {
        let retained = items.filter { $0.id != identity }
        guard retained.count != items.count else { return }
        items = retained
        persist()
    }

    private func persist() {
        let payload = Payload(version: Self.currentVersion, items: items.map(StoredItem.init(resource:)))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Temporary revision-aware media resume storage.
///
/// D-032 will decide the durable schema. Until then this narrow store keeps
/// only a canonical identity, known revision evidence, and a bounded time
/// value. It never receives a URL, adapter, credential, or content payload.
@MainActor
final class ResourceProgressStore {
    private static let currentVersion = 1
    private static let storageKey = "resourceResume.v1"
    private static let maximumItemCount = 20

    private struct Payload: Codable {
        let version: Int
        let items: [StoredItem]
    }

    private struct StoredItem: Codable {
        let identityKey: String
        let revisionKind: String
        let revisionValue: String?
        let revisionDate: Date?
        let revisionByteSize: Int64?
        let seconds: Double
        let updatedAt: Date

        init(
            position: ResourceResumePosition,
            resource: ResourceItem,
            metadata: ResourceMetadata
        ) {
            identityKey = resource.id.identityKey
            seconds = position.secondsValue ?? 0
            updatedAt = Date()
            switch metadata.revision {
            case .etag(let value):
                revisionKind = "etag"
                revisionValue = value
                revisionDate = nil
                revisionByteSize = nil
            case .serverVersion(let value):
                revisionKind = "serverVersion"
                revisionValue = value
                revisionDate = nil
                revisionByteSize = nil
            case .modifiedAndSize(let modifiedAt, let byteSize):
                revisionKind = "modifiedAndSize"
                revisionValue = nil
                revisionDate = modifiedAt
                revisionByteSize = byteSize
            case .unknown:
                revisionKind = "unknown"
                revisionValue = nil
                revisionDate = nil
                revisionByteSize = nil
            }
        }

        var identity: ResourceIdentity? {
            ResourceIdentity(identityKey: identityKey)
        }

        var revision: ResourceRevision? {
            switch revisionKind {
            case "etag":
                guard let revisionValue,
                      !revisionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .etag(revisionValue)
            case "serverVersion":
                guard let revisionValue,
                      !revisionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .serverVersion(revisionValue)
            case "modifiedAndSize":
                guard let revisionDate, let revisionByteSize, revisionByteSize >= 0 else {
                    return nil
                }
                return .modifiedAndSize(modifiedAt: revisionDate, byteSize: revisionByteSize)
            default:
                return nil
            }
        }
    }

    private let defaults: UserDefaults
    private var items: [StoredItem]

    var count: Int { items.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion else {
            self.items = []
            return
        }
        self.items = payload.items.filter { item in
            item.identity != nil
                && item.revision?.isKnown == true
                && item.seconds.isFinite
                && item.seconds >= 0
        }
    }

    func position(
        for resource: ResourceItem,
        metadata: ResourceMetadata
    ) -> ResourceResumePosition? {
        guard Self.isSupportedMedia(resource), Self.hasCanonicalIdentity(resource) else {
            return nil
        }

        guard let index = items.firstIndex(where: { $0.identityKey == resource.id.identityKey }) else {
            return nil
        }

        guard metadata.revision.isKnown else {
            remove(at: index)
            return nil
        }

        let item = items[index]
        guard item.revision == metadata.revision,
              item.seconds.isFinite,
              item.seconds >= 0 else {
            remove(at: index)
            return nil
        }
        return .seconds(item.seconds)
    }

    func record(
        _ position: ResourceResumePosition,
        for resource: ResourceItem,
        metadata: ResourceMetadata
    ) {
        guard Self.isSupportedMedia(resource),
              Self.hasCanonicalIdentity(resource),
              metadata.revision.isKnown,
              let seconds = position.secondsValue else {
            return
        }

        let stored = StoredItem(position: .seconds(seconds), resource: resource, metadata: metadata)
        items.removeAll { $0.identityKey == resource.id.identityKey }
        items.insert(stored, at: 0)
        if items.count > Self.maximumItemCount {
            items.removeLast(items.count - Self.maximumItemCount)
        }
        persist()
    }

    func remove(for resource: ResourceItem) {
        let originalCount = items.count
        items.removeAll { $0.identityKey == resource.id.identityKey }
        guard items.count != originalCount else { return }
        persist()
    }

    func retain(sourceIDs: Set<UUID>) {
        let retained = items.filter { item in
            guard let identity = item.identity else { return false }
            return sourceIDs.contains(identity.sourceID)
        }
        guard retained.count != items.count else { return }
        items = retained
        persist()
    }

    func remove(sourceID: UUID) {
        let retained = items.filter { $0.identity?.sourceID != sourceID }
        guard retained.count != items.count else { return }
        items = retained
        persist()
    }

    private func remove(at index: Int) {
        items.remove(at: index)
        persist()
    }

    private func persist() {
        let payload = Payload(version: Self.currentVersion, items: items)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func isSupportedMedia(_ resource: ResourceItem) -> Bool {
        resource.kind == .audio || resource.kind == .video
    }

    private static func hasCanonicalIdentity(_ resource: ResourceItem) -> Bool {
        guard let path = ResourcePath(rawValue: resource.path) else { return false }
        return path.normalized == resource.path
            && resource.id.logicalPath == resource.path
    }
}

/// Temporary revision-aware document reading position storage.
///
/// This store deliberately uses a separate key from media progress so the two
/// position domains cannot be decoded as one another during future migrations.
@MainActor
final class ResourceReadingStore {
    private static let currentVersion = 1
    private static let storageKey = "resourceReading.v1"
    private static let maximumItemCount = 20

    private struct Payload: Codable {
        let version: Int
        let items: [StoredItem]
    }

    private struct StoredItem: Codable {
        let identityKey: String
        let revisionKind: String
        let revisionValue: String?
        let revisionDate: Date?
        let revisionByteSize: Int64?
        let positionKind: String
        let pageIndex: Int?
        let fraction: Double?
        let updatedAt: Date

        init(
            position: ResourceReadingPosition,
            resource: ResourceItem,
            metadata: ResourceMetadata
        ) {
            identityKey = resource.id.identityKey
            updatedAt = Date()
            switch metadata.revision {
            case .etag(let value):
                revisionKind = "etag"
                revisionValue = value
                revisionDate = nil
                revisionByteSize = nil
            case .serverVersion(let value):
                revisionKind = "serverVersion"
                revisionValue = value
                revisionDate = nil
                revisionByteSize = nil
            case .modifiedAndSize(let modifiedAt, let byteSize):
                revisionKind = "modifiedAndSize"
                revisionValue = nil
                revisionDate = modifiedAt
                revisionByteSize = byteSize
            case .unknown:
                revisionKind = "unknown"
                revisionValue = nil
                revisionDate = nil
                revisionByteSize = nil
            }

            switch position {
            case .pdf(let pageIndex):
                positionKind = "pdf"
                self.pageIndex = pageIndex
                fraction = nil
            case .text(let value):
                positionKind = "text"
                pageIndex = nil
                fraction = value
            }
        }

        var identity: ResourceIdentity? {
            ResourceIdentity(identityKey: identityKey)
        }

        var revision: ResourceRevision? {
            switch revisionKind {
            case "etag":
                guard let revisionValue,
                      !revisionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .etag(revisionValue)
            case "serverVersion":
                guard let revisionValue,
                      !revisionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .serverVersion(revisionValue)
            case "modifiedAndSize":
                guard let revisionDate, let revisionByteSize, revisionByteSize >= 0 else {
                    return nil
                }
                return .modifiedAndSize(modifiedAt: revisionDate, byteSize: revisionByteSize)
            default:
                return nil
            }
        }

        var position: ResourceReadingPosition? {
            switch positionKind {
            case "pdf":
                guard let pageIndex, pageIndex >= 0 else { return nil }
                return .pdf(pageIndex: pageIndex)
            case "text":
                guard let fraction,
                      fraction.isFinite,
                      (0...1).contains(fraction) else { return nil }
                return .text(fraction: fraction)
            default:
                return nil
            }
        }
    }

    private let defaults: UserDefaults
    private var items: [StoredItem]

    var count: Int { items.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion else {
            self.items = []
            return
        }
        self.items = payload.items.filter { item in
            item.identity != nil
                && item.revision?.isKnown == true
                && item.position != nil
        }
    }

    func position(
        for resource: ResourceItem,
        metadata: ResourceMetadata
    ) -> ResourceReadingPosition? {
        guard Self.supportsReading(resource), Self.hasCanonicalIdentity(resource) else {
            return nil
        }
        guard let index = items.firstIndex(where: { $0.identityKey == resource.id.identityKey }) else {
            return nil
        }
        guard metadata.revision.isKnown else {
            remove(at: index)
            return nil
        }
        let item = items[index]
        guard item.revision == metadata.revision,
              let position = item.position,
              Self.isCompatible(position, with: resource.kind) else {
            remove(at: index)
            return nil
        }
        return position
    }

    func record(
        _ position: ResourceReadingPosition,
        for resource: ResourceItem,
        metadata: ResourceMetadata
    ) {
        guard Self.supportsReading(resource),
              Self.hasCanonicalIdentity(resource),
              metadata.revision.isKnown,
              Self.isCompatible(position, with: resource.kind) else {
            return
        }
        let stored = StoredItem(position: position, resource: resource, metadata: metadata)
        items.removeAll { $0.identityKey == resource.id.identityKey }
        items.insert(stored, at: 0)
        if items.count > Self.maximumItemCount {
            items.removeLast(items.count - Self.maximumItemCount)
        }
        persist()
    }

    func remove(for resource: ResourceItem) {
        let originalCount = items.count
        items.removeAll { $0.identityKey == resource.id.identityKey }
        guard items.count != originalCount else { return }
        persist()
    }

    func retain(sourceIDs: Set<UUID>) {
        let retained = items.filter { item in
            guard let identity = item.identity else { return false }
            return sourceIDs.contains(identity.sourceID)
        }
        guard retained.count != items.count else { return }
        items = retained
        persist()
    }

    func remove(sourceID: UUID) {
        let retained = items.filter { $0.identity?.sourceID != sourceID }
        guard retained.count != items.count else { return }
        items = retained
        persist()
    }

    private func remove(at index: Int) {
        items.remove(at: index)
        persist()
    }

    private func persist() {
        let payload = Payload(version: Self.currentVersion, items: items)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func supportsReading(_ resource: ResourceItem) -> Bool {
        resource.kind == .pdf || resource.kind == .text || resource.kind == .markdown
    }

    private static func isCompatible(
        _ position: ResourceReadingPosition,
        with kind: ResourceKind
    ) -> Bool {
        switch (position, kind) {
        case (.pdf(let pageIndex), .pdf):
            return pageIndex >= 0
        case (.text(let fraction), .text), (.text(let fraction), .markdown):
            return fraction.isFinite && (0...1).contains(fraction)
        default:
            return false
        }
    }

    private static func hasCanonicalIdentity(_ resource: ResourceItem) -> Bool {
        guard let path = ResourcePath(rawValue: resource.path) else { return false }
        return path.normalized == resource.path
            && resource.id.logicalPath == resource.path
    }
}
