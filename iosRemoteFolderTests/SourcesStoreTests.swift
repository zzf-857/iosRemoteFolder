import Foundation
import AVFoundation
import PDFKit
import Testing
import UIKit
import UniformTypeIdentifiers

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

@Suite("查看器解析与文本载荷")
struct ViewerResolutionTests {
    @Test("TXT 解析使用 typed 文本证据和显式预算")
    func resolvesTextContent() {
        let item = makeItem(path: "/notes/readme.txt", kind: .unknown)
        let metadata = ResourceMetadata(
            mimeType: "text/plain",
            typeIdentifier: UTType.plainText.identifier
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .textReader)
        #expect(resolution.preparation == .text(maximumBytes: 10 * 1024 * 1024))
        #expect(resolution.fallbackDescription == nil)
    }

    @Test("PDF 解析保留 PDFKit 预算")
    func resolvesPDFContent() {
        let item = makeItem(path: "/manual.pdf", kind: .unknown)
        let metadata = ResourceMetadata(
            mimeType: "application/pdf",
            typeIdentifier: UTType.pdf.identifier
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .pdfReader)
        #expect(resolution.preparation == .pdf(maximumBytes: 50 * 1024 * 1024))
    }

    @Test("图片解析使用显式预算并拒绝非图片字节")
    func resolvesImageContent() {
        let item = makeItem(path: "/photo.jpg", kind: .unknown)
        let metadata = ResourceMetadata(
            mimeType: "image/jpeg",
            typeIdentifier: UTType.jpeg.identifier
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .imageViewer)
        #expect(resolution.preparation == .image(maximumBytes: 50 * 1024 * 1024))
        let imageData = UIImage(systemName: "photo")!.pngData()!
        #expect(ViewerContentDecoder.isValidImageData(imageData))
        #expect(!ViewerContentDecoder.isValidImageData(Data("not an image".utf8)))
    }

    @Test("音乐解析使用显式预算")
    func resolvesAudioContent() {
        let item = makeItem(path: "/demo.wav", kind: .audio)
        let metadata = ResourceMetadata(
            mimeType: "audio/wav",
            typeIdentifier: "com.microsoft.waveform-audio"
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .musicPlayer)
        #expect(resolution.preparation == .audio(maximumBytes: 50 * 1024 * 1024))
    }

    @Test("视频解析使用显式预算")
    func resolvesVideoContent() {
        let item = makeItem(path: "/demo.mp4", kind: .video)
        let metadata = ResourceMetadata(
            mimeType: "video/mp4",
            typeIdentifier: UTType.mpeg4Movie.identifier
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .videoPlayer)
        #expect(resolution.preparation == .video(maximumBytes: 50 * 1024 * 1024))
    }

    @Test("Markdown 与通用文本证据兼容，但真正冲突降级")
    func resolvesMarkdownAndRejectsConflict() {
        let markdown = makeItem(path: "/notes/readme.md", kind: .unknown)
        let markdownResolution = ViewerRegistry.resolve(
            resource: markdown,
            metadata: ResourceMetadata(
                mimeType: "text/markdown",
                typeIdentifier: UTType.plainText.identifier
            )
        )
        #expect(markdownResolution.kind == .markdownReader)
        #expect(markdownResolution.preparation == .text(maximumBytes: 10 * 1024 * 1024))

        let conflict = makeItem(path: "/notes/readme.pdf", kind: .pdf)
        let conflictResolution = ViewerRegistry.resolve(
            resource: conflict,
            metadata: ResourceMetadata(
                mimeType: "text/plain",
                typeIdentifier: UTType.plainText.identifier
            )
        )
        #expect(conflictResolution.kind == .systemPreview)
        #expect(conflictResolution.fallbackDescription?.contains("扩展名") == true)
    }

    @Test("文本解码优先 UTF-8 并支持 UTF-16")
    func decodesTextPayloads() {
        #expect(ViewerContentDecoder.decodeText(Data("你好".utf8)) == "你好")
        let utf16 = "hello".data(using: .utf16LittleEndian)!
        #expect(ViewerContentDecoder.decodeText(utf16) == "hello")
    }

    private func makeItem(path: String, kind: ResourceKind) -> ResourceItem {
        ResourceItem(
            sourceID: UUID(),
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .blue
        )
    }
}

