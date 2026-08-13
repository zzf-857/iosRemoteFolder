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

    @Test("视频通过有界 Range 生成真实代表帧")
    func rendersVideoFrameThroughBoundedRanges() async throws {
        let content = try await sampleContent(
            sourceID: SampleData.workSourceID,
            path: "/产品/路线图演示.mp4"
        )
        let fixture = makeFixture(
            kind: .video,
            path: "/预览/代表帧.mp4",
            revision: .etag("video-v1"),
            acceptsRanges: true,
            mimeType: "video/mp4",
            typeIdentifier: "public.mpeg-4",
            content: content,
            readsReleased: true
        )

        let artifact = try await fixture.pipeline.preview(
            for: makeRequest(item: fixture.item)
        )
        guard case .encodedImage(let data, .png, let width, let height) = artifact else {
            Issue.record("视频应生成真实 PNG 代表帧")
            return
        }
        #expect(width > 0 && width <= 80)
        #expect(height > 0 && height <= 80)
        #expect(CGImageSourceCreateWithData(data as CFData, nil) != nil)

        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(!snapshot.readRanges.isEmpty)
        #expect(snapshot.readRanges.allSatisfy { range in
            guard let range else { return false }
            return (range.validatedLength ?? .max) <= 4 * 1024 * 1024
        })
        #expect(snapshot.activeReads == 0)
    }

    @Test("无封面 WAV 诚实降级且不会完整下载")
    func audioWithoutArtworkFallsBackWithoutFullRead() async throws {
        let content = try await sampleContent(
            sourceID: SampleData.workSourceID,
            path: "/产品/路线图演示.wav"
        )
        let fixture = makeFixture(
            kind: .audio,
            path: "/预览/无封面.wav",
            revision: .etag("audio-v1"),
            acceptsRanges: true,
            mimeType: "audio/wav",
            typeIdentifier: "com.microsoft.waveform-audio",
            content: content,
            readsReleased: true
        )

        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            try await fixture.pipeline.preview(for: makeRequest(item: fixture.item))
        }
        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readRanges.allSatisfy { range in
            guard let range else { return false }
            return (range.validatedLength ?? .max) <= 4 * 1024 * 1024
        })
        #expect(snapshot.activeReads == 0)
    }

    @Test("MP3 embedded artwork 通过有界 Range 下采样")
    func rendersEmbeddedMP3ArtworkThroughBoundedRanges() async throws {
        let fixture = makeFixture(
            kind: .audio,
            path: "/预览/带封面.mp3",
            revision: .etag("artwork-v1"),
            acceptsRanges: true,
            mimeType: "audio/mpeg",
            typeIdentifier: "public.mp3",
            content: try makeArtworkMP3(),
            readsReleased: true
        )

        let artifact = try await fixture.pipeline.preview(
            for: makeRequest(item: fixture.item)
        )
        guard case .encodedImage(let data, .png, let width, let height) = artifact else {
            Issue.record("带封面的 MP3 应生成 PNG 预览")
            return
        }
        #expect(width > 0 && width <= 80)
        #expect(height > 0 && height <= 80)
        #expect(CGImageSourceCreateWithData(data as CFData, nil) != nil)

        let snapshot = await fixture.adapter.snapshot()
        #expect(!snapshot.readRanges.isEmpty)
        #expect(snapshot.readRanges.allSatisfy { range in
            guard let range else { return false }
            return (range.validatedLength ?? .max) <= 4 * 1024 * 1024
        })
        #expect(snapshot.activeReads == 0)
    }

    @Test("媒体不支持 Range 时零正文读取")
    func mediaWithoutRangesNeverReadsBody() async throws {
        for kind in [ResourceKind.video, .audio] {
            let fixture = makeFixture(
                kind: kind,
                revision: .etag("no-range-v1"),
                acceptsRanges: false,
                readsReleased: true
            )
            await #expect(throws: ResourceSourceError.capabilityUnavailable) {
                try await fixture.pipeline.preview(for: makeRequest(item: fixture.item))
            }
            let snapshot = await fixture.adapter.snapshot()
            #expect(snapshot.metadataCalls == 1)
            #expect(snapshot.readCalls == 0)
            #expect(snapshot.readRanges.isEmpty)
        }
    }

    @Test("最后媒体 waiter 取消会终止 Range 读取")
    func cancellingLastMediaWaiterStopsRangeRead() async throws {
        let content = try await sampleContent(
            sourceID: SampleData.workSourceID,
            path: "/产品/路线图演示.mp4"
        )
        let fixture = makeFixture(
            kind: .video,
            path: "/预览/取消.mp4",
            revision: .etag("cancel-video-v1"),
            acceptsRanges: true,
            mimeType: "video/mp4",
            typeIdentifier: "public.mpeg-4",
            content: content,
            readsReleased: false
        )
        let request = try makeRequest(item: fixture.item)
        let task = Task { try await fixture.pipeline.preview(for: request) }

        #expect(try await waitUntil { await fixture.adapter.snapshot().activeReads == 1 })
        task.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            try await task.value
        }
        #expect(try await waitUntil { await fixture.adapter.snapshot().activeReads == 0 })

        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.readRanges.allSatisfy { $0 != nil })
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

    @Test("文件夹预览零探测零读取")
    func rejectsUnsupportedAndOversizedResourcesBeforeRead() async throws {
        for kind in [ResourceKind.folder] {
            let unsupported = makeFixture(
                kind: kind,
                revision: .etag("unsupported-v1"),
                readsReleased: true
            )
            let unsupportedRequest = try makeRequest(item: unsupported.item)
            await #expect(throws: ResourceSourceError.capabilityUnavailable) {
                try await unsupported.pipeline.preview(for: unsupportedRequest)
            }
            let unsupportedSnapshot = await unsupported.adapter.snapshot()
            #expect(unsupportedSnapshot.metadataCalls == 0)
            #expect(unsupportedSnapshot.readCalls == 0)
        }
    }

    @Test("文本超预算不会下载正文")
    func rejectsOversizedTextBeforeRead() async throws {
        let oversized = makeFixture(
            revision: .etag("large-v1"),
            metadataByteSize: .some(256 * 1024 + 1),
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

    @Test("未知类型缺少大小、超预算或无合法扩展名时不会读取正文")
    func rejectsUnsafeQuickLookMaterializationBeforeRead() async throws {
        let missingSize = makeFixture(
            kind: .unknown,
            path: "/测试.pages",
            revision: .unknown,
            metadataByteSize: .some(nil),
            readsReleased: true
        )
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            try await missingSize.pipeline.preview(for: makeRequest(item: missingSize.item))
        }
        let missingSizeSnapshot = await missingSize.adapter.snapshot()
        #expect(missingSizeSnapshot.metadataCalls == 1)
        #expect(missingSizeSnapshot.readCalls == 0)

        let oversized = makeFixture(
            kind: .unknown,
            path: "/测试.pages",
            revision: .unknown,
            metadataByteSize: .some(4 * 1024 * 1024 + 1),
            readsReleased: true
        )
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            try await oversized.pipeline.preview(for: makeRequest(item: oversized.item))
        }
        let oversizedSnapshot = await oversized.adapter.snapshot()
        #expect(oversizedSnapshot.metadataCalls == 1)
        #expect(oversizedSnapshot.readCalls == 0)

        let invalidExtension = makeFixture(
            kind: .unknown,
            path: "/测试.文档",
            revision: .unknown,
            readsReleased: true
        )
        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            try await invalidExtension.pipeline.preview(
                for: makeRequest(item: invalidExtension.item)
            )
        }
        let invalidExtensionSnapshot = await invalidExtension.adapter.snapshot()
        #expect(invalidExtensionSnapshot.metadataCalls == 1)
        #expect(invalidExtensionSnapshot.readCalls == 0)
    }

    @Test("有界未知文件至多读取一次且 Quick Look 终态清理物化目录")
    func quickLookMaterializationReadsOnceAndCleansUp() async throws {
        let materializationRoot = quickLookMaterializationRoot()
        try? FileManager.default.removeItem(at: materializationRoot)
        defer { try? FileManager.default.removeItem(at: materializationRoot) }

        let content = Data("不是有效的 Pages 文档".utf8)
        let fixture = makeFixture(
            kind: .unknown,
            path: "/测试.pages",
            revision: .unknown,
            metadataByteSize: .some(Int64(content.count)),
            content: content,
            readsReleased: true
        )

        do {
            let artifact = try await fixture.pipeline.preview(
                for: makeRequest(item: fixture.item)
            )
            guard case .encodedImage = artifact else {
                Issue.record("Quick Look 成功时只能返回真实缩略图")
                return
            }
        } catch {
            let sourceError = ResourceSourceError.mapping(error)
            #expect(isDegradableQuickLookError(sourceError))
        }

        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)
        #expect(snapshot.activeReads == 0)
        #expect(try materializationDirectories(at: materializationRoot).isEmpty)
    }

    @Test("未知文件在正文读取阶段取消会关闭读取并清理物化目录")
    func cancellingQuickLookReadLeavesNoMaterializedFile() async throws {
        let materializationRoot = quickLookMaterializationRoot()
        try? FileManager.default.removeItem(at: materializationRoot)
        defer { try? FileManager.default.removeItem(at: materializationRoot) }

        let content = Data("等待取消".utf8)
        let fixture = makeFixture(
            kind: .unknown,
            path: "/测试.pages",
            revision: .unknown,
            metadataByteSize: .some(Int64(content.count)),
            content: content,
            readsReleased: false
        )
        let request = try makeRequest(item: fixture.item)
        let task = Task { try await fixture.pipeline.preview(for: request) }

        #expect(try await waitUntil { await fixture.adapter.snapshot().activeReads == 1 })
        task.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            try await task.value
        }
        #expect(try await waitUntil { await fixture.adapter.snapshot().activeReads == 0 })

        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)
        #expect(try materializationDirectories(at: materializationRoot).isEmpty)
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

        let rowRequest = try #require(ResourcePreviewRequest(
            item: item,
            targetSize: CGSize(width: 40, height: 40),
            displayScale: 3
        ))
        let continueCardRequest = try #require(ResourcePreviewRequest(
            item: item,
            targetSize: CGSize(width: 260, height: 96),
            displayScale: 3
        ))
        #expect(rowRequest.targetSize == CGSize(width: 40, height: 40))
        #expect(continueCardRequest.targetSize == CGSize(width: 260, height: 96))
        #expect(rowRequest.pixelWidth == 120)
        #expect(rowRequest.pixelHeight == 120)
        #expect(continueCardRequest.pixelWidth == 780)
        #expect(continueCardRequest.pixelHeight == 288)
        #expect(rowRequest != continueCardRequest)
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

    private func sampleContent(sourceID: UUID, path: String) async throws -> Data {
        let source = try #require(SampleData.sources.first { $0.id == sourceID })
        let item = try #require(SampleData.resources.first {
            $0.sourceID == sourceID && $0.path == path
        })
        return try await SampleSourceAdapter(source: source).readData(
            for: item,
            range: nil
        )
    }

    private func makeArtworkMP3() throws -> Data {
        let encodedAudio = "//sQxAAABHQTVVSQgDCmCa83GiACAAGtOUAAAVk6PVBQCAYJAfB8HwfKAgCAYRB8H9QIOxOH+INwBJP2wGA4HA4AAAAAACiJKpkUZAjpAkgWo/eFAfATG/AilC+oGhL8JA0qAAAA4An/+xLEAoKFHB0vvdAAIJuDpXWO4EyAAADguCBABSUEYDGw+EmlhTmJQTmCgEgkAiyQKAJr3d3/r9QAEsAFO1hCWZGGGIwm6XJm44wmGQIGkZd9CQFTsTsH/7////9N36Yw0OMOHTHTgz7/+xDEBIIFBB8YDfsiQLKDpGmfZEyDMK8b41DOHDTrG0MJ4G01zAIGbqh1fmsGyaWhz9f0AFRQGAA/iRZiCG/OYNAVhmcruGZIFcYNYF5xLGMUYY5hPIOS8E/7M/+3//+qAAAAwAFgAP/7EsQDggVYHyes+4IgowOm9G5sDgCgKCYGDmPIYGAU5jxren1FGYrDiRLOkAJgEDKXTvdX//IfqLogEDbAFhDlqAGCQybQuZ5YyECCm7W3YZG5eBSGfs/3f6fuwx+fTGjaMLEDDB8xk//7EMQDgAUAHxgN+yJAq4Ondc2whsM4iTCfHSNKTrQ0hRyDCMB1M1QDCnCgd3JsAs2nQ5+n6AQAE7gJaIgBynZwgHMAAo07CjmAoOAwGCQSwUAg+K35D+p2xStVn+rfu9MwoRMNHjFj//sSxAOABPwfGA37IkB/A6i0HTAW0zWMMJQd00b++zROHTMIUHgyGQcUcRp46ALJfs8G/0/YCASxwAMBQAII2zhL843UJDskA+SyQHYJuYD//2///PoCADI0eFFwAAAYK0pBCMgBkWIA//sQxAmABJwdReHvIHCRA2e0zbBOwn9ZFAr9M5abaMwMkUTs9T/eAAAhcAKBGAOfMAPgQCONzDiAJEcDhIJYoBA/u3//Uz//ZT/01QoAA/rhLxEYjAAQzKWwznkECgDcYGdVdzbWegj/+xLEDgBDXB8yrHdiIHqDaPQdPBYIu/4AYQS93FhzeVw7u2gmZb2BFnOcOX16//6UtqUABAgaUCAAAPmFFCyiEOGTs8c04pisp5Ys/sC3/Hcz//9jHQwWZoQcVaYXgYBqpsvGpgGEYXr/+xDEGwDENB07p/NCMI8D44GvaE0HpxFRlDxizphogMCP/ULKMECzAxgwg3MbgDBeG5Mwve0y9BsTBNByGHSZIBenW0EVNBnjP6AAAYo5NYHLdt5woCGFFR+mie+nmPhqEZe8BA5adv/7EsQhgES4HxoN+yJg9w3nNrZgBVbgNcsfomTT1jCCDgAIy09iHIABDnkyabH34x7tiY/gigAALBIIxYKBAGAAAAAGCgFDLv+DlmtY7/zHlNRCQ03+FKB5GSeFxCei4r4Ose4kBfrr8f/7EMQZgAiMg1W5loAQAAA0g4AABBoT0aCoef/mhqXjExOfLmlC1UxBTUUzLjEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        let audio = try #require(Data(base64Encoded: encodedAudio))
        let artwork = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        var payload = Data([0])
        payload.append(Data("image/png".utf8))
        payload.append(0)
        payload.append(3)
        payload.append(0)
        payload.append(artwork)

        var frame = Data("APIC".utf8)
        frame.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        frame.append(contentsOf: [0, 0])
        frame.append(payload)

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [3, 0, 0])
        tag.append(contentsOf: synchsafeBytes(frame.count))
        tag.append(frame)
        tag.append(audio)
        return tag
    }

    private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private func synchsafeBytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ]
    }

    private func makeFixture(
        kind: ResourceKind = .text,
        path: String? = nil,
        revision: ResourceRevision,
        resolvedRevision: ResourceRevision? = nil,
        metadataByteSize: Int64?? = nil,
        acceptsRanges: Bool = false,
        mimeType: String? = nil,
        typeIdentifier: String? = nil,
        content: Data = Data("预览正文".utf8),
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
        let resolvedMimeType = mimeType ?? defaultMIMEType(for: kind)
        let resolvedTypeIdentifier = typeIdentifier ?? defaultTypeIdentifier(for: kind)
        let metadata = ResourceMetadata(
            byteSize: metadataByteSize ?? Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            mimeType: resolvedMimeType,
            typeIdentifier: resolvedTypeIdentifier,
            acceptsRanges: acceptsRanges,
            revision: resolvedRevision ?? revision
        )
        let item = try! makeItem(
            sourceID: source.id,
            path: path ?? defaultFixturePath(for: kind),
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

    private func defaultFixturePath(for kind: ResourceKind) -> String {
        switch kind {
        case .folder: "/测试文件夹"
        case .video: "/测试.mp4"
        case .audio: "/测试.mp3"
        case .image: "/测试.png"
        case .pdf: "/测试.pdf"
        case .markdown: "/测试.md"
        case .text: "/测试.txt"
        case .unknown: "/测试.pages"
        }
    }

    private func defaultMIMEType(for kind: ResourceKind) -> String {
        switch kind {
        case .video: "video/mp4"
        case .audio: "audio/mpeg"
        case .image: "image/png"
        case .pdf: "application/pdf"
        case .markdown: "text/markdown"
        case .folder, .text, .unknown: "text/plain"
        }
    }

    private func defaultTypeIdentifier(for kind: ResourceKind) -> String {
        switch kind {
        case .video: "public.mpeg-4"
        case .audio: "public.mp3"
        case .image: "public.png"
        case .pdf: "com.adobe.pdf"
        case .markdown: "net.daringfireball.markdown"
        case .folder: "public.folder"
        case .text, .unknown: "public.plain-text"
        }
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

    private func quickLookMaterializationRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder", isDirectory: true)
            .appendingPathComponent("preview-materialization-v1", isDirectory: true)
    }

    private func materializationDirectories(at root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    private func isDegradableQuickLookError(_ error: ResourceSourceError) -> Bool {
        switch error {
        case .capabilityUnavailable, .invalidResponse, .unavailable:
            true
        default:
            false
        }
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
        let readRanges: [ResourceByteRange?]
        let activeReads: Int
        let maximumActiveReads: Int
    }

    nonisolated let source: ResourceSource
    private let metadata: ResourceMetadata
    private let content: Data
    private var readsReleased: Bool
    private var metadataCalls = 0
    private var readCalls = 0
    private var readRanges: [ResourceByteRange?] = []
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
        readCalls += 1
        readRanges.append(range)
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
        guard let range else { return content }
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound < Int64(content.count),
              let lowerBound = Int(exactly: range.lowerBound),
              let upperBound = Int(exactly: range.upperBound + 1) else {
            throw ResourceSourceError.invalidReference
        }
        return content.subdata(in: lowerBound..<upperBound)
    }

    func releaseReads() {
        readsReleased = true
    }

    func snapshot() -> Snapshot {
        Snapshot(
            metadataCalls: metadataCalls,
            readCalls: readCalls,
            readRanges: readRanges,
            activeReads: activeReads,
            maximumActiveReads: maximumActiveReads
        )
    }
}
