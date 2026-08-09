import Foundation
import Testing

@testable import iosRemoteFolder

/// 可控行为的桩 adapter：连接会等待测试释放，可注入失败、统计调用次数。
private final class StubSourceAdapter: ResourceSourceAdapter, @unchecked Sendable {
    let source: ResourceSource
    let items: [ResourceItem]

    private let lock = NSLock()
    private var released = false
    private var failure: ResourceSourceError?
    private var connectCount = 0
    private var requestedListPaths: [ResourcePath] = []

    init(source: ResourceSource, items: [ResourceItem] = []) {
        self.source = source
        self.items = items
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectCount
    }

    var listPaths: [ResourcePath] {
        lock.lock()
        defer { lock.unlock() }
        return requestedListPaths
    }

    func setFailure(_ error: ResourceSourceError?) {
        lock.lock()
        defer { lock.unlock() }
        failure = error
    }

    /// 释放所有等待中的 connect，使连接任务继续执行。
    func release() {
        lock.lock()
        defer { lock.unlock() }
        released = true
    }

    func connect() async throws {
        let currentFailure = beginConnect()
        while true {
            if isReleasedSnapshot { break }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        if let currentFailure {
            throw currentFailure
        }
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        recordListPath(path)
        return items
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        throw ResourceSourceError.capabilityUnavailable
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        throw ResourceSourceError.capabilityUnavailable
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        throw ResourceSourceError.capabilityUnavailable
    }

    // MARK: - 同步锁辅助（NSLock 不能直接出现在 async 上下文）

    private func beginConnect() -> ResourceSourceError? {
        lock.lock()
        defer { lock.unlock() }
        connectCount += 1
        return failure
    }

    private func recordListPath(_ path: ResourcePath) {
        lock.lock()
        defer { lock.unlock() }
        requestedListPaths.append(path)
    }

    private var isReleasedSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }
}

@Suite("来源连接状态仓库") @MainActor
struct SourcesStoreTests {
    @Test("无参数列举由协议扩展单向转发根目录")
    func noArgumentListingForwardsToRoot() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source)

        _ = try await stub.listResources()

        #expect(stub.listPaths == [.root])
    }

    @Test("连接成功进入就绪并回写资源数量")
    func connectSucceeds() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(
            source: source,
            items: [
                sampleItem(source.id, path: "/first.txt"),
                sampleItem(source.id, path: "/second.txt"),
            ]
        )
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connect(source.id)
        #expect(store.entries.first?.state == .connecting)

        stub.release()
        try await waitUntil { store.entries.first?.state == .ready }
        #expect(store.entries.first?.source.status == .connected)
        #expect(store.entries.first?.source.itemCountDescription == "2 个资源")
        #expect(stub.listPaths == [.root])
    }

    @Test("连接失败保留可行动错误")
    func connectFailsWithError() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source)
        stub.setFailure(.networkUnavailable)
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connect(source.id)
        stub.release()
        try await waitUntil { store.entries.first?.state == .failed(.networkUnavailable) }
        #expect(store.entries.first?.source.status == .needsAttention)
    }

    @Test("失败后重试可以成功")
    func retryAfterFailure() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source, items: [sampleItem(source.id)])
        stub.setFailure(.timedOut)
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connect(source.id)
        stub.release()
        try await waitUntil { store.entries.first?.state == .failed(.timedOut) }

        stub.setFailure(nil)
        store.retry(source.id)
        try await waitUntil { store.entries.first?.state == .ready }
        #expect(stub.calls == 2)
        #expect(store.entries.first?.source.itemCountDescription == "1 个资源")
    }

    @Test("没有适配器的来源保持未连接")
    func sourceWithoutAdapterStaysDisconnected() async throws {
        let source = makeSource(kind: .alist)
        let store = try makeStore(sources: [source], adapters: [])
        store.connectAll()
        #expect(store.entries.first?.state == .disconnected)
        #expect(store.entries.first?.hasAdapter == false)
    }

    @Test("connectAll 只连接未连接且有适配器的来源")
    func connectAllScope() async throws {
        let sourceA = makeSource()
        let sourceB = makeSource()
        let sourceC = makeSource(kind: .webdav)
        let stubA = StubSourceAdapter(source: sourceA)
        let stubB = StubSourceAdapter(source: sourceB)
        let store = try makeStore(
            sources: [sourceA, sourceB, sourceC],
            adapters: [stubA, stubB]
        )

        store.connectAll()
        #expect(entry(of: sourceA, in: store)?.state == .connecting)
        #expect(entry(of: sourceB, in: store)?.state == .connecting)
        #expect(entry(of: sourceC, in: store)?.state == .disconnected)

        stubA.release()
        stubB.release()
        try await waitUntil {
            entry(of: sourceA, in: store)?.state == .ready
                && entry(of: sourceB, in: store)?.state == .ready
        }
    }

    @Test("connectAll 不重复连接已就绪来源")
    func connectAllSkipsReady() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source)
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connectAll()
        stub.release()
        try await waitUntil { store.entries.first?.state == .ready }

        store.connectAll()
        #expect(stub.calls == 1)
        #expect(store.entries.first?.state == .ready)
    }

    @Test("重复连接会替换上一次未完成任务")
    func duplicateConnectReplacesTask() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source, items: [sampleItem(source.id)])
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connect(source.id)
        store.connect(source.id)
        stub.release()
        try await waitUntil { store.entries.first?.state == .ready }
        // 状态最终稳定在就绪，而不是被取消任务覆写。
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.entries.first?.state == .ready)
    }

    // MARK: - Helpers

    private func makeStore(
        sources: [ResourceSource],
        adapters: [any ResourceSourceAdapter]
    ) throws -> SourcesStore {
        let registry = try SourceRegistry(sources: sources, adapters: adapters)
        return SourcesStore(registry: registry)
    }

    private func makeSource(kind: ResourceSource.SourceKind = .local) -> ResourceSource {
        ResourceSource(
            id: UUID(),
            name: "测试来源",
            kind: kind,
            endpoint: "test://fixture",
            status: .disconnected,
            itemCountDescription: ""
        )
    }

    private func sampleItem(_ sourceID: UUID, path: String = "/示例.txt") -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: .text,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .teal
        )
    }

    private func entry(of source: ResourceSource, in store: SourcesStore) -> SourcesStore.Entry? {
        store.entries.first { $0.id == source.id }
    }
}