@Suite("最近资源记录")
@MainActor
struct RecentResourceStoreTests {
    @Test("按稳定身份去重并在重启后恢复最新 metadata")
    func persistsAndDeduplicates() {
        let suiteName = "iosRemoteFolder.recent-resource-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceID = UUID()
        let path = ResourcePath(rawValue: "/notes/guide.txt")!
        let first = ResourceItem(
            sourceID: sourceID,
            logicalPath: path,
            name: "guide.txt",
            kind: .text,
            metadata: ResourceMetadata(byteSize: 10, mimeType: "text/plain"),
            capabilities: [.read],
            accent: .blue
        )
        let updated = ResourceItem(
            sourceID: sourceID,
            logicalPath: path,
            name: "guide.txt",
            kind: .text,
            metadata: ResourceMetadata(byteSize: 99, mimeType: "text/plain"),
            capabilities: [.read],
            accent: .blue
        )

        let store = RecentResourceStore(defaults: defaults)
        store.record(first)
        store.record(updated)

        #expect(store.items.count == 1)
        #expect(store.items.first?.id == first.id)
        #expect(store.items.first?.metadata.byteSize == 99)

        let restored = RecentResourceStore(defaults: defaults)
        #expect(restored.items.count == 1)
        #expect(restored.items.first?.id == first.id)
        #expect(restored.items.first?.metadata.byteSize == 99)
        let payloadText = String(
            data: defaults.data(forKey: "recentResources.v1")!,
            encoding: .utf8
        )!
        #expect(!payloadText.contains("http://"))
        #expect(!payloadText.contains("headers"))
    }

    @Test("限制数量并在来源移除后过滤记录")
    func limitsAndPrunesBySource() {
        let suiteName = "iosRemoteFolder.recent-resource-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceID = UUID()
        let store = RecentResourceStore(defaults: defaults)
        for index in 0..<21 {
            let path = ResourcePath(rawValue: "/recent-\(index).txt")!
            store.record(
                ResourceItem(
                    sourceID: sourceID,
                    logicalPath: path,
                    name: "recent-\(index).txt",
                    kind: .text,
                    metadata: ResourceMetadata(byteSize: Int64(index)),
                    capabilities: [.read],
                    accent: .blue
                )
            )
        }

        #expect(store.items.count == 20)
        #expect(store.items.first?.path == "/recent-20.txt")
        #expect(store.items.last?.path == "/recent-1.txt")

        store.retain(sourceIDs: [UUID()])
        #expect(store.items.isEmpty)
        #expect(RecentResourceStore(defaults: defaults).items.isEmpty)
    }
}

@Suite("媒体播放位置")
@MainActor
struct ResourceProgressStoreTests {
    @Test("已知 revision 的位置可持久化并恢复")
    func persistsAndRestoresKnownRevision() {
        let suiteName = "iosRemoteFolder.resource-progress-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceID = UUID()
        let resource = makeResource(sourceID: sourceID, path: "/media/demo.mp3")
        let revision = ResourceRevision.modifiedAndSize(
            modifiedAt: Date(timeIntervalSince1970: 1_786_003_200),
            byteSize: 4096
        )
        let metadata = ResourceMetadata(
            byteSize: 4096,
            mimeType: "audio/mpeg",
            revision: revision
        )

        let store = ResourceProgressStore(defaults: defaults)
        store.record(.seconds(12.5), for: resource, metadata: metadata)

        #expect(store.count == 1)
        #expect(store.position(for: resource, metadata: metadata) == .seconds(12.5))
        #expect(ResourceProgressStore(defaults: defaults).position(for: resource, metadata: metadata) == .seconds(12.5))

        let payloadText = String(
            data: defaults.data(forKey: "resourceResume.v1")!,
            encoding: .utf8
        )!
        #expect(!payloadText.contains("http://"))
        #expect(!payloadText.contains("headers"))
        #expect(!payloadText.contains("Cookie"))
    }

    @Test("unknown 或变化的 revision 不恢复旧位置")
    func rejectsUnknownAndChangedRevision() {
        let suiteName = "iosRemoteFolder.resource-progress-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resource = makeResource(sourceID: UUID(), path: "/media/demo.mp4", kind: .video)
        let firstMetadata = ResourceMetadata(
            byteSize: 2048,
            revision: .etag("\"first\"")
        )
        let changedMetadata = ResourceMetadata(
            byteSize: 2048,
            revision: .etag("\"changed\"")
        )
        let unknownMetadata = ResourceMetadata(byteSize: 2048, revision: .unknown)
        let store = ResourceProgressStore(defaults: defaults)

        store.record(.seconds(4), for: resource, metadata: firstMetadata)
        #expect(store.position(for: resource, metadata: changedMetadata) == nil)
        #expect(store.count == 0)

        store.record(.seconds(4), for: resource, metadata: firstMetadata)
        #expect(store.position(for: resource, metadata: unknownMetadata) == nil)
        #expect(store.count == 0)

        store.record(.seconds(-1), for: resource, metadata: firstMetadata)
        store.record(.seconds(.nan), for: resource, metadata: firstMetadata)
        store.record(.seconds(.infinity), for: resource, metadata: firstMetadata)
        #expect(store.count == 0)
    }

