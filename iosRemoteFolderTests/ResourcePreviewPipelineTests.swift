import Foundation
import ImageIO
import PDFKit
import Testing

@testable import iosRemoteFolder

@Suite("统一资源预览管线", .serialized)
struct ResourcePreviewPipelineTests {
    @Test("演示图片 PDF 与 Markdown 生成有界真实预览")
    func rendersSampleArtifacts() async throws {
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let image = try await samplePreview(
            sourceID: SampleData.workSourceID,
            path: "/产品/路线图封面.png",
            cacheDirectory: cacheDirectory.appendingPathComponent("image", isDirectory: true)
        )
        guard case .encodedImage(let imageData, .png, let imageWidth, let imageHeight) = image else {
            Issue.record("图片应生成 PNG 预览")
            return
        }
        #expect(imageWidth > 0 && imageWidth <= 80)
        #expect(imageHeight > 0 && imageHeight <= 80)
        #expect(CGImageSourceCreateWithData(imageData as CFData, nil) != nil)

        let pdf = try await samplePreview(
            sourceID: SampleData.personalSourceID,
            path: "/知识库/设计/设计系统与组件规范.pdf",
            cacheDirectory: cacheDirectory.appendingPathComponent("pdf", isDirectory: true)
        )
        guard case .encodedImage(let pdfData, .png, let pdfWidth, let pdfHeight) = pdf else {
            Issue.record("PDF 应生成首页 PNG 预览")
            return
        }
        #expect(pdfWidth == 80)
        #expect(pdfHeight == 80)
        #expect(CGImageSourceCreateWithData(pdfData as CFData, nil) != nil)

        let markdown = try await samplePreview(
            sourceID: SampleData.workSourceID,
            path: "/产品/路线图.md",
            cacheDirectory: cacheDirectory.appendingPathComponent("markdown", isDirectory: true)
        )
        guard case .textExcerpt(let excerpt) = markdown else {
            Issue.record("Markdown 应生成文本摘要")
            return
        }
        #expect(excerpt.contains("产品路线图"))
        #expect(excerpt.count <= 180)
        #expect(!excerpt.contains("<script"))
    }

    @Test("相同请求合并且取消单个 waiter 不影响其余调用")
    func coalescesRequestsAndCancelsOnlyOneWaiter() async throws {
        let fixture = makeFixture(revision: .etag("v1"), readsReleased: false)
        let pipeline = fixture.pipeline
        let request = try makeRequest(item: fixture.item)

        let first = Task { try await pipeline.preview(for: request) }
        let second = Task { try await pipeline.preview(for: request) }
        #expect(try await waitUntil { await fixture.adapter.snapshot().readCalls == 1 })

        first.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            try await first.value
        }
        #expect(await fixture.adapter.snapshot().readCalls == 1)

