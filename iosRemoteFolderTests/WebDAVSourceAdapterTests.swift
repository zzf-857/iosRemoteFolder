import Foundation
import Testing
import UniformTypeIdentifiers

@testable import iosRemoteFolder

@Suite("WebDAV 来源适配器", .serialized)
struct WebDAVSourceAdapterTests {
    private static let endpoint = URL(string: "https://dav.test/dav/")!
    private static let fileURL = URL(string: "https://dav.test/dav/%E8%B5%84%E6%96%99%20%23%3F%25.txt")!
    private static let fileDirectoryURL = URL(string: "https://dav.test/dav/%E8%B5%84%E6%96%99%20%23%3F%25.txt/")!
    private static let imageURL = URL(string: "https://dav.test/dav/%E5%B0%81%E9%9D%A2.jpg")!
    private static let imageDirectoryURL = URL(string: "https://dav.test/dav/%E5%B0%81%E9%9D%A2.jpg/")!
    private static let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let source = ResourceSource(
        id: sourceID,
        name: "测试 WebDAV",
        kind: .webdav,
        endpoint: endpoint.absoluteString,
        status: .disconnected,
        itemCountDescription: ""
    )

    @Test("PROPFIND 解析 namespace、保留字符路径与 Basic Auth，Range 读取使用文件响应证据")
    func listAndReadPreservePathAndAuthentication() async throws {
        WebDAVMockURLProtocol.reset()
        let observedAuth = TestBox<String?>(nil)
        let observedDepth = TestBox<String?>(nil)
        WebDAVMockURLProtocol.register(Self.endpoint) { request in
            observedAuth.value = request.value(forHTTPHeaderField: "Authorization")
            observedDepth.value = request.value(forHTTPHeaderField: "Depth")
            return .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { request in
            observedAuth.value = request.value(forHTTPHeaderField: "Authorization")
            return .respond(
                status: 206,
                headers: [
                    "Content-Range": "bytes 1-3/5",
                    "Content-Length": "3",
                    "Content-Type": "text/plain"
                ],
                body: Data("bcd".utf8)
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            username: "user",
            password: "pass",
            session: WebDAVMockURLProtocol.makeSession()
        )
        let items = try await adapter.listResources(at: .root)
        let item = try #require(items.first)
        let data = try await adapter.readData(
            for: item,
            range: ResourceByteRange(lowerBound: 1, upperBound: 3)
        )

        #expect(observedDepth.value == "1")
        #expect(observedAuth.value == "Basic dXNlcjpwYXNz")
        #expect(item.path == "/资料 #?%.txt")
        #expect(item.name == "资料 #?%.txt")
        #expect(item.metadata.byteSize == 5)
        #expect(item.metadata.revision == .etag("\"dav-revision\""))
        #expect(!item.capabilities.contains(.rangeRead))
        #expect(data == Data("bcd".utf8))
    }

    @Test("PROPFIND Range header 不证明子文件能力，DAV 与 HTTP 大小冲突必须失败")
    func fileRangeEvidenceRejectsDAVAndHTTPSizeMismatch() async throws {
        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileDirectoryURL) { _ in
            .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: Self.fileResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { request in
            #expect(request.httpMethod == "HEAD")
            return .respond(
                status: 200,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Length": "6",
                    "Content-Type": "text/plain"
                ],
                body: Data()
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            session: WebDAVMockURLProtocol.makeSession()
        )
        let item = try #require(try await adapter.listResources(at: .root).first)
        #expect(!item.metadata.acceptsRanges)
        #expect(!item.capabilities.contains(.rangeRead))
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await adapter.fetchMetadata(for: item)
        }
    }

    @Test("畸形文件 Range 探测回退 DAV 且不声明能力")
    func malformedFileRangeProbeFallsBackWithoutRangeCapability() async throws {
        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileDirectoryURL) { _ in
            .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: Self.fileResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { request in
            if request.httpMethod == "HEAD" {
                return .respond(
                    status: 200,
                    headers: ["Content-Length": "5", "Content-Type": "text/plain"],
                    body: Data()
                )
            }
            return .respond(
                status: 206,
                headers: [
                    "Content-Range": "bytes 1-1/5",
                    "Content-Length": "1",
                    "Content-Type": "text/plain"
                ],
                body: Data("a".utf8)
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            session: WebDAVMockURLProtocol.makeSession()
        )
        let item = try #require(try await adapter.listResources(at: .root).first)
        let metadata = try await adapter.fetchMetadata(for: item)

        #expect(metadata.byteSize == 5)
        #expect(!metadata.acceptsRanges)
    }

    @Test("PROPFIND 元数据与 HTTP 206 探测合并时不把单字节长度当作文件大小")
    func metadataUsesCompleteSizeFromContentRange() async throws {
        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { request in
            let depth = request.value(forHTTPHeaderField: "Depth")
            return .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: depth == "0" ? Self.fileResponse : Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileDirectoryURL) { _ in
            .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: Self.fileResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { request in
            if request.httpMethod == "HEAD" {
                return .respond(status: 405, headers: [:], body: Data())
            }
            return .respond(
                status: 206,
                headers: [
                    "Content-Range": "bytes 0-0/5",
                    "Content-Length": "1",
                    "Content-Type": "text/plain",
                    "Last-Modified": "Wed, 06 Aug 2026 08:00:00 GMT"
                ],
                body: Data("a".utf8)
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            session: WebDAVMockURLProtocol.makeSession()
        )
        let item = try #require(try await adapter.listResources(at: .root).first)
        let metadata = try await adapter.fetchMetadata(for: item)

        #expect(metadata.byteSize == 5)
        #expect(metadata.acceptsRanges)
        #expect(metadata.revision == .etag("\"dav-revision\""))
    }

    @Test("DAV 具体 MIME 不被 Alist 的错误或通用 HTTP MIME 覆盖")
    func metadataKeepsConcreteDAVTypeWhenHTTPTypeIsMisleading() async throws {
        for httpMIMEType in ["text/plain", "application/octet-stream"] {
            WebDAVMockURLProtocol.reset()
            WebDAVMockURLProtocol.register(Self.endpoint) { request in
                let depth = request.value(forHTTPHeaderField: "Depth")
                return .respond(
                    status: 207,
                    headers: ["Content-Type": "application/xml"],
                    body: depth == "0" ? Self.imageFileResponse : Self.imageDirectoryResponse
                )
            }
            WebDAVMockURLProtocol.register(Self.imageDirectoryURL) { _ in
                .respond(
                    status: 207,
                    headers: ["Content-Type": "application/xml"],
                    body: Self.imageFileResponse
                )
            }
            WebDAVMockURLProtocol.register(Self.imageURL) { request in
                #expect(request.httpMethod == "HEAD")
                return .respond(
                    status: 200,
                    headers: [
                        "Accept-Ranges": "bytes",
                        "Content-Length": "256392",
                        "Content-Type": httpMIMEType
                    ],
                    body: Data()
                )
            }

            let adapter = try WebDAVSourceAdapter(
                source: Self.source,
                endpoint: Self.endpoint,
                session: WebDAVMockURLProtocol.makeSession()
            )
            let item = try #require(try await adapter.listResources(at: .root).first)
            let metadata = try await adapter.fetchMetadata(for: item)
            let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

            #expect(item.kind == .image)
            #expect(metadata.byteSize == 256392)
            #expect(metadata.acceptsRanges)
            #expect(metadata.mimeType == "image/jpeg")
            #expect(metadata.typeIdentifier == UTType.jpeg.identifier)
            #expect(resolution.kind == .imageViewer)
            #expect(resolution.fallbackDescription == nil)
        }
    }

    @Test("同一资源的可选属性 404 不覆盖成功 propstat")
    func mixedPropstatStatusesKeepSuccessfulProperties() async throws {
        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: Self.mixedPropstatDirectoryResponse
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            session: WebDAVMockURLProtocol.makeSession()
        )
        let items = try await adapter.listResources(at: .root)
        let folder = try #require(items.first)

        #expect(items.count == 1)
        #expect(folder.name == "共享目录")
        #expect(folder.path == "/共享目录")
        #expect(folder.kind == .folder)
        #expect(folder.metadata.isDirectory)
        #expect(folder.metadata.byteSize == nil)
        #expect(folder.metadata.mimeType == nil)
    }

    @Test("多个成功 propstat 的冲突属性拒绝歧义覆盖")
    func conflictingSuccessfulPropstatsAreRejected() async throws {
        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: Self.conflictingPropstatResponse
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            session: WebDAVMockURLProtocol.makeSession()
        )
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await adapter.listResources(at: .root)
        }
    }

    @Test("非法来源与失败状态保持统一错误语义")
    func invalidEndpointAndHTTPFailuresMapToSourceErrors() async throws {
        #expect(throws: ResourceSourceError.invalidReference) {
            _ = try WebDAVSourceAdapter(
                source: Self.source,
                endpoint: URL(string: "file:///tmp/dav")!
            )
        }

        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .respond(status: 401, headers: [:], body: Data())
        }
        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            session: WebDAVMockURLProtocol.makeSession()
        )
        await #expect(throws: ResourceSourceError.authenticationRequired) {
            try await adapter.connect()
        }
    }

    @Test("重定向只允许同源且仍在 endpoint 根路径内")
    func redirectsStayWithinTrustedRoot() async throws {
        let sameOriginTarget = URL(string: "https://dav.test/dav/redirected/")!
        let crossOriginTarget = URL(string: "https://evil.test/dav/")!
        let escapedRootTarget = URL(string: "https://dav.test/private/")!

        WebDAVMockURLProtocol.reset()
        let sameOriginAuth = TestBox<String?>(nil)
        WebDAVMockURLProtocol.register(Self.endpoint) { request in
            .redirect(status: 307, location: sameOriginTarget)
        }
        WebDAVMockURLProtocol.register(sameOriginTarget) { request in
            sameOriginAuth.value = request.value(forHTTPHeaderField: "Authorization")
            return .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }

        let sameOriginAdapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            username: "user",
            password: "pass",
            session: WebDAVMockURLProtocol.makeSession()
        )
        try await sameOriginAdapter.connect()
        #expect(sameOriginAuth.value == "Basic dXNlcjpwYXNz")

        WebDAVMockURLProtocol.reset()
        let crossOriginReached = TestBox(false)
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .redirect(status: 302, location: crossOriginTarget)
        }
        WebDAVMockURLProtocol.register(crossOriginTarget) { _ in
            crossOriginReached.value = true
            return .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }

        let crossOriginAdapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            username: "user",
            password: "pass",
            session: WebDAVMockURLProtocol.makeSession()
        )
        await #expect(throws: ResourceSourceError.unsafeRedirect) {
            try await crossOriginAdapter.connect()
        }
        #expect(!crossOriginReached.value)

        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .redirect(status: 307, location: escapedRootTarget)
        }
        let escapedRootAdapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            session: WebDAVMockURLProtocol.makeSession()
        )
        await #expect(throws: ResourceSourceError.unsafeRedirect) {
            try await escapedRootAdapter.connect()
        }
    }

    @Test("内容读取可跟随跨 origin 签名地址但不外发来源请求头")
    func delegatedContentReadSanitizesCrossOriginRedirect() async throws {
        let crossOriginTarget = URL(string: "https://cdn.test/object/file.txt?signature=short-lived")!
        WebDAVMockURLProtocol.reset()
        let redirectedAuthorization = TestBox<String?>("not-reached")
        let redirectedRange = TestBox<String?>(nil)
        WebDAVMockURLProtocol.register(Self.endpoint) { request in
            .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
            return .redirect(status: 307, location: crossOriginTarget)
        }
        WebDAVMockURLProtocol.register(crossOriginTarget) { request in
            redirectedAuthorization.value = request.value(forHTTPHeaderField: "Authorization")
            redirectedRange.value = request.value(forHTTPHeaderField: "Range")
            #expect(!request.httpShouldHandleCookies)
            return .respond(status: 206, headers: ["Content-Range": "bytes 0-0/5"], body: Data("a".utf8))
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            username: "user",
            password: "pass",
            session: WebDAVMockURLProtocol.makeSession()
        )
        let item = try #require(try await adapter.listResources(at: .root).first)
        let data = try await adapter.readData(
            for: item,
            range: ResourceByteRange(lowerBound: 0, upperBound: 0)
        )
        #expect(data == Data("a".utf8))
        #expect(redirectedAuthorization.value == nil)
        #expect(redirectedRange.value == "bytes=0-0")
    }

    @Test("Alist 动态 Range 探测在多级外部跳转中持续脱敏")
    func alistRangeProbeStaysSanitizedAcrossMultipleExternalRedirects() async throws {
        let firstTarget = URL(string: "https://edge.storage.test/object/file.txt?signature=first")!
        let finalTarget = URL(string: "https://object.storage.test/object/file.txt?signature=second")!
        WebDAVMockURLProtocol.reset()

        let firstHopMethods = TestBox<[String]>([])
        let firstHopRanges = TestBox<[String?]>([])
        let finalHopMethods = TestBox<[String]>([])
        let finalHopRanges = TestBox<[String?]>([])

        WebDAVMockURLProtocol.register(Self.endpoint) { request in
            let depth = request.value(forHTTPHeaderField: "Depth")
            return .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: depth == "0" ? Self.fileResponse : Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileDirectoryURL) { _ in
            .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: Self.fileResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
            return .redirect(status: 307, location: firstTarget)
        }
        WebDAVMockURLProtocol.register(firstTarget) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(!request.httpShouldHandleCookies)
            firstHopMethods.value.append(request.httpMethod ?? "")
            firstHopRanges.value.append(request.value(forHTTPHeaderField: "Range"))
            return .redirect(status: 307, location: finalTarget)
        }
        WebDAVMockURLProtocol.register(finalTarget) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(!request.httpShouldHandleCookies)
            finalHopMethods.value.append(request.httpMethod ?? "")
            finalHopRanges.value.append(request.value(forHTTPHeaderField: "Range"))
            if request.httpMethod == "HEAD" {
                return .respond(
                    status: 200,
                    headers: [
                        "Content-Length": "5",
                        "Content-Type": "text/plain"
                    ],
                    body: Data()
                )
            }
            return .respond(
                status: 206,
                headers: [
                    "Content-Range": "bytes 0-0/5",
                    "Content-Length": "1",
                    "Content-Type": "text/plain"
                ],
                body: Data("a".utf8)
            )
        }

        let session = WebDAVMockURLProtocol.makeSession()
        if let cookie = HTTPCookie(properties: [
            .domain: ".storage.test",
            .path: "/",
            .name: "session",
            .value: "must-not-leak",
            .secure: "TRUE"
        ]) {
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }
        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            username: "user",
            password: "pass",
            session: session
        )
        let item = try #require(try await adapter.listResources(at: .root).first)
        let metadata = try await adapter.fetchMetadata(for: item)
        let reference = try await adapter.reference(for: item)

        #expect(metadata.byteSize == 5)
        #expect(metadata.acceptsRanges)
        guard case .remoteHTTP(let remote) = reference else {
            Issue.record("预期 WebDAV 文件返回远端 HTTP 引用")
            return
        }
        #expect(remote.supportsRange)
        #expect(firstHopMethods.value == ["HEAD", "GET"])
        #expect(finalHopMethods.value == ["HEAD", "GET"])
        #expect(firstHopRanges.value.count == 2)
        #expect(firstHopRanges.value[0] == nil)
        #expect(firstHopRanges.value[1] == "bytes=0-0")
        #expect(finalHopRanges.value.count == 2)
        #expect(finalHopRanges.value[0] == nil)
        #expect(finalHopRanges.value[1] == "bytes=0-0")
    }

    @Test("内容外跳后拒绝回到可信根恢复认证")
    func delegatedContentRejectsAuthenticatedBounceBack() async throws {
        let externalTarget = URL(string: "https://object.storage.test/file.txt?signature=short-lived")!
        let trustedBounce = URL(string: "https://dav.test/dav/bounced.txt")!
        let trustedBounceReached = TestBox(false)

        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { _ in
            .redirect(status: 307, location: externalTarget)
        }
        WebDAVMockURLProtocol.register(externalTarget) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return .redirect(status: 307, location: trustedBounce)
        }
        WebDAVMockURLProtocol.register(trustedBounce) { _ in
            trustedBounceReached.value = true
            return .respond(
                status: 206,
                headers: ["Content-Range": "bytes 0-0/5"],
                body: Data("a".utf8)
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            username: "user",
            password: "pass",
            session: WebDAVMockURLProtocol.makeSession()
        )
        let item = try #require(try await adapter.listResources(at: .root).first)
        await #expect(throws: ResourceSourceError.unsafeRedirect) {
            _ = try await adapter.readData(
                for: item,
                range: ResourceByteRange(lowerBound: 0, upperBound: 0)
            )
        }
        #expect(!trustedBounceReached.value)
    }

    @Test("外部内容跳转逐 hop 拒绝 HTTPS 降级")
    func delegatedContentRejectsPerHopHTTPSDowngrade() async throws {
        let httpEndpoint = URL(string: "http://dav.test/dav/")!
        let httpFileURL = URL(string: "http://dav.test/dav/%E8%B5%84%E6%96%99%20%23%3F%25.txt")!
        let secureTarget = URL(string: "https://object.storage.test/file.txt?signature=secure")!
        let downgradeTarget = URL(string: "http://object.storage.test/file.txt?signature=exposed")!
        let downgradeReached = TestBox(false)
        let source = ResourceSource(
            id: UUID(),
            name: "HTTP Alist",
            kind: .alist,
            endpoint: httpEndpoint.absoluteString,
            status: .disconnected,
            itemCountDescription: ""
        )

        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(httpEndpoint) { _ in
            .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(httpFileURL) { _ in
            .redirect(status: 307, location: secureTarget)
        }
        WebDAVMockURLProtocol.register(secureTarget) { _ in
            .redirect(status: 307, location: downgradeTarget)
        }
        WebDAVMockURLProtocol.register(downgradeTarget) { _ in
            downgradeReached.value = true
            return .respond(
                status: 206,
                headers: ["Content-Range": "bytes 0-0/5"],
                body: Data("a".utf8)
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: source,
            endpoint: httpEndpoint,
            username: "user",
            password: "pass",
            session: WebDAVMockURLProtocol.makeSession()
        )
        let item = try #require(try await adapter.listResources(at: .root).first)
        await #expect(throws: ResourceSourceError.unsafeRedirect) {
            _ = try await adapter.readData(
                for: item,
                range: ResourceByteRange(lowerBound: 0, upperBound: 0)
            )
        }
        #expect(!downgradeReached.value)
    }

    @Test("HTTPS 来源的内容跳转拒绝降级为 HTTP")
    func delegatedContentReadRejectsHTTPSDowngrade() async throws {
        let downgradeTarget = URL(string: "http://cdn.test/object/file.txt?signature=short-lived")!
        WebDAVMockURLProtocol.reset()
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .respond(
                status: 207,
                headers: ["Accept-Ranges": "bytes", "Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { _ in
            .redirect(status: 302, location: downgradeTarget)
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            username: "user",
            password: "pass",
            session: WebDAVMockURLProtocol.makeSession()
        )
        let item = try #require(try await adapter.listResources(at: .root).first)
        await #expect(throws: ResourceSourceError.unsafeRedirect) {
            _ = try await adapter.readData(
                for: item,
                range: ResourceByteRange(lowerBound: 0, upperBound: 0)
            )
        }
    }

    private static let directoryResponse = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/</d:href>
            <d:propstat><d:prop>
              <d:displayname>dav</d:displayname>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/%E8%B5%84%E6%96%99%20%23%3F%25.txt</d:href>
            <d:propstat><d:prop>
              <d:displayname>资料 #?%.txt</d:displayname>
              <d:resourcetype/>
              <d:getcontentlength>5</d:getcontentlength>
              <d:getlastmodified>Wed, 06 Aug 2026 08:00:00 GMT</d:getlastmodified>
              <d:getetag>"dav-revision"</d:getetag>
              <d:getcontenttype>text/plain</d:getcontenttype>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8
    )

    private static let fileResponse = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/%E8%B5%84%E6%96%99%20%23%3F%25.txt</d:href>
            <d:propstat><d:prop>
              <d:displayname>资料 #?%.txt</d:displayname>
              <d:resourcetype/>
              <d:getcontentlength>5</d:getcontentlength>
              <d:getlastmodified>Wed, 06 Aug 2026 08:00:00 GMT</d:getlastmodified>
              <d:getetag>"dav-revision"</d:getetag>
              <d:getcontenttype>text/plain</d:getcontenttype>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8
    )

    private static let imageDirectoryResponse = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/</d:href>
            <d:propstat><d:prop>
              <d:displayname>dav</d:displayname>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/%E5%B0%81%E9%9D%A2.jpg</d:href>
            <d:propstat><d:prop>
              <d:displayname>封面.jpg</d:displayname>
              <d:resourcetype/>
              <d:getcontentlength>256392</d:getcontentlength>
              <d:getetag>"image-revision"</d:getetag>
              <d:getcontenttype>image/jpeg</d:getcontenttype>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8
    )

    private static let imageFileResponse = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/%E5%B0%81%E9%9D%A2.jpg</d:href>
            <d:propstat><d:prop>
              <d:displayname>封面.jpg</d:displayname>
              <d:resourcetype/>
              <d:getcontentlength>256392</d:getcontentlength>
              <d:getetag>"image-revision"</d:getetag>
              <d:getcontenttype>image/jpeg</d:getcontenttype>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8
    )

    private static let mixedPropstatDirectoryResponse = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>root</d:displayname>
                <d:resourcetype><d:collection/></d:resourcetype>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
            <d:propstat>
              <d:prop><d:getcontenttype/><d:getetag/></d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/%E5%85%B1%E4%BA%AB%E7%9B%AE%E5%BD%95/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>共享目录</d:displayname>
                <d:resourcetype><d:collection/></d:resourcetype>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
            <d:propstat>
              <d:prop><d:getcontentlength/><d:getcontenttype/><d:getetag/></d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8
    )

    private static let conflictingPropstatResponse = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/file.txt</d:href>
            <d:propstat>
              <d:prop><d:displayname>first.txt</d:displayname></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
            <d:propstat>
              <d:prop><d:displayname>second.txt</d:displayname></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8
    )
}