    @Test("来源移除后清理位置")
    func prunesRemovedSources() {
        let suiteName = "iosRemoteFolder.resource-progress-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let retainedSource = UUID()
        let removedSource = UUID()
        let metadata = ResourceMetadata(
            byteSize: 1024,
            revision: .serverVersion("v1")
        )
        let store = ResourceProgressStore(defaults: defaults)
        store.record(
            .seconds(1),
            for: makeResource(sourceID: retainedSource, path: "/keep.mp3"),
            metadata: metadata
        )
        store.record(
            .seconds(2),
            for: makeResource(sourceID: removedSource, path: "/remove.mp4", kind: .video),
            metadata: metadata
        )

        store.retain(sourceIDs: [retainedSource])
        #expect(store.count == 1)
    }

    private func makeResource(
        sourceID: UUID,
        path: String,
        kind: ResourceKind = .audio
    ) -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(byteSize: 1),
            capabilities: [.read],
            accent: .blue
        )
    }
}

@Suite("文档阅读位置")
@MainActor
struct ResourceReadingStoreTests {
    @Test("PDF 页码与文本比例按身份和 revision 持久化恢复")
    func persistsAndRestoresDocumentPositions() {
        let suiteName = "iosRemoteFolder.resource-reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceID = UUID()
        let revision = ResourceRevision.modifiedAndSize(
            modifiedAt: Date(timeIntervalSince1970: 1_786_003_200),
            byteSize: 4096
        )
        let metadata = ResourceMetadata(byteSize: 4096, revision: revision)
        let pdf = makeResource(sourceID: sourceID, path: "/docs/guide.pdf", kind: .pdf)
        let text = makeResource(sourceID: sourceID, path: "/docs/notes.txt", kind: .text)
        let store = ResourceReadingStore(defaults: defaults)

        store.record(.pdf(pageIndex: 3), for: pdf, metadata: metadata)
        store.record(.text(fraction: 0.65), for: text, metadata: metadata)

        #expect(store.position(for: pdf, metadata: metadata) == .pdf(pageIndex: 3))
        #expect(store.position(for: text, metadata: metadata) == .text(fraction: 0.65))

        let restored = ResourceReadingStore(defaults: defaults)
        #expect(restored.position(for: pdf, metadata: metadata) == .pdf(pageIndex: 3))
        #expect(restored.position(for: text, metadata: metadata) == .text(fraction: 0.65))

        let payloadText = String(
            data: defaults.data(forKey: "resourceReading.v1")!,
            encoding: .utf8
        )!
        #expect(!payloadText.contains("http://"))
        #expect(!payloadText.contains("headers"))
        #expect(!payloadText.contains("Cookie"))
    }

    @Test("unknown 或变化的 revision 清理旧文档位置")
    func rejectsUnknownAndChangedRevision() {
        let suiteName = "iosRemoteFolder.resource-reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resource = makeResource(sourceID: UUID(), path: "/docs/notes.md", kind: .markdown)
        let first = ResourceMetadata(revision: .etag("\"first\""))
        let changed = ResourceMetadata(revision: .etag("\"changed\""))
        let unknown = ResourceMetadata(revision: .unknown)
        let store = ResourceReadingStore(defaults: defaults)

        store.record(.text(fraction: 0.4), for: resource, metadata: first)
        #expect(store.position(for: resource, metadata: changed) == nil)
        #expect(store.count == 0)

        store.record(.text(fraction: 0.4), for: resource, metadata: first)
        #expect(store.position(for: resource, metadata: unknown) == nil)
        #expect(store.count == 0)
    }

    @Test("非法位置、类型冲突和移除来源不会留下记录")
    func validatesPositionsAndPrunesSources() {
        let suiteName = "iosRemoteFolder.resource-reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let retainedSource = UUID()
        let removedSource = UUID()
        let metadata = ResourceMetadata(revision: .serverVersion("v1"))
        let pdf = makeResource(sourceID: retainedSource, path: "/docs/guide.pdf", kind: .pdf)
        let text = makeResource(sourceID: removedSource, path: "/docs/notes.txt", kind: .text)
        let store = ResourceReadingStore(defaults: defaults)

        store.record(.pdf(pageIndex: -1), for: pdf, metadata: metadata)
        store.record(.text(fraction: .nan), for: text, metadata: metadata)
        store.record(.pdf(pageIndex: 2), for: text, metadata: metadata)
        #expect(store.count == 0)

        store.record(.pdf(pageIndex: 2), for: pdf, metadata: metadata)
        store.record(.text(fraction: 0.2), for: text, metadata: metadata)
        #expect(store.count == 2)

        store.retain(sourceIDs: [retainedSource])
        #expect(store.count == 1)
        #expect(store.position(for: pdf, metadata: metadata) == .pdf(pageIndex: 2))
        #expect(store.position(for: text, metadata: metadata) == nil)
    }

