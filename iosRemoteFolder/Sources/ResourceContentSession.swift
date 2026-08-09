import Foundation

/// 受控的资源内容读取会话。
///
/// 会话只暴露 typed metadata、带显式预算的读取和幂等终态控制；adapter、
/// ResourceItem、引用、请求头和 URL 只保留在 actor 私有实现中。
actor ResourceContentSession {
    private enum Operation: Sendable {
        case metadata
        case full(maximumBytes: Int64)
        case range(ResourceByteRange, maximumBytes: Int64)
    }

    private enum Outcome: Sendable {
        case metadata(ResourceMetadata)
        case data(Data)
        case failure(ResourceSourceError)
    }

    private let registry: SourceRegistry
    private let item: ResourceItem
    private var isTerminated = false
    private var activeOperations: [UUID: Task<Outcome, Never>] = [:]

    init(registry: SourceRegistry, item: ResourceItem) {
        self.registry = registry
        self.item = item
    }

    /// 获取该位置的最新 typed metadata。
    func fetchMetadata() async throws -> ResourceMetadata {
        let outcome = try await perform(.metadata)
        if case .metadata(let metadata) = outcome {
            return metadata
        }
        if case .failure(let error) = outcome { throw error }
        throw ResourceSourceError.invalidResponse
    }

    /// 在获取最新 metadata 并确认完整大小不超过预算后读取完整内容。
    func readData(maximumBytes: Int64) async throws -> Data {
        guard maximumBytes > 0 else { throw ResourceSourceError.invalidReference }
        let outcome = try await perform(.full(maximumBytes: maximumBytes))
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

        let outcome = try await perform(.range(range, maximumBytes: maximumBytes))
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
        let registry = self.registry
        let item = self.item
        let task = Task<Outcome, Never> {
            do {
                try Task.checkCancellation()
                let outcome = try await Self.execute(
                    operation,
                    registry: registry,
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
        registry: SourceRegistry,
        item: ResourceItem
    ) async throws -> Outcome {
        switch operation {
        case .metadata:
            let metadata = try await registry.fetchMetadata(
                sourceID: item.sourceID,
                for: item
            )
            return .metadata(metadata)

        case .full(let maximumBytes):
            let metadata = try await registry.fetchMetadata(
                sourceID: item.sourceID,
                for: item
            )
            try Task.checkCancellation()
            guard !metadata.isDirectory else {
                throw ResourceSourceError.capabilityUnavailable
            }
            guard let byteSize = metadata.byteSize,
                  byteSize >= 0,
                  byteSize <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }

            let data = try await registry.readData(
                sourceID: item.sourceID,
                for: item,
                range: nil
            )
            try Task.checkCancellation()
            guard Int64(data.count) <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }
            if Int64(data.count) > byteSize {
                throw ResourceSourceError.invalidResponse
            }
            return .data(data)

        case .range(let range, let maximumBytes):
            let metadata = try await registry.fetchMetadata(
                sourceID: item.sourceID,
                for: item
            )
            try Task.checkCancellation()
            guard !metadata.isDirectory, metadata.acceptsRanges else {
                throw ResourceSourceError.capabilityUnavailable
            }
            guard item.capabilities.contains(.rangeRead) else {
                throw ResourceSourceError.capabilityUnavailable
            }
            guard let requestedLength = checkedLength(of: range) else {
                throw ResourceSourceError.invalidReference
            }

            let data = try await registry.readData(
                sourceID: item.sourceID,
                for: item,
                range: range
            )
            try Task.checkCancellation()
            guard Int64(data.count) <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }
            guard Int64(data.count) <= requestedLength else {
                throw ResourceSourceError.invalidResponse
            }
            return .data(data)
        }
    }

    private static func checkedLength(of range: ResourceByteRange) -> Int64? {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            return nil
        }
        let (difference, differenceOverflow) = range.upperBound.subtractingReportingOverflow(
            range.lowerBound
        )
        let (length, lengthOverflow) = difference.addingReportingOverflow(1)
        guard !differenceOverflow, !lengthOverflow, length > 0 else {
            return nil
        }
        return length
    }

}
