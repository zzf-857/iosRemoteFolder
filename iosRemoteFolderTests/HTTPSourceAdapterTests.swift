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
        #expect(items.map(\.path) == ["/a.pdf", "/b.jpg"])
        #expect(items.allSatisfy { $0.capabilities.contains(.directURL) })
        #expect(items.allSatisfy { !$0.capabilities.contains(.rangeRead) })
        #expect(items.allSatisfy { $0.sourceID == adapter.source.id })
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
            _ = try await adapter.readData(for: unknown, range: nil)
        }
    }

    @Test("跨来源资源映射为 invalidReference")
    func foreignSourceRejected() async throws {
        MockURLProtocol.reset()
        let adapter = makeAdapter(descriptors: [descriptor()])
        let foreign = makeItem(path: "/files/manual.pdf", sourceID: UUID())
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.reference(for: foreign)
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
                    "Last-Modified": "Wed, 06 Aug 2026 08:00:00 GMT"
                ],
                body: Data()
            )
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        let metadata = try await adapter.fetchMetadata(for: items[0])
        #expect(observedMethod.value == "HEAD")
        #expect(metadata.byteSize == 12345)
        #expect(metadata.contentType == "application/pdf")
        #expect(metadata.acceptsRanges)
        #expect(metadata.modifiedAt != nil)
    }

    @Test("HEAD 被拒绝时降级为 Range GET 探测")
    func metadataFallsBackToGET() async throws {
        MockURLProtocol.reset()
        let methods = TestBox<[String]>([])
        MockURLProtocol.register(Self.fileURL) { request in
            let method = request.httpMethod ?? "GET"
            methods.value = methods.value + [method]
            if method == "HEAD" {
                return .respond(status: 405, headers: [:], body: Data())
            }
            return .respond(
                status: 206,
                headers: ["Content-Range": "bytes 0-0/88", "Content-Length": "1"],
                body: Data([0])
            )
        }
        let adapter = makeAdapter(descriptors: [descriptor()])
        let items = try await adapter.listResources()
        let metadata = try await adapter.fetchMetadata(for: items[0])
        #expect(methods.value == ["HEAD", "GET"])
        #expect(metadata.acceptsRanges)
        #expect(metadata.byteSize == 88)
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
        timeout: TimeInterval = 5
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
            timeout: timeout
        )
    }

    private func descriptor(
        path: String = "/files/manual.pdf",
        name: String = "manual.pdf",
        kind: ResourceKind = .pdf,
        headers: [String: String] = [:]
    ) -> HTTPResourceDescriptor {
        HTTPResourceDescriptor(
            path: path,
            name: name,
            kind: kind,
            url: path == "/files/manual.pdf"
                ? Self.fileURL
                : URL(string: "http://resources.test\(path)")!,
            headers: headers
        )
    }

    private func makeItem(path: String, sourceID: UUID) -> ResourceItem {
        ResourceItem(
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: .pdf,
            sourceID: sourceID,
            path: path,
            sizeDescription: "",
            modifiedDescription: "",
            capabilities: [.read],
            accent: .orange
        )
    }
}