    private func makeResource(
        sourceID: UUID,
        path: String,
        kind: ResourceKind
    ) -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .blue
        )
    }
}

@Suite("演示来源文档内容")
struct SampleSourceContentTests {
    @Test("演示来源经内容会话返回真实 Markdown 与 PDF 字节")
    func readsDemoDocumentsThroughSession() async throws {
        let markdownSource = SampleData.sources.first { $0.id == SampleData.workSourceID }!
        let markdownItem = SampleData.resources.first { $0.path == "/产品/路线图.md" }!
        let markdownAdapter = SampleSourceAdapter(source: markdownSource)
        let markdownRegistry = try SourceRegistry(
            sources: [markdownSource],
            adapters: [markdownAdapter]
        )
        let markdownSession = try await ResourceAccessService(registry: markdownRegistry)
            .makeSession(for: markdownItem)
        let markdownData = try await markdownSession.readData(maximumBytes: 10 * 1024 * 1024)
        #expect(String(decoding: markdownData, as: UTF8.self).contains("产品路线图"))

        let pdfSource = SampleData.sources.first { $0.id == SampleData.personalSourceID }!
        let pdfItem = SampleData.resources.first { $0.path.hasSuffix("设计系统与组件规范.pdf") }!
        let pdfAdapter = SampleSourceAdapter(source: pdfSource)
        let pdfRegistry = try SourceRegistry(sources: [pdfSource], adapters: [pdfAdapter])
        let pdfSession = try await ResourceAccessService(registry: pdfRegistry)
            .makeSession(for: pdfItem)
        let pdfData = try await pdfSession.readData(maximumBytes: 50 * 1024 * 1024)
        #expect(pdfData.starts(with: Data("%PDF-1.4".utf8)))
        #expect(PDFDocument(data: pdfData) != nil)
    }

    @Test("演示来源经内容会话返回可解码图片字节")
    func readsDemoImageThroughSession() async throws {
        let imageSource = SampleData.sources.first { $0.id == SampleData.workSourceID }!
        let imageItem = SampleData.resources.first { $0.path == "/产品/路线图封面.png" }!
        let adapter = SampleSourceAdapter(source: imageSource)
        let registry = try SourceRegistry(sources: [imageSource], adapters: [adapter])
        let session = try await ResourceAccessService(registry: registry)
            .makeSession(for: imageItem)
        let imageData = try await session.readData(maximumBytes: 50 * 1024 * 1024)

        #expect(UIImage(data: imageData) != nil)
    }

    @Test("演示来源经内容会话返回可播放音频字节")
    func readsDemoAudioThroughSession() async throws {
        let audioSource = SampleData.sources.first { $0.id == SampleData.workSourceID }!
        let audioItem = SampleData.resources.first { $0.path == "/产品/路线图演示.wav" }!
        let adapter = SampleSourceAdapter(source: audioSource)
        let registry = try SourceRegistry(sources: [audioSource], adapters: [adapter])
        let session = try await ResourceAccessService(registry: registry)
            .makeSession(for: audioItem)
        let audioData = try await session.readData(maximumBytes: 50 * 1024 * 1024)

        #expect(ViewerContentDecoder.isValidAudioData(audioData))
        #expect((try? AVAudioPlayer(data: audioData)) != nil)
    }

    @Test("演示来源经内容会话返回可加载视频字节")
    func readsDemoVideoThroughSession() async throws {
        let videoSource = SampleData.sources.first { $0.id == SampleData.workSourceID }!
        let videoItem = SampleData.resources.first { $0.path == "/产品/路线图演示.mp4" }!
        let adapter = SampleSourceAdapter(source: videoSource)
        let registry = try SourceRegistry(sources: [videoSource], adapters: [adapter])
        let session = try await ResourceAccessService(registry: registry)
            .makeSession(for: videoItem)
        let videoData = try await session.readData(maximumBytes: 50 * 1024 * 1024)

        #expect(videoData.count == 2_268)
        #expect(await ViewerContentDecoder.isValidVideoData(videoData))
    }
}