        await fixture.adapter.releaseReads()
        #expect(try await second.value == .textExcerpt("预览正文"))
        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)
    }

    @Test("最后 waiter 取消会终止底层读取且后续请求重新生成")
    func lastWaiterCancellationStopsGeneration() async throws {
        let fixture = makeFixture(revision: .etag("v1"), readsReleased: false)
        let request = try makeRequest(item: fixture.item)

        let task = Task { try await fixture.pipeline.preview(for: request) }
        #expect(try await waitUntil { await fixture.adapter.snapshot().readCalls == 1 })
        task.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            try await task.value
        }
        #expect(try await waitUntil { await fixture.adapter.snapshot().activeReads == 0 })

        await fixture.adapter.releaseReads()
        #expect(try await fixture.pipeline.preview(for: request) == .textExcerpt("预览正文"))
        #expect(await fixture.adapter.snapshot().readCalls == 2)
    }

    @Test("来源失效立即恢复 waiter 且迟到结果不能重新发布")
    func sourceInvalidationCancelsAndPreventsLatePublication() async throws {
        let fixture = makeFixture(revision: .etag("v1"), readsReleased: false)
        let request = try makeRequest(item: fixture.item)

        let task = Task { try await fixture.pipeline.preview(for: request) }
        #expect(try await waitUntil { await fixture.adapter.snapshot().readCalls == 1 })
        await fixture.pipeline.remove(sourceID: fixture.source.id)
        await #expect(throws: ResourceSourceError.cancelled) {
            try await task.value
        }
        #expect(try await waitUntil { await fixture.adapter.snapshot().activeReads == 0 })

        await fixture.adapter.releaseReads()
        #expect(try await fixture.pipeline.preview(for: request) == .textExcerpt("预览正文"))
        #expect(await fixture.adapter.snapshot().readCalls == 2)
    }

    @Test("不同请求的底层生成并发不超过三")
    func limitsConcurrentGeneration() async throws {
        let fixture = makeFixture(revision: .etag("v1"), readsReleased: false)
        let items = try (0..<5).map { index in
            try makeItem(
                sourceID: fixture.source.id,
                path: "/并发/预览-\(index).txt",
                revision: .etag("v1")
            )
        }
        let requests = try items.map(makeRequest)
        let tasks = requests.map { request in
            Task { try await fixture.pipeline.preview(for: request) }
        }

        #expect(try await waitUntil { await fixture.adapter.snapshot().readCalls == 3 })
        let blockedSnapshot = await fixture.adapter.snapshot()
        #expect(blockedSnapshot.activeReads == 3)
        #expect(blockedSnapshot.maximumActiveReads == 3)

        await fixture.adapter.releaseReads()
        for task in tasks {
            #expect(try await task.value == .textExcerpt("预览正文"))
        }
        let completedSnapshot = await fixture.adapter.snapshot()
        #expect(completedSnapshot.readCalls == 5)
        #expect(completedSnapshot.maximumActiveReads == 3)
    }

    @Test("只有请求自身带已知 revision 才跨 pipeline 读取磁盘缓存")
    func persistsOnlyKnownRequestRevisions() async throws {
        let knownDirectory = try makeCacheDirectory()
        let unknownDirectory = try makeCacheDirectory()
        defer {
            try? FileManager.default.removeItem(at: knownDirectory)
            try? FileManager.default.removeItem(at: unknownDirectory)
        }

        let known = makeFixture(
            revision: .etag("v1"),
            readsReleased: true,
            cacheDirectory: knownDirectory
        )
        let knownRequest = try makeRequest(item: known.item)
        _ = try await known.pipeline.preview(for: knownRequest)
        let secondKnownPipeline = ResourcePreviewPipeline(
            accessService: known.accessService,
            cacheDirectory: knownDirectory
        )
        _ = try await secondKnownPipeline.preview(for: knownRequest)
        #expect(await known.adapter.snapshot().readCalls == 1)

        let unknown = makeFixture(
            revision: .unknown,
            resolvedRevision: .etag("resolved-v1"),
            readsReleased: true,
            cacheDirectory: unknownDirectory
        )
        let unknownRequest = try makeRequest(item: unknown.item)
        _ = try await unknown.pipeline.preview(for: unknownRequest)
        let secondUnknownPipeline = ResourcePreviewPipeline(
            accessService: unknown.accessService,
            cacheDirectory: unknownDirectory
        )
        _ = try await secondUnknownPipeline.preview(for: unknownRequest)
        #expect(await unknown.adapter.snapshot().readCalls == 2)
        let unknownDiskEntries = try FileManager.default.contentsOfDirectory(
            at: unknownDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(unknownDiskEntries.isEmpty)
    }

    @Test("不支持类型零读取且文本超预算不会下载正文")
    func rejectsUnsupportedAndOversizedResourcesBeforeRead() async throws {
        let unsupported = makeFixture(
            kind: .video,
            revision: .etag("video-v1"),
            readsReleased: true
        )
        let unsupportedRequest = try makeRequest(item: unsupported.item)
        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            try await unsupported.pipeline.preview(for: unsupportedRequest)
        }
        let unsupportedSnapshot = await unsupported.adapter.snapshot()
        #expect(unsupportedSnapshot.metadataCalls == 0)
        #expect(unsupportedSnapshot.readCalls == 0)

        let oversized = makeFixture(
            revision: .etag("large-v1"),
            resolvedByteSize: 256 * 1024 + 1,
            readsReleased: true
        )
        let oversizedRequest = try makeRequest(item: oversized.item)
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            try await oversized.pipeline.preview(for: oversizedRequest)
        }
        let oversizedSnapshot = await oversized.adapter.snapshot()
        #expect(oversizedSnapshot.metadataCalls == 1)
        #expect(oversizedSnapshot.readCalls == 0)
    }

    @Test("请求尺寸与 scale 规范化并设置像素上限")
    func normalizesRequestDimensions() throws {
        let sourceID = UUID()
        let item = try makeItem(sourceID: sourceID, path: "/图片.png", revision: .etag("v1"))
        let request = try #require(ResourcePreviewRequest(
            item: item,
            targetSize: CGSize(width: 900, height: 700),
            displayScale: 8
        ))

        #expect(request.targetSize == CGSize(width: 512, height: 512))
        #expect(request.displayScale == 4)
        #expect(request.pixelWidth == 2_048)
        #expect(request.pixelHeight == 2_048)
        #expect(ResourcePreviewRequest(
            item: item,
            targetSize: .zero,
            displayScale: 2
        ) == nil)
    }

    private func samplePreview(
        sourceID: UUID,
        path: String,
        cacheDirectory: URL
    ) async throws -> ResourcePreviewArtifact {
        let source = try #require(SampleData.sources.first { $0.id == sourceID })
        let item = try #require(SampleData.resources.first {
            $0.sourceID == sourceID && $0.path == path
        })
        let adapter = SampleSourceAdapter(source: source)
        let registry = try SourceRegistry(
            sources: [source],
            adapters: [adapter],
            transientRetryDelays: []
        )
        let pipeline = ResourcePreviewPipeline(
            accessService: ResourceAccessService(registry: registry),
            cacheDirectory: cacheDirectory
        )
        return try await pipeline.preview(for: try makeRequest(item: item))
    }

    private func makeFixture(
        kind: ResourceKind = .text,
        revision: ResourceRevision,
        resolvedRevision: ResourceRevision? = nil,
        resolvedByteSize: Int64? = nil,
        readsReleased: Bool,
        cacheDirectory: URL? = nil
    ) -> PreviewFixture {
        let source = ResourceSource(
            id: UUID(),
            name: "预览测试来源",
            kind: .local,
            endpoint: "test://preview",
            status: .connected,
            itemCountDescription: ""
        )
        let content = Data("预览正文".utf8)
        let metadata = ResourceMetadata(
            byteSize: resolvedByteSize ?? Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            mimeType: kind == .video ? "video/mp4" : "text/plain",
            typeIdentifier: kind == .video ? "public.mpeg-4" : "public.plain-text",
            revision: resolvedRevision ?? revision
        )
        let item = try! makeItem(
            sourceID: source.id,
            path: kind == .video ? "/测试.mp4" : "/测试.txt",
            kind: kind,
            byteSize: revision.isKnown ? metadata.byteSize : nil,
            revision: revision
        )
        let adapter = PreviewFixtureAdapter(
            source: source,
            metadata: metadata,
            content: content,
            readsReleased: readsReleased
        )
        let registry = try! SourceRegistry(
            sources: [source],
            adapters: [adapter],
            transientRetryDelays: []
        )
        let accessService = ResourceAccessService(registry: registry)
        let directory = cacheDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-preview-tests-\(UUID().uuidString)", isDirectory: true)
        return PreviewFixture(
            source: source,
            item: item,
            adapter: adapter,
            accessService: accessService,
            pipeline: ResourcePreviewPipeline(
                accessService: accessService,
                cacheDirectory: directory
            )
        )
    }

    private func makeRequest(item: ResourceItem) throws -> ResourcePreviewRequest {
        try #require(ResourcePreviewRequest(
            item: item,
            targetSize: CGSize(width: 40, height: 40),
            displayScale: 2
        ))
    }

    private func makeItem(
        sourceID: UUID,
        path: String,
        kind: ResourceKind = .text,
        byteSize: Int64? = nil,
        revision: ResourceRevision
    ) throws -> ResourceItem {
        let logicalPath = try #require(ResourcePath(rawValue: path))
        return ResourceItem(
            sourceID: sourceID,
            logicalPath: logicalPath,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(
                byteSize: byteSize,
                mimeType: kind == .video ? "video/mp4" : "text/plain",
                typeIdentifier: kind == .video ? "public.mpeg-4" : "public.plain-text",
                revision: revision
            ),
            capabilities: [.read],
            accent: .recommended(for: kind)
        )
    }

    private func makeCacheDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private struct PreviewFixture {
    let source: ResourceSource
    let item: ResourceItem
    let adapter: PreviewFixtureAdapter
    let accessService: ResourceAccessService
    let pipeline: ResourcePreviewPipeline
}