/// 在超时前轮询等待条件成立；超时记录测试失败。
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("等待条件超时")
}

/// 内容会话专用桩：可观察 metadata/read 次数，并可在读取前挂起以验证取消。
private final class ContentStubAdapter: ResourceSourceAdapter, @unchecked Sendable {
    let source: ResourceSource
    let metadata: ResourceMetadata
    let content: Data
    let delay: Duration?
    let rangeResponse: Data?

    private let lock = NSLock()
    private var metadataCallCount = 0
    private var readCallCount = 0

    init(
        source: ResourceSource,
        metadata: ResourceMetadata,
        content: Data,
        delay: Duration? = nil,
        rangeResponse: Data? = nil
    ) {
        self.source = source
        self.metadata = metadata
        self.content = content
        self.delay = delay
        self.rangeResponse = rangeResponse
    }

    var metadataCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return metadataCallCount
    }

    var readCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCallCount
    }

    func connect() async throws {}

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        []
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        throw ResourceSourceError.capabilityUnavailable
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        incrementMetadataCalls()
        return metadata
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        incrementReadCalls()
        if let delay {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        guard let range else { return content }
        if let rangeResponse { return rangeResponse }
        guard range.lowerBound < Int64(content.count) else { return Data() }
        let upperBound = min(range.upperBound, Int64(content.count - 1))
        let lowerIndex = Int(range.lowerBound)
        let upperIndex = Int(upperBound) + 1
        return content.subdata(
            in: lowerIndex..<upperIndex
        )
    }

    private func incrementMetadataCalls() {
        lock.lock()
        metadataCallCount += 1
        lock.unlock()
    }

    private func incrementReadCalls() {
        lock.lock()
        readCallCount += 1
        lock.unlock()
    }
}

@Suite("统一来源注册与内容会话")
struct ResourceAccessServiceTests {
    @Test("registry 拒绝重复来源、未注册 adapter 和重复 adapter")
    func registryRejectsDuplicateConfiguration() {
        let source = makeSource()
        let otherSource = makeSource()
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(),
            content: Data()
        )

