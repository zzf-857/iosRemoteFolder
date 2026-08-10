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
    /// 成功打开过的资源，按最近打开顺序投影给 Home。
    var recentResources: [ResourceItem]
    /// 来源连接与浏览状态的唯一仓库，由应用级状态持有。
    var sourcesStore: SourcesStore
    /// 来源列表是 Store 的实时投影，Home 与 Sources 不维护第二份来源状态。
    var sources: [ResourceSource] { sourcesStore.entries.map(\.source) }
    /// 最近一次来源配置操作的可见错误；错误文本不包含 bookmark 解析后的 URL。
    var sourceActionError: String?

    @ObservationIgnored let resourceAccessService: ResourceAccessService
    @ObservationIgnored private let registry: SourceRegistry
    @ObservationIgnored private let configurationStore: LocalSourceConfigurationStore
    @ObservationIgnored private let recentResourceStore: RecentResourceStore
    @ObservationIgnored private let resourceProgressStore: ResourceProgressStore
    @ObservationIgnored private let resourceReadingStore: ResourceReadingStore
    /// UI 操作通过这个可取消、可追踪的任务串行执行 registry actor mutation，
    /// 不把异步操作丢成未跟踪的 fire-and-forget Task。
    @ObservationIgnored private var sourceMutationTask: Task<Void, Never>?
    /// mutation 任务代数；旧任务结束时不能清理已替换的新任务引用。
    @ObservationIgnored private var sourceMutationGeneration = 0

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
        recentResourceStore.retain(sourceIDs: Set(snapshots.map(\.id)))
        recentResources = recentResourceStore.items
        resourceProgressStore.retain(sourceIDs: Set(snapshots.map(\.id)))
        resourceReadingStore.retain(sourceIDs: Set(snapshots.map(\.id)))
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
            case .alist, .webdav:
                adapters.append(SampleSourceAdapter(source: source))
            case .lan:
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
