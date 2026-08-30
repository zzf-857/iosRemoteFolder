import Foundation

/// 受控的资源内容读取会话。
///
/// 会话只暴露 typed metadata、带显式预算的读取和幂等终态控制；adapter、
/// ResourceItem、引用、请求头和 URL 只保留在 actor 私有实现中。
actor ResourceContentSession {
    static let signaturePrefixByteLimit: Int64 = 4 * 1024

    private enum Backend: Sendable {
        case source(SourceRegistry, CacheCoordinator?)
        case cache(CacheCoordinator, ResourceMetadata)
    }

    private enum Operation: Sendable {
        case metadata
        case full(ResourceMetadata, maximumBytes: Int64)
        case range(ResourceByteRange, ResourceMetadata, maximumBytes: Int64)
        case signaturePrefix(ResourceMetadata)
    }

    private enum Outcome: Sendable {
        case metadata(ResourceMetadata)
        case data(Data)
        case failure(ResourceSourceError)
    }

    private struct PrefixWaiter {
        let continuation: CheckedContinuation<Data, any Error>
    }

    private struct PrefixInFlight {
        let id: UUID
        let task: Task<Outcome, Never>
        var waiters: [UUID: PrefixWaiter]
    }

    private let backend: Backend
    private let item: ResourceItem
    private var metadataSnapshot: ResourceMetadata?
    private var completeDataSnapshot: Data?
    private var signaturePrefixSnapshot: Data?
    private var signaturePrefixInFlight: PrefixInFlight?
    private var isTerminated = false
    private var activeOperations: [UUID: Task<Outcome, Never>] = [:]

    init(
        registry: SourceRegistry,
        item: ResourceItem,
        cacheCoordinator: CacheCoordinator? = nil
    ) {
        self.backend = .source(registry, cacheCoordinator)
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
        if let byteSize = metadata.byteSize,
           byteSize >= 0,
           byteSize <= Self.signaturePrefixByteLimit {
            guard byteSize <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }
            return try await readSignaturePrefix()
        }
        if let completeDataSnapshot,
           Int64(completeDataSnapshot.count) == metadata.byteSize,
           Int64(completeDataSnapshot.count) <= maximumBytes {
            return completeDataSnapshot
        }
        let outcome = try await perform(.full(metadata, maximumBytes: maximumBytes))
        if case .data(let data) = outcome {
            completeDataSnapshot = data
            if signaturePrefixSnapshot == nil {
                signaturePrefixSnapshot = Data(
                    data.prefix(Int(Self.signaturePrefixByteLimit))
                )
            }
            return data
        }
        if case .failure(let error) = outcome { throw error }
        throw ResourceSourceError.invalidResponse
    }

    /// Reads at most 4 KiB for deterministic content-signature inspection.
    /// Concurrent callers share one operation, and a complete small body is
    /// retained for the viewer's subsequent full-data read.
    func readSignaturePrefix() async throws -> Data {
        guard !isTerminated, !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }
        if let signaturePrefixSnapshot {
            return signaturePrefixSnapshot
        }

        let metadata = try await fetchMetadata()
        if let completeDataSnapshot,
           Int64(completeDataSnapshot.count) == metadata.byteSize {
            let prefix = Data(
                completeDataSnapshot.prefix(Int(Self.signaturePrefixByteLimit))
            )
            signaturePrefixSnapshot = prefix
            return prefix
        }
        guard !metadata.isDirectory else {
            throw ResourceSourceError.capabilityUnavailable
        }
        if metadata.byteSize == 0 {
            signaturePrefixSnapshot = Data()
            completeDataSnapshot = Data()
            return Data()
        }
        if metadata.byteSize == nil,
           !metadata.acceptsRanges {
            throw ResourceSourceError.capabilityUnavailable
        }

        let waiterID = UUID()
        let data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                addSignaturePrefixWaiter(continuation, id: waiterID, metadata: metadata)
                if Task.isCancelled {
                    cancelSignaturePrefixWaiter(waiterID)
                }
            }
        }, onCancel: {
            Task { await self.cancelSignaturePrefixWaiter(waiterID) }
        })
        guard !Task.isCancelled, !isTerminated else {
            throw ResourceSourceError.cancelled
        }
        return data
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
        if let prefix = signaturePrefixInFlight {
            signaturePrefixInFlight = nil
            prefix.task.cancel()
            prefix.waiters.values.forEach {
                $0.continuation.resume(throwing: ResourceSourceError.cancelled)
            }
        }
        completeDataSnapshot = nil
        signaturePrefixSnapshot = nil
    }

    private func perform(_ operation: Operation) async throws -> Outcome {
        guard !isTerminated else { throw ResourceSourceError.cancelled }
        guard !Task.isCancelled else { throw ResourceSourceError.cancelled }

        let operationID = UUID()
        let task = makeOperationTask(operation)
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

    private func makeOperationTask(_ operation: Operation) -> Task<Outcome, Never> {
        let backend = self.backend
        let item = self.item
        return Task<Outcome, Never> {
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
    }

    private func addSignaturePrefixWaiter(
        _ continuation: CheckedContinuation<Data, any Error>,
        id waiterID: UUID,
        metadata: ResourceMetadata
    ) {
        guard !isTerminated else {
            continuation.resume(throwing: ResourceSourceError.cancelled)
            return
        }
        if let signaturePrefixSnapshot {
            continuation.resume(returning: signaturePrefixSnapshot)
            return
        }
        if var existing = signaturePrefixInFlight {
            existing.waiters[waiterID] = PrefixWaiter(continuation: continuation)
            signaturePrefixInFlight = existing
            return
        }

        let id = UUID()
        let task = makeOperationTask(.signaturePrefix(metadata))
        signaturePrefixInFlight = PrefixInFlight(
            id: id,
            task: task,
            waiters: [waiterID: PrefixWaiter(continuation: continuation)]
        )
        Task {
            let outcome = await task.value
            completeSignaturePrefix(outcome, id: id, metadata: metadata)
        }
    }

    private func completeSignaturePrefix(
        _ outcome: Outcome,
        id: UUID,
        metadata: ResourceMetadata
    ) {
        guard let current = signaturePrefixInFlight,
              current.id == id else {
            return
        }
        signaturePrefixInFlight = nil
        guard !isTerminated else {
            current.waiters.values.forEach {
                $0.continuation.resume(throwing: ResourceSourceError.cancelled)
            }
            return
        }

        switch outcome {
        case .data(let data):
            signaturePrefixSnapshot = data
            if let byteSize = metadata.byteSize,
               byteSize == Int64(data.count) {
                completeDataSnapshot = data
            }
            current.waiters.values.forEach { $0.continuation.resume(returning: data) }
        case .failure(let error):
            current.waiters.values.forEach { $0.continuation.resume(throwing: error) }
        case .metadata:
            current.waiters.values.forEach {
                $0.continuation.resume(throwing: ResourceSourceError.invalidResponse)
            }
        }
    }

    private func cancelSignaturePrefixWaiter(_ waiterID: UUID) {
        guard var current = signaturePrefixInFlight,
              let waiter = current.waiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.continuation.resume(throwing: ResourceSourceError.cancelled)
        if current.waiters.isEmpty {
            signaturePrefixInFlight = nil
            current.task.cancel()
        } else {
            signaturePrefixInFlight = current
        }
    }

    private static func execute(
        _ operation: Operation,
        backend: Backend,
        item: ResourceItem
    ) async throws -> Outcome {
        switch operation {
        case .metadata:
            switch backend {
            case .source(let registry, _):
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
            case .source(let registry, _):
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
            case .source(let registry, _):
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

        case .signaturePrefix(let metadata):
            guard !metadata.isDirectory else {
                throw ResourceSourceError.capabilityUnavailable
            }
            if let byteSize = metadata.byteSize, byteSize < 0 {
                throw ResourceSourceError.invalidReference
            }
            if metadata.byteSize == 0 {
                return .data(Data())
            }
            if case .source(_, let cacheCoordinator) = backend,
               let cacheCoordinator,
               let byteSize = metadata.byteSize,
               let key = ResourceCacheKey(
                   identity: item.id,
                   revision: metadata.revision,
                   variant: .content
               ),
               let cachedPrefix = try await cacheCoordinator.prefixData(
                   for: key,
                   expectedByteCount: byteSize,
                   maximumBytes: signaturePrefixByteLimit
               ) {
                return .data(cachedPrefix)
            }
            if let byteSize = metadata.byteSize,
               byteSize <= signaturePrefixByteLimit {
                return try await execute(
                    .full(metadata, maximumBytes: signaturePrefixByteLimit),
                    backend: backend,
                    item: item
                )
            }

            switch backend {
            case .source(let registry, _):
                guard metadata.acceptsRanges else {
                    throw ResourceSourceError.capabilityUnavailable
                }
                let range = ResourceByteRange(
                    lowerBound: 0,
                    upperBound: signaturePrefixByteLimit - 1
                )
                let snapshotItem = try snapshotItem(for: item, metadata: metadata)
                let data = try await registry.readData(
                    sourceID: snapshotItem.sourceID,
                    for: snapshotItem,
                    range: range
                )
                try Task.checkCancellation()
                guard Int64(data.count) <= signaturePrefixByteLimit else {
                    throw ResourceSourceError.responseTooLarge
                }
                if metadata.byteSize != nil,
                   Int64(data.count) != signaturePrefixByteLimit {
                    throw ResourceSourceError.invalidResponse
                }
                return .data(data)

            case .cache(let cacheCoordinator, _):
                guard let byteSize = metadata.byteSize,
                      let key = ResourceCacheKey(
                          identity: item.id,
                          revision: metadata.revision,
                          variant: .content
                      ),
                      let data = try await cacheCoordinator.prefixData(
                          for: key,
                          expectedByteCount: byteSize,
                          maximumBytes: signaturePrefixByteLimit
                      ) else {
                    throw ResourceSourceError.capabilityUnavailable
                }
                return .data(data)
            }
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
