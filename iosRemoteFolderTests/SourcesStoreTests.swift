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

    init(source: ResourceSource, items: [ResourceItem] = []) {
        self.source = source
        self.items = items
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectCount
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

    func listResources() async throws -> [ResourceItem] { items }

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

    private var isReleasedSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }
}

@Suite("来源连接状态仓库") @MainActor
struct SourcesStoreTests {
    @Test("连接成功进入就绪并回写资源数量")
    func connectSucceeds() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source, items: [sampleItem(source.id), sampleItem(source.id)])
        let store = SourcesStore(sources: [source]) { _ in stub }

        store.connect(source.id)
        #expect(store.entries.first?.state == .connecting)

        stub.release()
        try await waitUntil { store.entries.first?.state == .ready }
        #expect(store.entries.first?.source.status == .connected)
        #expect(store.entries.first?.source.itemCountDescription == "2 个资源")
    }

    @Test("连接失败保留可行动错误")
    func connectFailsWithError() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source)
        stub.setFailure(.networkUnavailable)
        let store = SourcesStore(sources: [source]) { _ in stub }

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
        let store = SourcesStore(sources: [source]) { _ in stub }

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
    func sourceWithoutAdapterStaysDisconnected() async {
        let source = makeSource(kind: .alist)
        let store = SourcesStore(sources: [source]) { _ in nil }
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
        let store = SourcesStore(sources: [sourceA, sourceB, sourceC]) { source in
            switch source.id {
            case sourceA.id: return stubA
            case sourceB.id: return stubB
            default: return nil
            }
        }

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
        let store = SourcesStore(sources: [source]) { _ in stub }

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
        let store = SourcesStore(sources: [source]) { _ in stub }

        store.connect(source.id)
        store.connect(source.id)
        stub.release()
        try await waitUntil { store.entries.first?.state == .ready }
        // 状态最终稳定在就绪，而不是被取消任务覆写。
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.entries.first?.state == .ready)
    }

    // MARK: - Helpers

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

    private func sampleItem(_ sourceID: UUID) -> ResourceItem {
        ResourceItem(
            name: "示例.txt",
            kind: .text,
            sourceID: sourceID,
            path: "/示例.txt",
            sizeDescription: "",
            modifiedDescription: "",
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