        #expect(throws: SourceRegistryError.duplicateSourceID(source.id)) {
            _ = try SourceRegistry(sources: [source, source], adapters: [])
        }
        #expect(throws: SourceRegistryError.adapterSourceNotRegistered(otherSource.id)) {
            _ = try SourceRegistry(sources: [source], adapters: [
                ContentStubAdapter(
                    source: otherSource,
                    metadata: ResourceMetadata(),
                    content: Data()
                )
            ])
        }
        #expect(throws: SourceRegistryError.duplicateAdapterSourceID(source.id)) {
            _ = try SourceRegistry(sources: [source], adapters: [adapter, adapter])
        }
    }

    @Test("完整读取先取最新 metadata，并拒绝未知或超预算大小")
    func fullReadRequiresKnownBudget() async throws {
        let source = makeSource()
        let content = Data("hello".utf8)
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(byteSize: Int64(content.count)),
            content: content
        )
        let session = try await makeService(source: source, adapter: adapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))

        let result = try await session.readData(maximumBytes: 5)
        #expect(result == content)
        #expect(adapter.metadataCalls == 2)
        #expect(adapter.readCalls == 1)

        let tooSmall = try await makeService(
            source: source,
            adapter: ContentStubAdapter(
                source: source,
                metadata: ResourceMetadata(byteSize: Int64(content.count)),
                content: content
            )
        ).makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            _ = try await tooSmall.readData(maximumBytes: 4)
        }

        let unknownAdapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(),
            content: content
        )
        let unknown = try await makeService(source: source, adapter: unknownAdapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            _ = try await unknown.readData(maximumBytes: 5)
        }
        #expect(unknownAdapter.readCalls == 0)
    }

    @Test("区间读取同时校验 capability、metadata Range 和请求预算")
    func rangeReadChecksCapabilitiesAndBudget() async throws {
        let source = makeSource()
        let content = Data("0123456789".utf8)
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(
                byteSize: Int64(content.count),
                acceptsRanges: true
            ),
            content: content
        )
        let service = try makeService(source: source, adapter: adapter)
        let noRange = try await service.makeSession(
            for: makeItem(sourceID: source.id, capabilities: [.read])
        )
        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            _ = try await noRange.readData(
                range: ResourceByteRange(lowerBound: 0, upperBound: 1),
                maximumBytes: 2
            )
        }
        #expect(adapter.readCalls == 0)

        let tooLarge = try await service.makeSession(
            for: makeItem(sourceID: source.id, capabilities: [.read, .rangeRead])
        )
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            _ = try await tooLarge.readData(
                range: ResourceByteRange(lowerBound: 0, upperBound: 2),
                maximumBytes: 2
            )
        }

        let noMetadataRangeAdapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(
                byteSize: Int64(content.count),
                acceptsRanges: false
            ),
            content: content
        )
        let noMetadataRange = try await makeService(
            source: source,
            adapter: noMetadataRangeAdapter
        ).makeSession(for: makeItem(sourceID: source.id, capabilities: [.read, .rangeRead]))
        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            _ = try await noMetadataRange.readData(
                range: ResourceByteRange(lowerBound: 0, upperBound: 1),
                maximumBytes: 2
            )
        }
        #expect(noMetadataRangeAdapter.readCalls == 0)
    }

    @Test("违约响应不交付，并且 close/cancel 是幂等终态")
    func responseValidationAndTerminalCancellation() async throws {
        let source = makeSource()
        let content = Data("0123456789".utf8)
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(
                byteSize: Int64(content.count),
                acceptsRanges: true
            ),
            content: content,
            rangeResponse: Data("overflow".utf8)
        )
        let session = try await makeService(source: source, adapter: adapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read, .rangeRead]))
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await session.readData(
                range: ResourceByteRange(lowerBound: 0, upperBound: 1),
                maximumBytes: 20
            )
        }

        await session.cancel()
        await session.close()
        await session.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await session.fetchMetadata()
        }
    }

    @Test("调用方取消会取消对应在途操作")
    func callerCancellationCancelsOperation() async throws {
        let source = makeSource()
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(byteSize: 5),
            content: Data("hello".utf8),
            delay: .seconds(10)
        )
        let session = try await makeService(source: source, adapter: adapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))
        let task = Task {
            try await session.readData(maximumBytes: 5)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await task.value
        }
    }

    private func makeService(
        source: ResourceSource,
        adapter: any ResourceSourceAdapter
    ) throws -> ResourceAccessService {
        let registry = try SourceRegistry(sources: [source], adapters: [adapter])
        return ResourceAccessService(registry: registry)
    }

    private func makeSource() -> ResourceSource {
        ResourceSource(
            id: UUID(),
            name: "会话测试来源",
            kind: .local,
            endpoint: "test://content",
            status: .disconnected,
            itemCountDescription: ""
        )
    }

    private func makeItem(
        sourceID: UUID,
        capabilities: ResourceCapability
    ) -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: "/content.txt")!,
            name: "content.txt",
            kind: .text,
            metadata: ResourceMetadata(),
            capabilities: capabilities,
            accent: .blue
        )
    }
}
