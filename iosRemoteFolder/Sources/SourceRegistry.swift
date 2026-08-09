import Foundation

/// 不可变的来源配置快照；不包含 adapter、请求头或底层客户端。
struct SourceRegistrySnapshot: Identifiable, Hashable, Sendable {
    let source: ResourceSource
    let hasAdapter: Bool

    var id: UUID { source.id }
}

/// composition root 接线错误必须在注册时显式失败，不能静默覆盖或丢弃来源。
enum SourceRegistryError: LocalizedError, Hashable, Sendable {
    case duplicateSourceID(UUID)
    case duplicateAdapterSourceID(UUID)
    case adapterSourceNotRegistered(UUID)

    var errorDescription: String? {
        switch self {
        case .duplicateSourceID(let sourceID):
            "来源 ID 重复：\(sourceID.uuidString)"
        case .duplicateAdapterSourceID(let sourceID):
            "来源 adapter ID 重复：\(sourceID.uuidString)"
        case .adapterSourceNotRegistered(let sourceID):
            "adapter 未匹配已注册来源：\(sourceID.uuidString)"
        }
    }
}

/// 来源 adapter 的唯一所有者。
///
/// UI、SourcesStore 和内容会话只通过下列窄接口访问来源；adapter、factory、
/// ResourceReference、URLSession、FileManager 和请求头都不会越过 registry 边界。
actor SourceRegistry {
    nonisolated let snapshots: [SourceRegistrySnapshot]
    private let adapters: [UUID: any ResourceSourceAdapter]

    init(
        sources: [ResourceSource],
        adapters: [any ResourceSourceAdapter]
    ) throws {
        var sourceIDs = Set<UUID>()
        for source in sources {
            guard sourceIDs.insert(source.id).inserted else {
                throw SourceRegistryError.duplicateSourceID(source.id)
            }
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

        self.adapters = adapterMap
        self.snapshots = sources.map { source in
            SourceRegistrySnapshot(
                source: source,
                hasAdapter: adapterMap[source.id] != nil
            )
        }
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
