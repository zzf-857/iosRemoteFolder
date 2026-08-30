import Foundation
import ImageIO
import PDFKit
import Testing

@testable import iosRemoteFolder

private final class PreviewImageExecutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var mainThreadObservation: Bool?

    func record(isMainThread: Bool) {
        lock.lock()
        callCount += 1
        mainThreadObservation = isMainThread
        lock.unlock()
    }

    var snapshot: (callCount: Int, observedMainThread: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        return (callCount, mainThreadObservation)
    }
}

@Suite("统一资源预览管线", .serialized)
struct ResourcePreviewPipelineTests {
    @Test("编码缩略图仅在后台准备一次并持有解码结果")
    @MainActor
    func preparesEncodedThumbnailOnceOffMainActor() async throws {
        let data = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let probe = PreviewImageExecutionProbe()

        let displayArtifact = try await ResourcePreviewDisplayPreparer.prepare(
            .encodedImage(
                data: data,
                format: .png,
                pixelWidth: 1,
                pixelHeight: 1
            ),
            imageExecutionObserver: probe.record(isMainThread:)
        )

        guard case .image(let image) = displayArtifact else {
            Issue.record("编码图片应准备为可直接展示的 CGImage")
            return
        }
        #expect(image.pixelWidth == 1)
        #expect(image.pixelHeight == 1)
        let snapshot = probe.snapshot
        #expect(snapshot.callCount == 1)
        #expect(snapshot.observedMainThread == false)
    }