/// WebDAV tests use an isolated protocol because the existing HTTP fixture is
/// intentionally reset by its own suite while suites may run concurrently.
private final class WebDAVMockURLProtocol: URLProtocol {
    enum Outcome: Sendable {
        case respond(status: Int, headers: [String: String], body: Data)
        case redirect(status: Int, location: URL)
    }

    typealias Handler = @Sendable (URLRequest) -> Outcome

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [URL: Handler] = [:]
    private var delivered = false

    static func register(_ url: URL, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[url] = handler
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        defer { lock.unlock() }
        return handlers[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = request.url.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            deliver { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
            return
        }
        switch handler(request) {
        case .respond(let status, let headers, let body):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                deliver { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
                return
            }
            deliver {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        case .redirect(let status, let location):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: "HTTP/1.1",
                      headerFields: ["Location": location.absoluteString]
                  ) else {
                deliver { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
                return
            }
            var redirected = URLRequest(url: location)
            redirected.httpMethod = request.httpMethod
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
            deliver {
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            }
        }
    }

    override func stopLoading() {
        // URLSession may stop the original protocol instance after it asks the
        // task delegate to accept or reject a redirect. Complete that instance
        // so rejected redirects do not linger until the request timeout.
        guard !delivered else { return }
        delivered = true
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    private func deliver(_ body: () -> Void) {
        guard !delivered else { return }
        delivered = true
        body()
    }
}
