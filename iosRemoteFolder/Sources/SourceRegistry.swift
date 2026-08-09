import Foundation

/// 不可变的来源配置快照；不包含 adapter、请求头或底层客户端。
struct SourceRegistrySnapshot: Identifiable, Hashable, Sendable {
    let source: ResourceSource
    let hasAdapter: Bool
    /// 只表示 adapter 注册关系的版本，不暴露 adapter 或其内部状态。
    let adapterRevision: UUID

    var id: UUID { source.id }
}

/// composition root 接线错误必须在注册时显式失败，不能静默覆盖或丢弃来源。
enum SourceRegistryError: LocalizedError, Hashable, Sendable {
    case duplicateSourceID(UUID)
    case duplicateAdapterSourceID(UUID)
    case adapterSourceNotRegistered(UUID)
    case adapterSourceMismatch(expected: UUID, actual: UUID)
    case sourceNotRegistered(UUID)

    var errorDescription: String? {
        switch self {
        case .duplicateSourceID(let sourceID):
            "来源 ID 重复：\(sourceID.uuidString)"
        case .duplicateAdapterSourceID(let sourceID):
            "来源 adapter ID 重复：\(sourceID.uuidString)"
        case .adapterSourceNotRegistered(let sourceID):
            "adapter 未匹配已注册来源：\(sourceID.uuidString)"
        case .adapterSourceMismatch(let expected, let actual):
            "adapter 来源 ID 不匹配（期望 \(expected.uuidString)，实际 \(actual.uuidString)）"
        case .sourceNotRegistered(let sourceID):
            "来源未注册：\(sourceID.uuidString)"
        }
    }
}