private actor PreviewFixtureAdapter: ResourceSourceAdapter {
    struct Snapshot: Sendable {
        let metadataCalls: Int
        let readCalls: Int
        let activeReads: Int
        let maximumActiveReads: Int
    }

    nonisolated let source: ResourceSource
    private let metadata: ResourceMetadata
    private let content: Data
    private var readsReleased: Bool
    private var metadataCalls = 0
    private var readCalls = 0
    private var activeReads = 0
    private var maximumActiveReads = 0

    init(
        source: ResourceSource,
        metadata: ResourceMetadata,
        content: Data,
        readsReleased: Bool
    ) {
        self.source = source
        self.metadata = metadata
        self.content = content
        self.readsReleased = readsReleased
    }

    func connect() async throws {}

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        []
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        throw ResourceSourceError.capabilityUnavailable
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        metadataCalls += 1
        return metadata
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        guard range == nil else { throw ResourceSourceError.capabilityUnavailable }
        readCalls += 1
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        defer { activeReads -= 1 }

        while !readsReleased {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                throw ResourceSourceError.cancelled
            }
        }
        try Task.checkCancellation()
        return content
    }

    func releaseReads() {
        readsReleased = true
    }

    func snapshot() -> Snapshot {
        Snapshot(
            metadataCalls: metadataCalls,
            readCalls: readCalls,
            activeReads: activeReads,
            maximumActiveReads: maximumActiveReads
        )
    }
}
