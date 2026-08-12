import Foundation

/// 受控的资源内容读取会话。
///
/// 会话只暴露 typed metadata、带显式预算的读取和幂等终态控制；adapter、
/// ResourceItem、引用、请求头和 URL 只保留在 actor 私有实现中。
actor ResourceContentSession {
    private enum Backend: Sendable {
        case source(SourceRegistry)
        case cache(CacheCoordinator, ResourceMetadata)
    }

    private enum Operation: Sendable {
        case metadata
        case full(ResourceMetadata, maximumBytes: Int64)
        case range(ResourceByteRange, ResourceMetadata, maximumBytes: Int64)
    }

    private enum Outcome: Sendable {
        case metadata(ResourceMetadata)
        case data(Data)
        case failure(ResourceSourceError)
    }

    private let backend: Backend
    private let item: ResourceItem
    private var metadataSnapshot: ResourceMetadata?
    private var isTerminated = false
    private var activeOperations: [UUID: Task<Outcome, Never>] = [:]

    init(registry: SourceRegistry, item: ResourceItem) {
        self.backend = .source(registry)
        self.item = item
        self.metadataSnapshot = nil
    }

    init(
        cacheCoordinator: CacheCoordinator,
        item: ResourceItem,
        metadata: ResourceMetadata
    ) {
        self.backend = .cache(cacheCoordinator, metadata)
        self.item = item
        self.metadataSnapshot = metadata
    }

    /// 获取本次打开的 typed metadata 快照。首次来源探测成功后保持不变。
    func fetchMetadata() async throws -> ResourceMetadata {
        guard !isTerminated, !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }
        if let metadataSnapshot {
            return metadataSnapshot
        }

        let outcome = try await perform(.metadata)
        if case .metadata(let metadata) = outcome {
            metadataSnapshot = metadata
            return metadata
        }
        if case .failure(let error) = outcome { throw error }
        throw ResourceSourceError.invalidResponse
    }

    /// 在获取最新 metadata 并确认完整大小不超过预算后读取完整内容。
    func readData(maximumBytes: Int64) async throws -> Data {
        guard maximumBytes > 0 else { throw ResourceSourceError.invalidReference }
        let metadata = try await fetchMetadata()
        let outcome = try await perform(.full(metadata, maximumBytes: maximumBytes))
        if case .data(let data) = outcome {
            return data
        }
        if case .failure(let error) = outcome { throw error }
        throw ResourceSourceError.invalidResponse
    }

    /// 在获取最新 metadata、确认 Range 能力并通过显式预算后读取区间。
    func readData(
        range: ResourceByteRange,
        maximumBytes: Int64
    ) async throws -> Data {
        guard maximumBytes > 0 else { throw ResourceSourceError.invalidReference }
        guard let length = Self.checkedLength(of: range) else {
            throw ResourceSourceError.invalidReference
        }
        guard length <= maximumBytes else {
            throw ResourceSourceError.responseTooLarge
        }

        let metadata = try await fetchMetadata()
        let outcome = try await perform(.range(range, metadata, maximumBytes: maximumBytes))
        if case .data(let data) = outcome {
            return data
        }
        if case .failure(let error) = outcome { throw error }
        throw ResourceSourceError.invalidResponse
    }

    /// 取消所有在途操作并进入终态；重复调用无副作用。
    func cancel() {
        terminate()
    }

    /// 关闭会话并取消所有在途操作；重复调用无副作用。
    func close() {
        terminate()
    }

    private func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        activeOperations.values.forEach { $0.cancel() }
        activeOperations.removeAll()
    }

    private func perform(_ operation: Operation) async throws -> Outcome {
        guard !isTerminated else { throw ResourceSourceError.cancelled }
        guard !Task.isCancelled else { throw ResourceSourceError.cancelled }

        let operationID = UUID()
        let backend = self.backend
        let item = self.item
        let task = Task<Outcome, Never> {
            do {
                try Task.checkCancellation()
                let outcome = try await Self.execute(
                    operation,
                    backend: backend,
                    item: item
                )
                try Task.checkCancellation()
                return outcome
            } catch {
                if Task.isCancelled || error is CancellationError {
                    return .failure(.cancelled)
                }
                return .failure(ResourceSourceError.mapping(error))
            }
        }
        activeOperations[operationID] = task
        defer { activeOperations[operationID] = nil }

        let outcome = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
        guard !isTerminated, !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }
        return outcome
    }

    private static func execute(
        _ operation: Operation,
        backend: Backend,
        item: ResourceItem
    ) async throws -> Outcome {
        switch operation {
        case .metadata:
            switch backend {
            case .source(let registry):
                let metadata = try await registry.fetchMetadata(
                    sourceID: item.sourceID,
                    for: item
                )
                return .metadata(metadata)
            case .cache(_, let metadata):
                return .metadata(metadata)
            }

        case .full(let metadata, let maximumBytes):
            guard !metadata.isDirectory else {
                throw ResourceSourceError.capabilityUnavailable
            }
            guard let byteSize = metadata.byteSize,
                  byteSize >= 0,
                  byteSize <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }

            let data: Data
            switch backend {
            case .source(let registry):
                let snapshotItem = try snapshotItem(for: item, metadata: metadata)
                data = try await registry.readData(
                    sourceID: snapshotItem.sourceID,
                    for: snapshotItem,
                    range: nil
                )
            case .cache(let cacheCoordinator, _):
                guard let key = ResourceCacheKey(
                    identity: item.id,
                    revision: metadata.revision,
                    variant: .content
                ),
                let cachedData = try await cacheCoordinator.data(
                    for: key,
                    maximumBytes: maximumBytes
                ) else {
                    throw ResourceSourceError.capabilityUnavailable
                }
                data = cachedData
            }
            try Task.checkCancellation()
            guard Int64(data.count) <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }
            // 已知长度的完整正文必须精确匹配快照大小：截断（短于声明）与
            // 超长同样违约，不允许把不完整内容静默交给查看器或缓存。
            guard Int64(data.count) == byteSize else {
                throw ResourceSourceError.invalidResponse
            }
            return .data(data)

        case .range(let range, let metadata, let maximumBytes):
            guard case .source = backend else {
                throw ResourceSourceError.capabilityUnavailable
            }
            guard !metadata.isDirectory, metadata.acceptsRanges else {
                throw ResourceSourceError.capabilityUnavailable
            }
            guard let byteSize = metadata.byteSize,
                  byteSize > 0,
                  range.lowerBound < byteSize,
                  range.upperBound < byteSize else {
                throw ResourceSourceError.invalidReference
            }
            guard let requestedLength = checkedLength(of: range) else {
                throw ResourceSourceError.invalidReference
            }

            let data: Data
            switch backend {
            case .source(let registry):
                let snapshotItem = try snapshotItem(for: item, metadata: metadata)
                data = try await registry.readData(
                    sourceID: snapshotItem.sourceID,
                    for: snapshotItem,
                    range: range
                )
            case .cache:
                throw ResourceSourceError.capabilityUnavailable
            }
            try Task.checkCancellation()
            guard Int64(data.count) <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }
            guard Int64(data.count) == requestedLength else {
                throw ResourceSourceError.invalidResponse
            }
            return .data(data)
        }
    }

    private static func checkedLength(of range: ResourceByteRange) -> Int64? {
        range.validatedLength
    }

    private static func snapshotItem(
        for item: ResourceItem,
        metadata: ResourceMetadata
    ) throws -> ResourceItem {
        guard let logicalPath = ResourcePath(rawValue: item.path) else {
            throw ResourceSourceError.invalidReference
        }
        return ResourceItem(
            sourceID: item.sourceID,
            logicalPath: logicalPath,
            name: item.name,
            kind: item.kind,
            metadata: metadata,
            capabilities: item.capabilities,
            accent: item.accent
        )
    }

}