/// 来源 adapter 的唯一所有者。
///
/// UI、SourcesStore 和内容会话只通过下列窄接口访问来源；adapter、factory、
/// ResourceReference、URLSession、FileManager 和请求头都不会越过 registry 边界。
actor SourceRegistry {
    /// 初始快照只用于同步构造 `SourcesStore`；动态变更必须通过 actor 的
    /// `currentSnapshots()` 读取，避免把可变 adapter 映射泄漏出 registry。
    nonisolated let initialSnapshots: [SourceRegistrySnapshot]
    private var sourceOrder: [UUID]
    private var sources: [UUID: ResourceSource]
    private var adapters: [UUID: any ResourceSourceAdapter]
    private var adapterRevisions: [UUID: UUID]

    init(
        sources: [ResourceSource],
        adapters: [any ResourceSourceAdapter]
    ) throws {
        var sourceIDs = Set<UUID>()
        var sourceMap: [UUID: ResourceSource] = [:]
        var sourceOrder: [UUID] = []
        for source in sources {
            guard sourceIDs.insert(source.id).inserted else {
                throw SourceRegistryError.duplicateSourceID(source.id)
            }
            sourceMap[source.id] = source
            sourceOrder.append(source.id)
        }

        var adapterMap: [UUID: any ResourceSourceAdapter] = [:]
        for adapter in adapters {
            let adapterSourceID = adapter.source.id
            guard sourceIDs.contains(adapterSourceID) else {
                throw SourceRegistryError.adapterSourceNotRegistered(adapterSourceID)
            }
            guard adapterMap[adapterSourceID] == nil else {
                throw SourceRegistryError.duplicateAdapterSourceID(adapterSourceID)
            }
            adapterMap[adapterSourceID] = adapter
        }

        let revisionMap = sourceIDs.reduce(into: [UUID: UUID]()) { result, sourceID in
            result[sourceID] = UUID()
        }

        self.sources = sourceMap
        self.sourceOrder = sourceOrder
        self.adapters = adapterMap
        self.adapterRevisions = revisionMap
        self.initialSnapshots = sources.map { source in
            SourceRegistrySnapshot(
                source: source,
                hasAdapter: adapterMap[source.id] != nil,
                adapterRevision: revisionMap[source.id] ?? UUID()
            )
        }
    }

    /// 返回不包含 adapter 的动态来源快照。
    func currentSnapshots() -> [SourceRegistrySnapshot] {
        sourceOrder.compactMap { sourceID in
            guard let source = sources[sourceID] else { return nil }
            return SourceRegistrySnapshot(
                source: source,
                hasAdapter: adapters[sourceID] != nil,
                adapterRevision: adapterRevisions[sourceID] ?? UUID()
            )
        }
    }

    /// 兼容偏好 snapshot 命名的窄读取入口；仍只暴露不可变描述。
    func snapshots() -> [SourceRegistrySnapshot] {
        currentSnapshots()
    }

    /// 注册一个新来源。重复 ID 或 adapter 接线错误均显式失败。
    func register(
        source: ResourceSource,
        adapter: (any ResourceSourceAdapter)? = nil
    ) throws {
        guard sources[source.id] == nil else {
            throw SourceRegistryError.duplicateSourceID(source.id)
        }
        if let adapter {
            guard adapter.source.id == source.id else {
                throw SourceRegistryError.adapterSourceMismatch(
                    expected: source.id,
                    actual: adapter.source.id
                )
            }
            guard adapters[adapter.source.id] == nil else {
                throw SourceRegistryError.duplicateAdapterSourceID(adapter.source.id)
            }
            adapters[source.id] = adapter
        }
        sources[source.id] = source
        adapterRevisions[source.id] = UUID()
        sourceOrder.append(source.id)
    }

    /// 替换已注册来源及其 adapter；不会把未知 ID 当成插入。
    func replace(
        source: ResourceSource,
        adapter: (any ResourceSourceAdapter)? = nil
    ) throws {
        guard sources[source.id] != nil else {
            throw SourceRegistryError.sourceNotRegistered(source.id)
        }
        if let adapter {
            guard adapter.source.id == source.id else {
                throw SourceRegistryError.adapterSourceMismatch(
                    expected: source.id,
                    actual: adapter.source.id
                )
            }
            adapters[source.id] = adapter
        } else {
            adapters.removeValue(forKey: source.id)
        }
        sources[source.id] = source
        adapterRevisions[source.id] = UUID()
    }

    /// 移除来源及其 adapter；不会删除来源对应的原目录或远端数据。
    @discardableResult
    func remove(sourceID: UUID) throws -> ResourceSource {
        guard let source = sources.removeValue(forKey: sourceID) else {
            throw SourceRegistryError.sourceNotRegistered(sourceID)
        }
        adapters.removeValue(forKey: sourceID)
        adapterRevisions.removeValue(forKey: sourceID)
        sourceOrder.removeAll { $0 == sourceID }
        return source
    }

    /// adapter 是否可用于该来源；不存在 adapter 时返回 false，不泄露其实现。
    func hasAdapter(for sourceID: UUID) -> Bool {
        adapters[sourceID] != nil
    }

    func connect(sourceID: UUID) async throws {
        let adapter = try adapter(for: sourceID)
        try await adapter.connect()
    }

    func listResources(sourceID: UUID, at path: ResourcePath) async throws -> [ResourceItem] {
        let adapter = try adapter(for: sourceID)
        return try await adapter.listResources(at: path)
    }

    func fetchMetadata(sourceID: UUID, for item: ResourceItem) async throws -> ResourceMetadata {
        let adapter = try adapter(for: sourceID)
        return try await adapter.fetchMetadata(for: item)
    }

    func readData(
        sourceID: UUID,
        for item: ResourceItem,
        range: ResourceByteRange?
    ) async throws -> Data {
        let adapter = try adapter(for: sourceID)
        return try await adapter.readData(for: item, range: range)
    }

    private func adapter(for sourceID: UUID) throws -> any ResourceSourceAdapter {
        guard let adapter = adapters[sourceID] else {
            throw ResourceSourceError.capabilityUnavailable
        }
        return adapter
    }
}
