import Foundation
import Testing

@testable import iosRemoteFolder

@Suite("HTTP 来源适配器", .serialized)
struct HTTPSourceAdapterTests {
    private static let fileURL = URL(string: "http://resources.test/files/manual.pdf")!

    @Test("列举返回已配置的直链且不预先声称 Range 能力")
    func listingReturnsConfiguredLinks() async throws {
        MockURLProtocol.reset()
        let adapter = makeAdapter(descriptors: [
            descriptor(path: "/a.pdf"),
            descriptor(path: "/b.jpg", name: "b.jpg", kind: .image)
        ])
        let items = try await adapter.listResources()
        #expect(Set(items.map(\.path)) == Set(["/a.pdf", "/b.jpg"]))
        #expect(items.allSatisfy { $0.capabilities.contains(.directURL) })
        #expect(items.allSatisfy { !$0.capabilities.contains(.rangeRead) })
        #expect(items.allSatisfy { $0.sourceID == adapter.source.id })
        #expect(items.allSatisfy { !$0.metadata.isDirectory })
        #expect(items.allSatisfy { $0.metadata.byteSize == nil })
        #expect(items.allSatisfy { $0.metadata.modifiedAt == nil })
        #expect(items.allSatisfy { $0.metadata.mimeType == nil })
        #expect(items.allSatisfy { $0.metadata.revision.isUnknown })
    }

    @Test("无参数列举与根目录列举返回相同稳定身份")
    func noArgumentListingMatchesRootIdentitySet() async throws {
        MockURLProtocol.reset()
        let adapter = makeAdapter(descriptors: [
            descriptor(path: "/a.pdf"),
            descriptor(path: "/b.jpg", name: "b.jpg", kind: .image),
        ])

        let noArgumentItems = try await adapter.listResources()
        let rootItems = try await adapter.listResources(at: .root)

        #expect(Set(noArgumentItems.map(\.id)) == Set(rootItems.map(\.id)))
        #expect(Set(noArgumentItems.map(\.path)) == Set(["/a.pdf", "/b.jpg"]))
    }