    @Test("共享类型解析统一证据、Viewer 与浏览筛选")
    func resolvesGenericMIMEAndSharedConsumers() throws {
        let genericPDF = try makeResolvedItem(
            path: "/文档/手册.pdf",
            kind: .unknown,
            metadata: ResourceMetadata(
                mimeType: "application/octet-stream",
                typeIdentifier: "public.data"
            )
        )

        let contentType = genericPDF.resolvedContentType
        #expect(contentType.kind == .pdf)
        #expect(contentType.confidence == .medium)
        #expect(contentType.diagnostics.isEmpty)
        #expect(contentType.evidence.contains { evidence in
            evidence.source == .mimeType
                && evidence.kind == .unknown
                && evidence.strength == .generic
        })
        #expect(contentType.evidence.contains { evidence in
            evidence.source == .filenameExtension
                && evidence.kind == .pdf
                && evidence.strength == .inferred
        })

        let viewer = ViewerRegistry.resolve(
            resource: genericPDF,
            metadata: genericPDF.metadata
        )
        #expect(viewer.contentType == contentType)
        #expect(viewer.kind == .pdfReader)

        let systemFile = try makeResolvedItem(
            path: "/文档/report.docx",
            kind: .unknown,
            metadata: ResourceMetadata(
                byteSize: 4_096,
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        )
        let systemResolution = ViewerRegistry.resolve(
            resource: systemFile,
            metadata: systemFile.metadata
        )
        #expect(systemResolution.kind == .systemPreview)
        #expect(
            systemResolution.preparation
                == .file(maximumBytes: ViewerRegistry.systemFallbackMaximumBytes)
        )

        let directory = try makeResolvedItem(
            path: "/文档/子目录.pdf",
            kind: .unknown,
            metadata: ResourceMetadata(isDirectory: true)
        )
        let folderResolution = ViewerRegistry.resolve(
            resource: directory,
            metadata: directory.metadata
        )
        #expect(folderResolution.kind == .systemPreview)
        #expect(folderResolution.preparation == .none)

        let declaredPDFButTypedText = try makeResolvedItem(
            path: "/文档/说明.txt",
            kind: .pdf,
            metadata: ResourceMetadata(
                mimeType: "text/plain",
                typeIdentifier: "public.plain-text"
            )
        )
        #expect(
            BrowseResourceFilter.filter(
                [genericPDF, declaredPDFButTypedText, directory],
                selectedKind: .pdf
            ) == [genericPDF, directory]
        )
    }

    @Test("Markdown 兼容、无扩展与 declared 低置信回退确定性解析")
    func resolvesCompatibleAndFallbackEvidence() throws {
        let markdown = try makeResolvedItem(
            path: "/笔记/readme.md",
            kind: .text,
            metadata: ResourceMetadata(
                mimeType: "text/markdown; charset=utf-8",
                typeIdentifier: "public.plain-text"
            )
        ).resolvedContentType
        #expect(markdown.kind == .markdown)
        #expect(markdown.confidence == .high)
        #expect(markdown.diagnostics.isEmpty)

        for path in ["/数据/payload.json", "/网页/index.html", "/数据/feed.xml"] {
            let typedText = try makeResolvedItem(
                path: path,
                kind: .unknown,
                metadata: ResourceMetadata(
                    mimeType: "text/plain",
                    typeIdentifier: "public.plain-text"
                )
            ).resolvedContentType
            #expect(typedText.kind == .text)
            #expect(typedText.confidence == .high)
            #expect(!typedText.hasBlockingConflict)
        }

        let genericPDF = try makeResolvedItem(
            path: "/文档/manual.pdf",
            kind: .unknown,
            metadata: ResourceMetadata(mimeType: "application/x-binary")
        ).resolvedContentType
        #expect(genericPDF.kind == .pdf)
        #expect(genericPDF.confidence == .medium)

        for (mimeType, expectedKind) in [
            ("audio/opus", ResourceKind.audio),
            ("image/x-icon", ResourceKind.image),
            ("video/x-matroska", ResourceKind.video)
        ] {
            let vendorMedia = try makeResolvedItem(
                path: "/媒体/extensionless",
                kind: .unknown,
                metadata: ResourceMetadata(mimeType: mimeType)
            ).resolvedContentType
            #expect(vendorMedia.kind == expectedKind)
            #expect(vendorMedia.confidence == .high)
            #expect(!vendorMedia.hasBlockingConflict)
        }

        let extensionlessAudio = try makeResolvedItem(
            path: "/媒体/track",
            kind: .unknown,
            metadata: ResourceMetadata(
                mimeType: "audio/mpeg",
                typeIdentifier: "public.mp3"
            )
        ).resolvedContentType
        #expect(extensionlessAudio.kind == .audio)
        #expect(extensionlessAudio.confidence == .high)

        let declaredOnly = try makeResolvedItem(
            path: "/资源/cover",
            kind: .image,
            metadata: ResourceMetadata()
        ).resolvedContentType
        #expect(declaredOnly.kind == .image)
        #expect(declaredOnly.confidence == .low)
        #expect(declaredOnly.evidence.contains { $0.source == .declaredKind })

        let officeDocument = try makeResolvedItem(
            path: "/文档/report.docx",
            kind: .unknown,
            metadata: ResourceMetadata(
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        ).resolvedContentType
        #expect(officeDocument.kind == .unknown)
        #expect(!officeDocument.hasBlockingConflict)
        #expect(!officeDocument.diagnostics.contains { diagnostic in
            if case .metadataExtensionMismatch = diagnostic { return true }
            return false
        })

        let typedArchiveWithoutExtension = try makeResolvedItem(
            path: "/资源/download",
            kind: .pdf,
            metadata: ResourceMetadata(mimeType: "application/zip")
        ).resolvedContentType
        #expect(typedArchiveWithoutExtension.kind == .unknown)
        #expect(typedArchiveWithoutExtension.confidence == .high)
        #expect(!typedArchiveWithoutExtension.hasBlockingConflict)

        for path in ["/文档/report.docx", "/归档/package.zip"] {
            let extensionOnlySystemFile = try makeResolvedItem(
                path: path,
                kind: .pdf,
                metadata: ResourceMetadata(byteSize: 4_096)
            )
            let contentType = extensionOnlySystemFile.resolvedContentType
            #expect(contentType.kind == .unknown)
            #expect(contentType.confidence == .medium)
            #expect(!contentType.hasBlockingConflict)
            #expect(
                ViewerRegistry.resolve(
                    resource: extensionOnlySystemFile,
                    metadata: extensionOnlySystemFile.metadata
                ).preparation == .file(
                    maximumBytes: ViewerRegistry.systemFallbackMaximumBytes
                )
            )
        }

        let declaredFolderWithTypedFile = try makeResolvedItem(
            path: "/文档/manual.pdf",
            kind: .folder,
            metadata: ResourceMetadata(
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf"
            )
        ).resolvedContentType
        #expect(declaredFolderWithTypedFile.kind == .pdf)
        #expect(declaredFolderWithTypedFile.confidence == .high)

        let dottedDeclaredFolder = try makeResolvedItem(
            path: "/文档/archive.zip",
            kind: .folder,
            metadata: ResourceMetadata()
        ).resolvedContentType
        #expect(dottedDeclaredFolder.kind == .folder)
        #expect(dottedDeclaredFolder.confidence == .low)
    }

    @Test("签名确认弱证据、纠正 declared hint 并阻断强冲突")
    func resolvesSignatureEvidenceWithSafeConflictRules() throws {
        let pdfMatch = ContentSignatureMatch(
            formatToken: "pdf",
            kind: .pdf,
            canonicalTypeIdentifier: "com.adobe.pdf",
            strength: .exact
        )
        let genericItem = try makeResolvedItem(
            path: "/资源/download",
            kind: .unknown,
            metadata: ResourceMetadata(
                mimeType: "application/octet-stream",
                typeIdentifier: "public.data"
            )
        )
        #expect(genericItem.resolvedContentType.signatureProbe == .required)
        let signaturePDF = ResolvedContentType.resolve(
            resource: genericItem,
            metadata: genericItem.metadata,
            signatureProbe: .matched(pdfMatch)
        )
        #expect(signaturePDF.kind == .pdf)
        #expect(signaturePDF.confidence == .high)
        #expect(!signaturePDF.hasBlockingConflict)
        #expect(signaturePDF.signatureProbe == .matched(pdfMatch))

        let weakDeclaredImage = try makeResolvedItem(
            path: "/资源/no-extension",
            kind: .image,
            metadata: ResourceMetadata()
        )
        let corrected = ResolvedContentType.resolve(
            resource: weakDeclaredImage,
            metadata: weakDeclaredImage.metadata,
            signatureProbe: .matched(pdfMatch)
        )
        #expect(corrected.kind == .pdf)
        #expect(!corrected.hasBlockingConflict)
        #expect(corrected.diagnostics.contains { diagnostic in
            if case .declaredKindOverridden(
                declared: .image,
                signature: .pdf,
                formatToken: "pdf"
            ) = diagnostic {
                return true
            }
            return false
        })

        let strongExtension = try makeResolvedItem(
            path: "/资源/cover.jpg",
            kind: .unknown,
            metadata: ResourceMetadata(mimeType: "application/octet-stream")
        )
        let blocked = ResolvedContentType.resolve(
            resource: strongExtension,
            metadata: strongExtension.metadata,
            signatureProbe: .matched(pdfMatch)
        )
        #expect(blocked.kind == .unknown)
        #expect(blocked.hasBlockingConflict)
        #expect(blocked.fallbackDescription == "文件签名与声明类型不一致")

        let pngMatch = ContentSignatureMatch(
            formatToken: "png",
            kind: .image,
            canonicalTypeIdentifier: "public.png",
            strength: .exact
        )
        let sameKindImageConflict = ResolvedContentType.resolve(
            resource: strongExtension,
            metadata: strongExtension.metadata,
            signatureProbe: .matched(pngMatch)
        )
        #expect(sameKindImageConflict.kind == .unknown)
        #expect(sameKindImageConflict.hasBlockingConflict)

        let mp3Item = try makeResolvedItem(
            path: "/资源/audio.mp3",
            kind: .unknown,
            metadata: ResourceMetadata(mimeType: "application/octet-stream")
        )
        let wavMatch = ContentSignatureMatch(
            formatToken: "wav",
            kind: .audio,
            canonicalTypeIdentifier: "com.microsoft.waveform-audio",
            strength: .exact
        )
        #expect(ResolvedContentType.resolve(
            resource: mp3Item,
            metadata: mp3Item.metadata,
            signatureProbe: .matched(wavMatch)
        ).hasBlockingConflict)

        let heicItem = try makeResolvedItem(
            path: "/资源/photo.heic",
            kind: .unknown,
            metadata: ResourceMetadata(mimeType: "application/octet-stream")
        )
        let heifMatch = ContentSignatureMatch(
            formatToken: "heif",
            kind: .image,
            canonicalTypeIdentifier: "public.heif",
            strength: .exact
        )
        #expect(!ResolvedContentType.resolve(
            resource: heicItem,
            metadata: heicItem.metadata,
            signatureProbe: .matched(heifMatch)
        ).hasBlockingConflict)

        let textHeuristic = ContentSignatureMatch(
            formatToken: "utf8-text",
            kind: .text,
            canonicalTypeIdentifier: "public.plain-text",
            strength: .heuristic
        )
        let heuristicResult = ResolvedContentType.resolve(
            resource: strongExtension,
            metadata: strongExtension.metadata,
            signatureProbe: .matched(textHeuristic)
        )
        #expect(heuristicResult.kind == .image)
        #expect(!heuristicResult.hasBlockingConflict)

        let officeItem = try makeResolvedItem(
            path: "/资源/report.docx",
            kind: .unknown,
            metadata: ResourceMetadata(mimeType: "application/octet-stream")
        )
        let zipMatch = ContentSignatureMatch(
            formatToken: "zip",
            kind: .unknown,
            canonicalTypeIdentifier: "public.zip-archive",
            strength: .container
        )
        let officeContainer = ResolvedContentType.resolve(
            resource: officeItem,
            metadata: officeItem.metadata,
            signatureProbe: .matched(zipMatch)
        )
        #expect(officeContainer.kind == .unknown)
        #expect(officeContainer.confidence == .high)
        #expect(!officeContainer.hasBlockingConflict)

        let isoBMFFMatch = ContentSignatureMatch(
            formatToken: "iso-bmff",
            kind: .unknown,
            canonicalTypeIdentifier: nil,
            strength: .container
        )
        #expect(ResolvedContentType.resolve(
            resource: mp3Item,
            metadata: mp3Item.metadata,
            signatureProbe: .matched(isoBMFFMatch)
        ).hasBlockingConflict)
        let m4aItem = try makeResolvedItem(
            path: "/资源/audio.m4a",
            kind: .unknown,
            metadata: ResourceMetadata(mimeType: "application/octet-stream")
        )
        #expect(!ResolvedContentType.resolve(
            resource: m4aItem,
            metadata: m4aItem.metadata,
            signatureProbe: .matched(isoBMFFMatch)
        ).hasBlockingConflict)
        for extensionName in ["m4b", "m4p", "m4r"] {
            let item = try makeResolvedItem(
                path: "/资源/audio.\(extensionName)",
                kind: .unknown,
                metadata: ResourceMetadata(mimeType: "application/octet-stream")
            )
            #expect(!ResolvedContentType.resolve(
                resource: item,
                metadata: item.metadata,
                signatureProbe: .matched(isoBMFFMatch)
            ).hasBlockingConflict)
        }
        for extensionName in ["odt", "ods", "odp"] {
            let item = try makeResolvedItem(
                path: "/资源/document.\(extensionName)",
                kind: .unknown,
                metadata: ResourceMetadata(mimeType: "application/octet-stream")
            )
            #expect(!ResolvedContentType.resolve(
                resource: item,
                metadata: item.metadata,
                signatureProbe: .matched(zipMatch)
            ).hasBlockingConflict)
        }

        let extensionlessZIP = ResolvedContentType.resolve(
            resource: genericItem,
            metadata: genericItem.metadata,
            signatureProbe: .matched(zipMatch)
        )
        #expect(
            ResourcePreviewPipeline.quickLookFilename(
                for: genericItem.name,
                contentType: extensionlessZIP
            )?.hasSuffix(".zip") == true
        )

        let noMatch = ResolvedContentType.resolve(
            resource: genericItem,
            metadata: genericItem.metadata,
            signatureProbe: .noMatch
        )
        let unavailable = ResolvedContentType.resolve(
            resource: genericItem,
            metadata: genericItem.metadata,
            signatureProbe: .unavailable
        )
        #expect(noMatch.stableFingerprint != unavailable.stableFingerprint)
        #expect(noMatch.stableFingerprint != genericItem.resolvedContentType.stableFingerprint)

        let trustedTyped = try makeResolvedItem(
            path: "/资源/manual.pdf",
            kind: .pdf,
            metadata: ResourceMetadata(
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf"
            )
        )
        #expect(trustedTyped.resolvedContentType.signatureProbe == .notRequired)
    }

    @Test("强 typed 冲突安全降级且目录事实优先")
    func rejectsStrongConflictAndPrioritizesDirectoryFact() async throws {
        let conflictItem = try makeResolvedItem(
            path: "/资源/no-extension",
            kind: .image,
            metadata: ResourceMetadata(
                mimeType: "image/jpeg",
                typeIdentifier: "public.plain-text"
            )
        )
        let conflict = conflictItem.resolvedContentType
        #expect(conflict.kind == .unknown)
        #expect(conflict.confidence == .none)
        #expect(conflict.hasBlockingConflict)
        #expect(conflict.diagnostics.contains { diagnostic in
            if case .conflictingTypedMetadata(
                typeIdentifier: .text,
                mimeType: .image
            ) = diagnostic {
                return true
            }
            return false
        })
        #expect(
            ViewerRegistry.resolve(
                resource: conflictItem,
                metadata: conflictItem.metadata
            ).kind == .systemPreview
        )

        let folder = try makeResolvedItem(
            path: "/资源/folder.pdf",
            kind: .unknown,
            metadata: ResourceMetadata(
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf",
                isDirectory: true
            )
        ).resolvedContentType
        #expect(folder.kind == .folder)
        #expect(folder.confidence == .authoritative)
        #expect(folder.diagnostics.isEmpty)
        #expect(folder.evidence.contains { $0.source == .directory })

        let fixture = makeFixture(
            kind: .unknown,
            path: "/资源/no-extension",
            revision: .etag("typed-conflict-v1"),
            mimeType: "image/jpeg",
            typeIdentifier: "public.plain-text",
            readsReleased: true
        )
        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            try await fixture.pipeline.preview(for: makeRequest(item: fixture.item))
        }
        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 0)
        #expect(snapshot.readCalls == 0)

        let zipDisguisedAsPDF = try makeResolvedItem(
            path: "/资源/archive.pdf",
            kind: .pdf,
            metadata: ResourceMetadata(mimeType: "application/zip")
        ).resolvedContentType
        #expect(zipDisguisedAsPDF.kind == .unknown)
        #expect(zipDisguisedAsPDF.hasBlockingConflict)
        #expect(zipDisguisedAsPDF.diagnostics.contains { diagnostic in
            if case .metadataExtensionMismatch(
                metadata: .unknown,
                filenameExtension: .pdf
            ) = diagnostic {
                return true
            }
            return false
        })
        let blockedViewer = ViewerRegistry.resolve(
            resource: try makeResolvedItem(
                path: "/资源/archive.pdf",
                kind: .pdf,
                metadata: ResourceMetadata(
                    byteSize: 4_096,
                    mimeType: "application/zip"
                )
            ),
            metadata: ResourceMetadata(
                byteSize: 4_096,
                mimeType: "application/zip"
            )
        )
        #expect(blockedViewer.kind == .systemPreview)
        #expect(blockedViewer.preparation == .none)
    }

    @Test("预览管线按 generic MIME 下的强扩展选择 renderer")
    func previewUsesSharedResolutionForGenericMIME() async throws {
        let fixture = makeFixture(
            kind: .unknown,
            path: "/预览/说明.md",
            revision: .etag("generic-markdown-v1"),
            mimeType: "application/octet-stream",
            typeIdentifier: "public.data",
            content: Data("# 标题\n正文".utf8),
            readsReleased: true
        )

        let artifact = try await fixture.pipeline.preview(
            for: makeRequest(item: fixture.item)
        )
        guard case .textExcerpt(let excerpt) = artifact else {
            Issue.record("Markdown 扩展应选择文本预览 renderer")
            return
        }
        #expect(excerpt.contains("标题 正文"))
        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)
    }

    @Test("generic MIME 无扩展 PNG/PDF 由签名选择 renderer 并复用 revision 别名")
    func signatureSelectsRendererAndPersistsKnownRevisionAlias() async throws {
        let pngData = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let pngFixture = makeFixture(
            kind: .unknown,
            path: "/预览/extensionless-image",
            revision: .etag("signature-png-v1"),
            mimeType: "application/octet-stream",
            typeIdentifier: "public.data",
            content: pngData,
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        let pngRequest = try makeRequest(item: pngFixture.item)
        #expect(pngRequest.contentType.signatureProbe == .required)

        for _ in 0..<2 {
            guard case .encodedImage = try await pngFixture.pipeline.preview(for: pngRequest) else {
                Issue.record("PNG 签名应选择图片 renderer")
                return
            }
        }
        var pngSnapshot = await pngFixture.adapter.snapshot()
        #expect(pngSnapshot.metadataCalls == 1)
        #expect(pngSnapshot.readCalls == 1)

        let restoredPipeline = ResourcePreviewPipeline(
            accessService: pngFixture.accessService,
            cacheDirectory: cacheDirectory
        )
        guard case .encodedImage = try await restoredPipeline.preview(for: pngRequest) else {
            Issue.record("签名解析后的持久 revision 别名应返回图片")
            return
        }
        try FileManager.default.removeItem(at: cacheDirectory)
        guard case .encodedImage = try await restoredPipeline.preview(for: pngRequest) else {
            Issue.record("磁盘 alias 命中后应提升为已验证的内存命中")
            return
        }
        pngSnapshot = await pngFixture.adapter.snapshot()
        #expect(pngSnapshot.metadataCalls == 1)
        #expect(pngSnapshot.readCalls == 1)

        let pdfData = try await sampleContent(
            sourceID: SampleData.personalSourceID,
            path: "/知识库/设计/设计系统与组件规范.pdf"
        )
        let pdfFixture = makeFixture(
            kind: .unknown,
            path: "/预览/extensionless-document",
            revision: .etag("signature-pdf-v1"),
            mimeType: "application/octet-stream",
            typeIdentifier: "public.data",
            content: pdfData,
            readsReleased: true
        )
        guard case .encodedImage = try await pdfFixture.pipeline.preview(
            for: makeRequest(item: pdfFixture.item)
        ) else {
            Issue.record("PDF 签名应选择 PDF renderer")
            return
        }
        let pdfSnapshot = await pdfFixture.adapter.snapshot()
        #expect(pdfSnapshot.metadataCalls == 1)
        #expect(pdfSnapshot.readCalls == 1)
    }

    @Test("同类不同格式冲突仅读取 4 KiB 签名前缀")
    func sameKindSignatureConflictStopsBeforeFullBody() async throws {
        let pngData = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        var content = pngData
        content.append(Data(repeating: 0, count: 5_000))
        let fixture = makeFixture(
            kind: .unknown,
            path: "/预览/disguised.jpg",
            revision: .etag("signature-conflict-v1"),
            acceptsRanges: true,
            mimeType: "application/octet-stream",
            typeIdentifier: "public.data",
            content: content,
            readsReleased: true
        )

        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            try await fixture.pipeline.preview(for: makeRequest(item: fixture.item))
        }
        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)
        #expect(snapshot.readRanges == [ResourceByteRange(lowerBound: 0, upperBound: 4_095)])
    }

    @Test("签名前缀不可用时不缓存 artifact 或建立类型别名")
    func unavailableSignatureProbeDoesNotCacheAlias() async throws {
        let pngData = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        var content = pngData
        content.append(Data(repeating: 0, count: 5_000))
        let fixture = makeFixture(
            kind: .unknown,
            path: "/预览/unavailable.png",
            revision: .etag("signature-unavailable-v1"),
            mimeType: "application/octet-stream",
            typeIdentifier: "public.data",
            content: content,
            readsReleased: true
        )
        let request = try makeRequest(item: fixture.item)

        for _ in 0..<2 {
            guard case .encodedImage = try await fixture.pipeline.preview(for: request) else {
                Issue.record("无法探测签名时仍应按扩展名渲染有效图片")
                return
            }
        }
        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 2)
        #expect(snapshot.readCalls == 2)
        #expect(snapshot.readRanges == [nil, nil])
    }

    @Test("初始强类型冲突在缓存查找前零探测拒绝")
    func rejectsInitialBlockingConflictBeforeCacheLookup() async throws {
        let revision = ResourceRevision.etag("initial-conflict-v1")
        let path = "/预览/conflict.txt"
        let fixture = makeFixture(
            kind: .text,
            path: path,
            revision: revision,
            readsReleased: true
        )

        let healthyRequest = try makeRequest(item: fixture.item)
        #expect(
            try await fixture.pipeline.preview(for: healthyRequest)
                == .textExcerpt("预览正文")
        )
        let primedSnapshot = await fixture.adapter.snapshot()
        #expect(primedSnapshot.metadataCalls == 1)
        #expect(primedSnapshot.readCalls == 1)

        let conflictingItem = try makeItem(
            sourceID: fixture.source.id,
            path: path,
            kind: .text,
            byteSize: fixture.item.metadata.byteSize,
            mimeType: "image/jpeg",
            typeIdentifier: "public.plain-text",
            revision: revision
        )
        let conflictingRequest = try makeRequest(item: conflictingItem)
        #expect(conflictingItem.id == fixture.item.id)
        #expect(conflictingRequest.contentType.hasBlockingConflict)

        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            try await fixture.pipeline.preview(for: conflictingRequest)
        }
        let rejectedSnapshot = await fixture.adapter.snapshot()
        #expect(rejectedSnapshot.metadataCalls == primedSnapshot.metadataCalls)
        #expect(rejectedSnapshot.readCalls == primedSnapshot.readCalls)
    }

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

    @Test("大文本与 Markdown 仅读取前 64 KiB")
    func largeTextAndMarkdownReadOnePrefixRange() async throws {
        for kind in [ResourceKind.text, .markdown] {
            var content = Data("标题\n摘要\n".utf8)
            content.append(Data(repeating: 0x61, count: 64 * 1024))
            let fixture = makeFixture(
                kind: kind,
                revision: .etag("large-text-\(kind)"),
                acceptsRanges: true,
                content: content,
                readsReleased: true
            )

            let artifact = try await fixture.pipeline.preview(
                for: makeRequest(item: fixture.item)
            )
            guard case .textExcerpt(let excerpt) = artifact else {
                Issue.record("文本资源应生成文本摘要")
                continue
            }
            #expect(excerpt.contains("标题 摘要"))

            let snapshot = await fixture.adapter.snapshot()
            #expect(snapshot.metadataCalls == 1)
            #expect(snapshot.readCalls == 1)
            let range = try #require(snapshot.readRanges.first ?? nil)
            #expect(range == ResourceByteRange(lowerBound: 0, upperBound: 65_535))
        }
    }

    @Test("恰好 64 KiB 或不支持 Range 的文本保持完整读取")
    func boundaryAndNonRangeTextKeepFullRead() async throws {
        let cases: [(name: String, byteCount: Int, acceptsRanges: Bool)] = [
            ("恰好 64 KiB", 64 * 1024, true),
            ("无 Range", 64 * 1024 + 1, false)
        ]

        for testCase in cases {
            var content = Data("完整读取".utf8)
            content.append(Data(
                repeating: 0x20,
                count: testCase.byteCount - content.count
            ))
            let fixture = makeFixture(
                revision: .etag("full-text-\(testCase.name)"),
                acceptsRanges: testCase.acceptsRanges,
                content: content,
                readsReleased: true
            )

            #expect(
                try await fixture.pipeline.preview(for: makeRequest(item: fixture.item))
                    == .textExcerpt("完整读取")
            )
            let snapshot = await fixture.adapter.snapshot()
            #expect(snapshot.readCalls == 1)
            #expect(snapshot.readRanges.count == 1)
            #expect(snapshot.readRanges[0] == nil)
        }
    }

    @Test("截断前缀安全修复 UTF-8 与 UTF-16 多字节尾部")
    func repairsTruncatedMultibyteTextTails() {
        var utf8 = Data([0xEF, 0xBB, 0xBF])
        utf8.append(Data("UTF-8 正文".utf8))
        utf8.append(contentsOf: [0xF0, 0x9F, 0x92])
        #expect(
            ResourceTextPreviewDecoder.decode(utf8, repairingTruncatedTail: true)
                == "UTF-8 正文"
        )

        var utf16LittleEndian = Data([0xFF, 0xFE])
        utf16LittleEndian.append("UTF-16 LE".data(using: .utf16LittleEndian)!)
        utf16LittleEndian.append(contentsOf: [0x3D, 0xD8])
        #expect(
            ResourceTextPreviewDecoder.decode(
                utf16LittleEndian,
                repairingTruncatedTail: true
            ) == "UTF-16 LE"
        )

        var utf16BigEndian = Data([0xFE, 0xFF])
        utf16BigEndian.append("UTF-16 BE".data(using: .utf16BigEndian)!)
        utf16BigEndian.append(contentsOf: [0xD8, 0x3D])
        #expect(
            ResourceTextPreviewDecoder.decode(
                utf16BigEndian,
                repairingTruncatedTail: true
            ) == "UTF-16 BE"
        )

        var completeUTF16 = Data([0xFF, 0xFE])
        completeUTF16.append("完整😀".data(using: .utf16LittleEndian)!)
        #expect(
            ResourceTextPreviewDecoder.decode(
                completeUTF16,
                repairingTruncatedTail: true
            ) == ViewerContentDecoder.decodeText(completeUTF16)
        )
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

    @Test("新鲜类型解析决定落盘键且不发布到陈旧类型键")
    func freshResolutionOwnsPersistedCacheKey() async throws {
        let pngData = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let revision = ResourceRevision.etag("fresh-image-v1")
        let path = "/预览/asset"
        let fixture = makeFixture(
            kind: .image,
            path: path,
            revision: revision,
            mimeType: "image/png",
            typeIdentifier: "public.png",
            content: pngData,
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        let staleItem = try makeItem(
            sourceID: fixture.source.id,
            path: path,
            kind: .text,
            byteSize: Int64(pngData.count),
            mimeType: "text/plain",
            typeIdentifier: "public.plain-text",
            revision: revision
        )
        let freshItem = try makeItem(
            sourceID: fixture.source.id,
            path: path,
            kind: .image,
            byteSize: Int64(pngData.count),
            mimeType: "image/png",
            typeIdentifier: "public.png",
            revision: revision
        )
        #expect(staleItem.id == freshItem.id)
        #expect(staleItem.resolvedContentType.kind == .text)
        #expect(freshItem.resolvedContentType.kind == .image)
        #expect(
            staleItem.resolvedContentType.stableFingerprint
                != freshItem.resolvedContentType.stableFingerprint
        )

        let staleRequest = try makeRequest(item: staleItem)
        let freshRequest = try makeRequest(item: freshItem)
        let generated = try await fixture.pipeline.preview(for: staleRequest)
        guard case .encodedImage = generated else {
            Issue.record("新鲜图片元数据必须覆盖陈旧文本列表类型")
            return
        }
        var snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)

        let repeatedStaleHit = try await fixture.pipeline.preview(for: staleRequest)
        guard case .encodedImage = repeatedStaleHit else {
            Issue.record("同一管线的陈旧类型别名应返回已验证图片")
            return
        }
        snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)

        let freshPipeline = ResourcePreviewPipeline(
            accessService: fixture.accessService,
            cacheDirectory: cacheDirectory
        )
        let diskHit = try await freshPipeline.preview(for: freshRequest)
        guard case .encodedImage = diskHit else {
            Issue.record("新鲜类型请求应命中已生成的图片磁盘缓存")
            return
        }
        snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)

        let stalePipeline = ResourcePreviewPipeline(
            accessService: fixture.accessService,
            cacheDirectory: cacheDirectory
        )
        let persistedAliasHit = try await stalePipeline.preview(for: staleRequest)
        guard case .encodedImage = persistedAliasHit else {
            Issue.record("陈旧类型请求应通过已验证的持久别名命中图片")
            return
        }
        snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 1)
        #expect(snapshot.readCalls == 1)
    }

    @Test("类型别名仅在请求 revision 与新鲜 revision 相同时建立")
    func resolvedTypeAliasRequiresMatchingRevision() async throws {
        let pngData = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let path = "/预览/revision-changed"
        let fixture = makeFixture(
            kind: .image,
            path: path,
            revision: .etag("stale-v1"),
            resolvedRevision: .etag("fresh-v2"),
            mimeType: "image/png",
            typeIdentifier: "public.png",
            content: pngData,
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        let staleItem = try makeItem(
            sourceID: fixture.source.id,
            path: path,
            kind: .text,
            byteSize: Int64(pngData.count),
            mimeType: "text/plain",
            typeIdentifier: "public.plain-text",
            revision: .etag("stale-v1")
        )
        let staleRequest = try makeRequest(item: staleItem)

        _ = try await fixture.pipeline.preview(for: staleRequest)
        _ = try await fixture.pipeline.preview(for: staleRequest)

        let snapshot = await fixture.adapter.snapshot()
        #expect(snapshot.metadataCalls == 2)
        #expect(snapshot.readCalls == 2)
    }

    @Test("磁盘类型别名不能跨身份 revision 与尺寸作用域命中")
    func rejectsTamperedResolvedTypeAliasOutsideScope() async throws {
        let pngData = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let revision = ResourceRevision.etag("alias-scope-a")
        let path = "/预览/alias-scope-a"
        let first = makeFixture(
            kind: .image,
            path: path,
            revision: revision,
            mimeType: "image/png",
            typeIdentifier: "public.png",
            content: pngData,
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        let staleItem = try makeItem(
            sourceID: first.source.id,
            path: path,
            kind: .text,
            byteSize: Int64(pngData.count),
            mimeType: "text/plain",
            typeIdentifier: "public.plain-text",
            revision: revision
        )
        let staleRequest = try makeRequest(item: staleItem)
        _ = try await first.pipeline.preview(for: staleRequest)

        let second = makeFixture(
            kind: .image,
            path: "/预览/alias-scope-b.png",
            revision: .etag("alias-scope-b"),
            mimeType: "image/png",
            typeIdentifier: "public.png",
            content: pngData,
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        _ = try await second.pipeline.preview(for: makeRequest(item: second.item))

        let entries = try decodeManifestEntries(in: cacheDirectory)
        let alias = try #require(entries.first { $0.value.aliasTargetDigest != nil })
        let originalTarget = try #require(alias.value.aliasTargetDigest)
        let unrelatedTarget = try #require(entries.first { digest, entry in
            digest != alias.key
                && digest != originalTarget
                && entry.aliasTargetDigest == nil
        }?.key)

        let aliasRecordURL = cacheDirectory
            .appendingPathComponent(alias.key + ".preview")
        let aliasRecordData = try Data(contentsOf: aliasRecordURL)
        var propertyListFormat = PropertyListSerialization.PropertyListFormat.binary
        let aliasPropertyList = try PropertyListSerialization.propertyList(
            from: aliasRecordData,
            options: [],
            format: &propertyListFormat
        )
        var aliasRecord = try #require(
            aliasPropertyList as? [String: Any]
        )
        aliasRecord["aliasTargetDigest"] = unrelatedTarget
        let tamperedAliasData = try PropertyListSerialization.data(
            fromPropertyList: aliasRecord,
            format: .binary,
            options: 0
        )
        try tamperedAliasData.write(to: aliasRecordURL, options: .atomic)

        let manifestURL = cacheDirectory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        var manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        var aliasManifestEntry = try #require(manifest[alias.key] as? [String: Any])
        aliasManifestEntry["aliasTargetDigest"] = unrelatedTarget
        manifest[alias.key] = aliasManifestEntry
        let tamperedManifestData = try JSONSerialization.data(withJSONObject: manifest)
        try tamperedManifestData.write(to: manifestURL, options: .atomic)

        let reloaded = ResourcePreviewPipeline(
            accessService: first.accessService,
            cacheDirectory: cacheDirectory
        )
        _ = try await reloaded.preview(for: staleRequest)

        let snapshot = await first.adapter.snapshot()
        #expect(snapshot.metadataCalls == 2)
        #expect(snapshot.readCalls == 2)
    }

    @Test("磁盘命中不阻塞写 manifest 且一个视口只批量持久化一次")
    func batchesDiskHitManifestPersistence() async throws {
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let fixture = makeFixture(
            revision: .etag("batch-v1"),
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        let items = try (0..<4).map { index in
            try makeItem(
                sourceID: fixture.source.id,
                path: "/批量/预览-\(index).txt",
                revision: .etag("batch-v1")
            )
        }
        for item in items {
            _ = try await fixture.pipeline.preview(for: makeRequest(item: item))
        }

        let persistenceSpy = ManifestDataWriterSpy()
        let accessDate = Date(timeIntervalSince1970: 1_800_000_000)
        let diskPipeline = ResourcePreviewPipeline(
            accessService: fixture.accessService,
            cacheDirectory: cacheDirectory,
            accessFlushDelay: .seconds(60),
            currentDate: { accessDate },
            manifestDataWriter: { try persistenceSpy.write($0, to: $1) }
        )
        for item in items {
            _ = try await diskPipeline.preview(for: makeRequest(item: item))
        }

        #expect(persistenceSpy.count == 0)
        #expect(await fixture.adapter.snapshot().readCalls == items.count)

        try await diskPipeline.flushPendingManifestAccesses()
        #expect(persistenceSpy.count == 1)
        try await diskPipeline.flushPendingManifestAccesses()
        #expect(persistenceSpy.count == 1)

        let entries = try decodeManifestEntries(in: cacheDirectory)
        #expect(entries.count == items.count)
        #expect(entries.values.allSatisfy { $0.lastAccess == accessDate })
    }

    @Test("管线析构会持久化最后一批磁盘访问")
    func deinitFlushesLastDiskAccess() async throws {
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let fixture = makeFixture(
            revision: .etag("deinit-v1"),
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        let request = try makeRequest(item: fixture.item)
        _ = try await fixture.pipeline.preview(for: request)

        let persistenceSpy = ManifestDataWriterSpy()
        let accessDate = Date(timeIntervalSince1970: 1_900_000_000)
        try await accessDiskArtifactAndReleasePipeline(
            request: request,
            accessService: fixture.accessService,
            cacheDirectory: cacheDirectory,
            accessDate: accessDate,
            persistenceSpy: persistenceSpy
        )

        #expect(persistenceSpy.count == 1)
        let entries = try decodeManifestEntries(in: cacheDirectory)
        #expect(entries.count == 1)
        #expect(entries.values.first?.lastAccess == accessDate)
        #expect(await fixture.adapter.snapshot().readCalls == 1)
    }

    @Test("自动 flush 失败会保留 dirty 访问并允许确定性重试")
    func failedScheduledFlushRetainsDirtyAccesses() async throws {
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let fixture = makeFixture(
            revision: .etag("retry-v1"),
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        let request = try makeRequest(item: fixture.item)
        _ = try await fixture.pipeline.preview(for: request)
        let originalAccess = try #require(
            decodeManifestEntries(in: cacheDirectory).values.first?.lastAccess
        )

        let writer = ManifestDataWriterSpy(failuresRemaining: 1)
        let retriedAccess = Date(timeIntervalSince1970: 2_000_000_000)
        let pipeline = ResourcePreviewPipeline(
            accessService: fixture.accessService,
            cacheDirectory: cacheDirectory,
            accessFlushDelay: .milliseconds(10),
            currentDate: { retriedAccess },
            manifestDataWriter: { try writer.write($0, to: $1) }
        )
        _ = try await pipeline.preview(for: request)

        #expect(try await waitUntil { writer.count == 1 })
        #expect(
            try decodeManifestEntries(in: cacheDirectory).values.first?.lastAccess
                == originalAccess
        )

        try await pipeline.flushPendingManifestAccesses()
        #expect(writer.count == 2)
        #expect(
            try decodeManifestEntries(in: cacheDirectory).values.first?.lastAccess
                == retriedAccess
        )
        #expect(await fixture.adapter.snapshot().readCalls == 1)
    }

    @Test("removeAll 取消 pending flush 且析构不会写回 manifest")
    func removeAllDiscardsPendingManifestAccesses() async throws {
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let fixture = makeFixture(
            revision: .etag("remove-all-v1"),
            readsReleased: true,
            cacheDirectory: cacheDirectory
        )
        let request = try makeRequest(item: fixture.item)
        _ = try await fixture.pipeline.preview(for: request)

        let writer = ManifestDataWriterSpy()
        try await accessThenRemoveAllAndReleasePipeline(
            request: request,
            accessService: fixture.accessService,
            cacheDirectory: cacheDirectory,
            writer: writer
        )

        #expect(writer.count == 0)
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
        #expect(await fixture.adapter.snapshot().readCalls == 1)
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

    @Test("未知类型缺少大小或超预算时零正文，非法扩展仅探测有界签名")
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
            content: Data(repeating: 0x01, count: 64),
            readsReleased: true
        )
        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            try await invalidExtension.pipeline.preview(
                for: makeRequest(item: invalidExtension.item)
            )
        }
        let invalidExtensionSnapshot = await invalidExtension.adapter.snapshot()
        #expect(invalidExtensionSnapshot.metadataCalls == 1)
        #expect(invalidExtensionSnapshot.readCalls == 1)
        #expect(invalidExtensionSnapshot.readRanges == [nil])
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

    private func accessDiskArtifactAndReleasePipeline(
        request: ResourcePreviewRequest,
        accessService: ResourceAccessService,
        cacheDirectory: URL,
        accessDate: Date,
        persistenceSpy: ManifestDataWriterSpy
    ) async throws {
        let pipeline = ResourcePreviewPipeline(
            accessService: accessService,
            cacheDirectory: cacheDirectory,
            accessFlushDelay: .seconds(60),
            currentDate: { accessDate },
            manifestDataWriter: { try persistenceSpy.write($0, to: $1) }
        )
        _ = try await pipeline.preview(for: request)
    }

    private func accessThenRemoveAllAndReleasePipeline(
        request: ResourcePreviewRequest,
        accessService: ResourceAccessService,
        cacheDirectory: URL,
        writer: ManifestDataWriterSpy
    ) async throws {
        let pipeline = ResourcePreviewPipeline(
            accessService: accessService,
            cacheDirectory: cacheDirectory,
            accessFlushDelay: .seconds(60),
            manifestDataWriter: { try writer.write($0, to: $1) }
        )
        _ = try await pipeline.preview(for: request)
        await pipeline.removeAll()
    }

    private func decodeManifestEntries(
        in cacheDirectory: URL
    ) throws -> [String: PreviewManifestEntry] {
        let data = try Data(
            contentsOf: cacheDirectory.appendingPathComponent("manifest.json")
        )
        return try JSONDecoder().decode([String: PreviewManifestEntry].self, from: data)
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
            mimeType: resolvedMimeType,
            typeIdentifier: resolvedTypeIdentifier,
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
        case .folder, .text: "text/plain"
        case .unknown: "application/octet-stream"
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
        case .text: "public.plain-text"
        case .unknown: "public.data"
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
        mimeType: String? = "text/plain",
        typeIdentifier: String? = "public.plain-text",
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
                mimeType: mimeType,
                typeIdentifier: typeIdentifier,
                revision: revision
            ),
            capabilities: [.read],
            accent: .recommended(for: kind)
        )
    }

    private func makeResolvedItem(
        path: String,
        kind: ResourceKind,
        metadata: ResourceMetadata
    ) throws -> ResourceItem {
        let logicalPath = try #require(ResourcePath(rawValue: path))
        return ResourceItem(
            sourceID: UUID(),
            logicalPath: logicalPath,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: metadata,
            capabilities: kind == .folder ? [.list] : [.read],
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

private struct PreviewManifestEntry: Decodable {
    let lastAccess: Date
    let aliasTargetDigest: String?
}

private enum ManifestDataWriterError: Error {
    case injectedFailure
}

private final class ManifestDataWriterSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var persistenceCount = 0
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return persistenceCount
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        persistenceCount += 1
        let shouldFail = failuresRemaining > 0
        failuresRemaining = max(0, failuresRemaining - 1)
        lock.unlock()

        if shouldFail {
            throw ManifestDataWriterError.injectedFailure
        }
        try data.write(to: url, options: .atomic)
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