    @Test("虚拟目录支持下钻并保持稳定身份")
    func virtualDirectoriesSupportStableDrillDown() async throws {
        MockURLProtocol.reset()
        let adapter = makeAdapter(descriptors: [
            descriptor(path: "/library/manual.pdf"),
            descriptor(path: "/library/images/cover.jpg", name: "cover.jpg", kind: .image),
        ])

        let rootItems = try await adapter.listResources()
        let library = try #require(rootItems.first)
        let libraryPath = try #require(ResourcePath(rawValue: library.path))
        let firstListing = try await adapter.listResources(at: libraryPath)
        let secondListing = try await adapter.listResources(at: libraryPath)
        let images = try #require(firstListing.first { $0.path == "/library/images" })
        let imagesPath = try #require(ResourcePath(rawValue: images.path))
        let imageItems = try await adapter.listResources(at: imagesPath)
        let cover = try #require(imageItems.first)

        #expect(rootItems.map(\.path) == ["/library"])
        #expect(library.kind == .folder)
        #expect(library.metadata.isDirectory)
        #expect(library.metadata.revision.isUnknown)
        #expect(library.capabilities == [.list])
        #expect(firstListing.map(\.path) == ["/library/images", "/library/manual.pdf"])
        #expect(firstListing.map(\.id) == secondListing.map(\.id))
        #expect(
            cover.id == ResourceIdentity(
                sourceID: adapter.source.id,
                logicalPath: ResourcePath(rawValue: "/library/images/cover.jpg")!
            )
        )
    }

    @Test("重复规范化路径与文件目录冲突均被拒绝")
    func conflictingDescriptorPathsRejected() async throws {
        MockURLProtocol.reset()
        let duplicateAdapter = makeAdapter(descriptors: [
            descriptor(path: "//files/./manual.pdf"),
            descriptor(path: "/files/manual.pdf"),
        ])
        let prefixAdapter = makeAdapter(descriptors: [
            descriptor(path: "/a", name: "a"),
            descriptor(path: "/a/b.pdf", name: "b.pdf"),
        ])

        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await duplicateAdapter.listResources()
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await prefixAdapter.listResources()
        }
    }

    @Test("引用携带 URL 与自定义请求头")
    func referenceCarriesHeaders() async throws {
        MockURLProtocol.reset()
        let adapter = makeAdapter(descriptors: [descriptor(headers: ["X-Token": "abc"])])
        let items = try await adapter.listResources()
        let reference = try await adapter.reference(for: items[0])
        guard case .remoteHTTP(let value) = reference else {
            Issue.record("应为 HTTP 引用")
            return
        }
        #expect(value.url == Self.fileURL)
        #expect(value.headers["X-Token"] == "abc")
        #expect(!value.supportsRange)
    }

    @Test("未知资源路径映射为 invalidReference")
    func unknownResourceRejected() async throws {
        MockURLProtocol.reset()
        let adapter = makeAdapter(descriptors: [descriptor()])
        let unknown = makeItem(path: "/not-exist.pdf", sourceID: adapter.source.id)
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.reference(for: unknown)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.fetchMetadata(for: unknown)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.readData(for: unknown, range: nil)
        }
    }

    @Test("跨来源资源被三个文件入口拒绝")
    func foreignSourceRejected() async throws {
        MockURLProtocol.reset()
        let adapter = makeAdapter(descriptors: [descriptor()])
        let foreign = makeItem(path: "/manual.pdf", sourceID: UUID())
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.reference(for: foreign)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.fetchMetadata(for: foreign)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.readData(for: foreign, range: nil)
        }
    }

    @Test("HEAD 探测返回结构化元数据")
    func headMetadata() async throws {
        MockURLProtocol.reset()
        let observedMethod = TestBox<String?>(nil)
        MockURLProtocol.register(Self.fileURL) { request in
            observedMethod.value = request.httpMethod
            return .respond(
                status: 200,
                headers: [
                    "Content-Length": "12345",
                    "Content-Type": "application/pdf",
                    "Accept-Ranges": "bytes",
                    "Last-Modified": "Wed, 06 Aug 2026 08:00:00 GMT",
                    "ETag": "W/\"revision-7\""
                ],
                body: Data()
            )
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        let metadata = try await adapter.fetchMetadata(for: items[0])
        #expect(observedMethod.value == "HEAD")
        #expect(metadata.byteSize == 12345)
        #expect(metadata.mimeType == "application/pdf")
        #expect(metadata.typeIdentifier != nil)
        #expect(!metadata.isDirectory)
        #expect(metadata.acceptsRanges)
        #expect(metadata.modifiedAt != nil)
        #expect(metadata.revision == .etag("W/\"revision-7\""))
    }

    @Test("HTTP 服务端版本优先于修改时间与大小")
    func serverVersionMetadata() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(
                status: 200,
                headers: [
                    "Content-Length": "12345",
                    "Last-Modified": "Wed, 06 Aug 2026 08:00:00 GMT",
                    "X-Resource-Version": "opaque-version-9"
                ],
                body: Data()
            )
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let item = try #require(try await adapter.listResources().first)
        let metadata = try await adapter.fetchMetadata(for: item)

        #expect(metadata.revision == .serverVersion("opaque-version-9"))
    }

    @Test("HEAD 405 或 501 时降级为 Range GET 探测")
    func metadataFallsBackToGET() async throws {
        for rejectedHeadStatus in [405, 501] {
            MockURLProtocol.reset()
            let methods = TestBox<[String]>([])
            MockURLProtocol.register(Self.fileURL) { request in
                let method = request.httpMethod ?? "GET"
                methods.value = methods.value + [method]
                if method == "HEAD" {
                    return .respond(status: rejectedHeadStatus, headers: [:], body: Data())
                }
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-0")
                return .respond(
                    status: 206,
                    headers: [
                        "Content-Range": "bytes 0-0/88",
                        "Content-Length": "1",
                        "Content-Type": "application/pdf",
                        "Last-Modified": "Wed, 06 Aug 2026 08:00:00 GMT"
                    ],
                    body: Data([0])
                )
            }
            let adapter = makeAdapter(descriptors: [descriptor()])
            let item = try #require(try await adapter.listResources().first)
            let metadata = try await adapter.fetchMetadata(for: item)
            #expect(methods.value == ["HEAD", "GET"])
            #expect(metadata.acceptsRanges)
            #expect(metadata.byteSize == 88)
            #expect(metadata.mimeType == "application/pdf")
            guard case .modifiedAndSize(let modifiedAt, let byteSize) = metadata.revision else {
                Issue.record("合法 206 探测应使用完整大小形成 metadata revision")
                continue
            }
            #expect(modifiedAt == metadata.modifiedAt)
            #expect(byteSize == 88)
        }
    }

    @Test("HEAD 200 未声明 Range 时使用合法 206 合并元数据与能力")
    func successfulHeadPerformsRangeProbe() async throws {
        MockURLProtocol.reset()
        let methods = TestBox<[String]>([])
        let ranges = TestBox<[String?]>([])
        MockURLProtocol.register(Self.fileURL) { request in
            methods.value = methods.value + [request.httpMethod ?? "GET"]
            ranges.value = ranges.value + [request.value(forHTTPHeaderField: "Range")]
            if request.httpMethod == "HEAD" {
                return .respond(
                    status: 200,
                    headers: [
                        "Content-Length": "88",
                        "Content-Type": "audio/mpeg",
                        "ETag": "\"head-version\""
                    ],
                    body: Data()
                )
            }
            return .respond(
                status: 206,
                headers: [
                    "Content-Range": "bytes 0-0/88",
                    "Content-Length": "1",
                    "Content-Type": "application/octet-stream"
                ],
                body: Data([0x49])
            )
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let item = try #require(try await adapter.listResources().first)
        let metadata = try await adapter.fetchMetadata(for: item)
        let reference = try await adapter.reference(for: item)

        #expect(methods.value == ["HEAD", "GET"])
        #expect(ranges.value.count == 2)
        #expect(ranges.value[0] == nil)
        #expect(ranges.value[1] == "bytes=0-0")
        #expect(metadata.acceptsRanges)
        #expect(metadata.byteSize == 88)
        #expect(metadata.mimeType == "audio/mpeg")
        #expect(metadata.revision == .etag("\"head-version\""))
        guard case .remoteHTTP(let value) = reference else {
            Issue.record("应为 HTTP 引用")
            return
        }
        #expect(value.supportsRange)
    }

    @Test("Range 探测收到 200 时保留 HEAD 元数据但不声明能力")
    func ignoredRangeProbeRemainsConservative() async throws {
        MockURLProtocol.reset()
        let observedRange = TestBox<String?>(nil)
        MockURLProtocol.register(Self.fileURL) { request in
            if request.httpMethod == "HEAD" {
                return .respond(
                    status: 200,
                    headers: ["Content-Length": "4096", "Content-Type": "application/pdf"],
                    body: Data()
                )
            }
            observedRange.value = request.value(forHTTPHeaderField: "Range")
            return .respond(
                status: 200,
                headers: ["Content-Length": "4096"],
                body: Data(repeating: 0x2A, count: 64)
            )
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let item = try #require(try await adapter.listResources().first)
        let metadata = try await adapter.fetchMetadata(for: item)
        let reference = try await adapter.reference(for: item)

        #expect(observedRange.value == "bytes=0-0")
        #expect(metadata.byteSize == 4096)
        #expect(metadata.mimeType == "application/pdf")
        #expect(!metadata.acceptsRanges)
        guard case .remoteHTTP(let value) = reference else {
            Issue.record("应为 HTTP 引用")
            return
        }
        #expect(!value.supportsRange)
    }

    @Test("Range 探测收到 416 时清除陈旧能力")
    func unsatisfiedRangeProbeClearsStaleCapability() async throws {
        MockURLProtocol.reset()
        let requestCount = TestBox(0)
        MockURLProtocol.register(Self.fileURL) { request in
            requestCount.value += 1
            switch requestCount.value {
            case 1:
                return .respond(status: 200, headers: ["Accept-Ranges": "bytes"], body: Data())
            case 2:
                return .respond(status: 200, headers: ["Content-Length": "88"], body: Data())
            default:
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-0")
                return .respond(status: 416, headers: ["Content-Range": "bytes */88"], body: Data())
            }
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let item = try #require(try await adapter.listResources().first)

        _ = try await adapter.fetchMetadata(for: item)
        let firstReference = try await adapter.reference(for: item)
        let metadata = try await adapter.fetchMetadata(for: item)
        let secondReference = try await adapter.reference(for: item)

        guard case .remoteHTTP(let first) = firstReference,
              case .remoteHTTP(let second) = secondReference else {
            Issue.record("应为 HTTP 引用")
            return
        }
        #expect(first.supportsRange)
        #expect(!metadata.acceptsRanges)
        #expect(metadata.byteSize == 88)
        #expect(!second.supportsRange)
    }

    @Test("畸形 206 探测返回协议错误并清除陈旧能力")
    func malformedProbeDoesNotAdvertiseRange() async throws {
        MockURLProtocol.reset()
        let requestCount = TestBox(0)
        MockURLProtocol.register(Self.fileURL) { request in
            requestCount.value += 1
            switch requestCount.value {
            case 1:
                return .respond(status: 200, headers: ["Accept-Ranges": "bytes"], body: Data())
            case 2:
                return .respond(status: 200, headers: ["Content-Length": "88"], body: Data())
            default:
                #expect(request.httpMethod == "GET")
                return .respond(
                    status: 206,
                    headers: ["Content-Range": "bytes 0-0/*", "Content-Length": "1"],
                    body: Data([0])
                )
            }
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let item = try #require(try await adapter.listResources().first)

        _ = try await adapter.fetchMetadata(for: item)
        let firstReference = try await adapter.reference(for: item)
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await adapter.fetchMetadata(for: item)
        }
        let secondReference = try await adapter.reference(for: item)

        guard case .remoteHTTP(let first) = firstReference,
              case .remoteHTTP(let second) = secondReference else {
            Issue.record("应为 HTTP 引用")
            return
        }
        #expect(first.supportsRange)
        #expect(!second.supportsRange)
    }

    @Test("连接探测成功")
    func connectSucceeds() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(status: 200, headers: [:], body: Data())
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        try await adapter.connect()
    }

    @Test("规范化路径复用连接探测的 Range 能力证据")
    func canonicalPathReusesRangeCapabilityEvidence() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { request in
            #expect(request.httpMethod == "HEAD")
            return .respond(status: 200, headers: ["Accept-Ranges": "bytes"], body: Data())
        }
        let adapter = makeAdapter(descriptors: [
            descriptor(path: "//files/./manual.pdf", url: Self.fileURL),
        ])

        #expect(adapter.descriptors.map(\.path) == ["/files/manual.pdf"])
        try await adapter.connect()
        let filesPath = try #require(ResourcePath(rawValue: "/files"))
        let fileItems = try await adapter.listResources(at: filesPath)
        let item = try #require(fileItems.first)
        let reference = try await adapter.reference(for: item)

        guard case .remoteHTTP(let value) = reference else {
            Issue.record("应为 HTTP 引用")
            return
        }
        #expect(item.path == "/files/manual.pdf")
        #expect(value.supportsRange)
    }

    @Test("成功 HEAD 会清除陈旧的 Range 能力")
    func headProbeClearsStaleRangeCapability() async throws {
        MockURLProtocol.reset()
        let requestCount = TestBox(0)
        MockURLProtocol.register(Self.fileURL) { _ in
            requestCount.value += 1
            if requestCount.value == 1 {
                return .respond(status: 200, headers: ["Accept-Ranges": "bytes"], body: Data())
            }
            return .respond(status: 200, headers: [:], body: Data())
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()

        try await adapter.connect()
        let firstReference = try await adapter.reference(for: items[0])
        try await adapter.connect()
        let secondReference = try await adapter.reference(for: items[0])

        guard case .remoteHTTP(let first) = firstReference,
              case .remoteHTTP(let second) = secondReference else {
            Issue.record("应为 HTTP 引用")
            return
        }
        #expect(first.supportsRange)
        #expect(!second.supportsRange)
    }

    @Test("没有配置直链时连接不发起网络请求")
    func connectWithoutDescriptors() async throws {
        MockURLProtocol.reset()
        let adapter = makeAdapter(descriptors: [])
        // 未注册任何处理器；一旦发起请求就会失败，因此成功即代表无网络请求。
        try await adapter.connect()
        let items = try await adapter.listResources()
        #expect(items.isEmpty)
    }

    @Test("连接探测失败映射为网络不可用")
    func connectFailureMapped() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in .fail(.cannotConnectToHost) }
        let adapter = makeAdapter(descriptors: [descriptor()])
        await #expect(throws: ResourceSourceError.networkUnavailable) {
            try await adapter.connect()
        }
    }

    @Test("GET 完整读取")
    func fullRead() async throws {
        MockURLProtocol.reset()
        let body = Data("完整内容".utf8)
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(status: 200, headers: ["Content-Type": "application/pdf"], body: body)
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        let data = try await adapter.readData(for: items[0], range: nil)
        #expect(data == body)
    }

    @Test("Range 请求发送正确的请求头并返回 206 分片")
    func rangedRead206() async throws {
        MockURLProtocol.reset()
        let full = Data("0123456789".utf8)
        let observedRange = TestBox<String?>(nil)
        MockURLProtocol.register(Self.fileURL) { request in
            observedRange.value = request.value(forHTTPHeaderField: "Range")
            guard request.value(forHTTPHeaderField: "Range") == "bytes=2-5" else {
                return .respond(status: 400, headers: [:], body: Data())
            }
            return .respond(
                status: 206,
                headers: ["Content-Range": "bytes 2-5/10"],
                body: full.subdata(in: 2..<6)
            )
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        let data = try await adapter.readData(
            for: items[0],
            range: ResourceByteRange(lowerBound: 2, upperBound: 5)
        )
        #expect(String(decoding: data, as: UTF8.self) == "2345")
        #expect(observedRange.value == "bytes=2-5")
    }

    @Test("会话快照 Range 要求 206 总长度一致并拒绝 200 回退")
    func snapshotRangeRejectsChangedRepresentation() async throws {
        let requestedRange = ResourceByteRange(lowerBound: 2, upperBound: 5)

        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(
                status: 206,
                headers: ["Content-Range": "bytes 2-5/10"],
                body: Data("2345".utf8)
            )
        }
        var adapter = makeAdapter(descriptors: [descriptor()])
        var listedItem = try #require(try await adapter.listResources().first)
        var snapshotItem = item(
            listedItem,
            metadata: ResourceMetadata(byteSize: 10, acceptsRanges: true)
        )
        let valid = try await adapter.readData(for: snapshotItem, range: requestedRange)
        #expect(valid == Data("2345".utf8))

        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(
                status: 206,
                headers: ["Content-Range": "bytes 2-5/11"],
                body: Data("2345".utf8)
            )
        }
        adapter = makeAdapter(descriptors: [descriptor()])
        listedItem = try #require(try await adapter.listResources().first)
        snapshotItem = item(
            listedItem,
            metadata: ResourceMetadata(byteSize: 10, acceptsRanges: true)
        )
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await adapter.readData(for: snapshotItem, range: requestedRange)
        }

        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(status: 200, headers: ["Content-Length": "10"], body: Data("0123456789".utf8))
        }
        adapter = makeAdapter(descriptors: [descriptor()])
        listedItem = try #require(try await adapter.listResources().first)
        snapshotItem = item(
            listedItem,
            metadata: ResourceMetadata(byteSize: 10, acceptsRanges: true)
        )
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await adapter.readData(for: snapshotItem, range: requestedRange)
        }
    }

    @Test("服务器忽略 Range 时在本地切片降级")
    func rangedReadFallsBackToLocalSlice() async throws {
        MockURLProtocol.reset()
        let full = Data("0123456789".utf8)
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(status: 200, headers: [:], body: full)
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        let data = try await adapter.readData(
            for: items[0],
            range: ResourceByteRange(lowerBound: 2, upperBound: 5)
        )
        #expect(String(decoding: data, as: UTF8.self) == "2345")
    }

    @Test("Range 200 回退在预算边界抛出超限")
    func rangedReadFallbackHonorsBudgetBoundary() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(status: 200, headers: [:], body: Data([0, 1, 2, 3]))
        }
        let adapter = makeAdapter(descriptors: [descriptor()], maxRangeFallbackBytes: 3)
        let items = try await adapter.listResources()

        await #expect(throws: ResourceSourceError.responseTooLarge) {
            _ = try await adapter.readData(
                for: items[0],
                range: ResourceByteRange(lowerBound: 3, upperBound: 3)
            )
        }
    }

    @Test("区间超出内容时截断到可用部分")
    func rangedReadBeyondEnd() async throws {
        MockURLProtocol.reset()
        let full = Data("0123".utf8)
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(status: 200, headers: [:], body: full)
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        let data = try await adapter.readData(
            for: items[0],
            range: ResourceByteRange(lowerBound: 2, upperBound: 99)
        )
        #expect(String(decoding: data, as: UTF8.self) == "23")
    }

    @Test("非 2xx 状态码映射为可行动错误")
    func statusMapping() async throws {
        let cases: [(Int, ResourceSourceError)] = [
            (401, .authenticationRequired),
            (403, .permissionDenied),
            (404, .notFound),
            (500, .httpStatus(500))
        ]
        for (status, expected) in cases {
            MockURLProtocol.reset()
            MockURLProtocol.register(Self.fileURL) { _ in
                .respond(status: status, headers: [:], body: Data())
            }
            let adapter = makeAdapter(descriptors: [descriptor()])
            let items = try await adapter.listResources()
            await #expect(throws: expected) {
                _ = try await adapter.readData(for: items[0], range: nil)
            }
        }
    }

    @Test("超时与断网映射")
    func networkErrorMapping() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in .fail(.timedOut) }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        await #expect(throws: ResourceSourceError.timedOut) {
            _ = try await adapter.readData(for: items[0], range: nil)
        }

        MockURLProtocol.register(Self.fileURL) { _ in .fail(.notConnectedToInternet) }
        await #expect(throws: ResourceSourceError.networkUnavailable) {
            _ = try await adapter.fetchMetadata(for: items[0])
        }
    }

    @Test("任务取消映射为 cancelled")
    func cancellationMapped() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(Self.fileURL) { _ in .hang }
        let adapter = makeAdapter(descriptors: [descriptor()], timeout: 30)
        let items = try await adapter.listResources()
        let task = Task {
            try await adapter.readData(for: items[0], range: nil)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await task.value
        }
    }

    @Test("重定向跟随到最终资源")
    func redirectFollowed() async throws {
        MockURLProtocol.reset()
        let finalURL = URL(string: "http://cdn.test/files/manual.pdf")!
        let body = Data("redirected".utf8)
        MockURLProtocol.register(Self.fileURL) { _ in
            .respond(status: 302, headers: ["Location": finalURL.absoluteString], body: Data())
        }
        MockURLProtocol.register(finalURL) { _ in
            .respond(status: 200, headers: [:], body: body)
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        let data = try await adapter.readData(for: items[0], range: nil)
        #expect(data == body)
    }

    @Test("描述符请求头随每次请求发出")
    func descriptorHeadersSent() async throws {
        MockURLProtocol.reset()
        let observedAuth = TestBox<String?>(nil)
        MockURLProtocol.register(Self.fileURL) { request in
            observedAuth.value = request.value(forHTTPHeaderField: "Authorization")
            return .respond(status: 200, headers: [:], body: Data())
        }
        let adapter = makeAdapter(descriptors: [
            descriptor(headers: ["Authorization": "Bearer fixture-token"])
        ])
        let items = try await adapter.listResources()
        _ = try await adapter.readData(for: items[0], range: nil)
        #expect(observedAuth.value == "Bearer fixture-token")
    }

    // MARK: - Helpers

    private func makeAdapter(
        descriptors: [HTTPResourceDescriptor],
        timeout: TimeInterval = 5,
        maxRangeFallbackBytes: Int64 = HTTPSourceAdapter.defaultMaxRangeFallbackBytes
    ) -> HTTPSourceAdapter {
        let source = ResourceSource(
            id: UUID(),
            name: "测试直链来源",
            kind: .http,
            endpoint: "http://resources.test",
            status: .disconnected,
            itemCountDescription: ""
        )
        return HTTPSourceAdapter(
            source: source,
            descriptors: descriptors,
            session: MockURLProtocol.makeSession(),
            timeout: timeout,
            maxRangeFallbackBytes: maxRangeFallbackBytes
        )
    }

    private func descriptor(
        path: String = "/manual.pdf",
        name: String = "manual.pdf",
        kind: ResourceKind = .pdf,
        url: URL? = nil,
        headers: [String: String] = [:]
    ) -> HTTPResourceDescriptor {
        HTTPResourceDescriptor(
            path: path,
            name: name,
            kind: kind,
            url: url ?? Self.fileURL,
            headers: headers
        )
    }

    private func makeItem(path: String, sourceID: UUID) -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: .pdf,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .orange
        )
    }

    private func item(
        _ item: ResourceItem,
        metadata: ResourceMetadata
    ) -> ResourceItem {
        ResourceItem(
            sourceID: item.sourceID,
            logicalPath: ResourcePath(rawValue: item.path)!,
            name: item.name,
            kind: item.kind,
            metadata: metadata,
            capabilities: item.capabilities.union(.rangeRead),
            accent: item.accent
        )
    }
}
