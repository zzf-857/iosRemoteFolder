import AVFoundation
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

    @Test("跨 origin 内容跳转保留 Range 但剥离 If-Range")
    func crossOriginContentRedirectDropsIfRange() async throws {
        let crossOriginTarget = URL(string: "https://cdn.test/object/file.txt?signature=short-lived")!
        WebDAVMockURLProtocol.reset()
        let originIfRange = TestBox<String?>(nil)
        let redirectedIfRange = TestBox<String?>("unset")
        let redirectedRange = TestBox<String?>(nil)
        let redirectedEncoding = TestBox<String?>(nil)
        WebDAVMockURLProtocol.register(Self.endpoint) { _ in
            .respond(
                status: 207,
                headers: ["Content-Type": "application/xml"],
                body: Self.directoryResponse
            )
        }
        WebDAVMockURLProtocol.register(Self.fileURL) { request in
            originIfRange.value = request.value(forHTTPHeaderField: "If-Range")
            return .redirect(status: 307, location: crossOriginTarget)
        }
        WebDAVMockURLProtocol.register(crossOriginTarget) { request in
            redirectedIfRange.value = request.value(forHTTPHeaderField: "If-Range")
            redirectedRange.value = request.value(forHTTPHeaderField: "Range")
            redirectedEncoding.value = request.value(forHTTPHeaderField: "Accept-Encoding")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return .respond(
                status: 206,
                headers: ["Content-Range": "bytes 0-1/5", "Content-Length": "2"],
                body: Data("ab".utf8)
            )
        }

        let adapter = try WebDAVSourceAdapter(
            source: Self.source,
            endpoint: Self.endpoint,
            username: "user",
            password: "pass",
            session: WebDAVMockURLProtocol.makeSession()
        )
        let listed = try #require(try await adapter.listResources(at: .root).first)
        let snapshotItem = ResourceItem(
            sourceID: listed.sourceID,
            logicalPath: ResourcePath(rawValue: listed.path)!,
            name: listed.name,
            kind: listed.kind,
            metadata: ResourceMetadata(
                byteSize: 5,
                acceptsRanges: true,
                revision: .etag("\"dav-revision\"")
            ),
            capabilities: listed.capabilities.union(.rangeRead),
            accent: listed.accent
        )
        let data = try await adapter.readData(
            for: snapshotItem,
            range: ResourceByteRange(lowerBound: 0, upperBound: 1)
        )
        #expect(data == Data("ab".utf8))
        #expect(originIfRange.value == "\"dav-revision\"")
        #expect(redirectedIfRange.value == nil)
        #expect(redirectedRange.value == "bytes=0-1")
        // Accept-Encoding 属于传输语义：identity 合同必须跨越 origin 边界。
        #expect(redirectedEncoding.value == "identity")
    }

    @Test("redirect 拒绝只归属到触发它的请求记录器")
    func requestScopedRedirectAttributionStaysPerRequest() async throws {
        final class RejectAllPolicy: NSObject,
            URLSessionTaskDelegate,
            HTTPRedirectFailureReporting,
            @unchecked Sendable {
            func consumeUnsafeRedirect() -> Bool { false }

            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                willPerformHTTPRedirection response: HTTPURLResponse,
                newRequest request: URLRequest,
                completionHandler: @escaping @Sendable (URLRequest?) -> Void
            ) {
                completionHandler(nil)
            }

            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                didCompleteWithError error: (any Error)?
            ) {}
        }

        let policy = RejectAllPolicy()
        let reporterA = RequestScopedRedirectReporter(policy: policy)
        let reporterB = RequestScopedRedirectReporter(policy: policy)
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "https://origin.test/resource")!
        let task = session.dataTask(with: url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://elsewhere.test/"]
        ))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            reporterA.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: "https://elsewhere.test/")!)
            ) { decision in
                #expect(decision == nil)
                continuation.resume()
            }
        }
        #expect(reporterA.consumeUnsafeRedirect())
        #expect(!reporterA.consumeUnsafeRedirect())
        #expect(!reporterB.consumeUnsafeRedirect())
        task.cancel()
    }

    @Test(
        "回环真实网络栈：Alist 形态大媒体经外跳完成流式播放、seek 与脱敏",
        .timeLimit(.minutes(2))
    )
    @MainActor
    func loopbackLargeMediaStreamsThroughRealNetworkStack() async throws {
        let media = Self.makeLoopbackWAV(secondsOfAudio: 750)
        let totalSize = media.count
        #expect(totalSize > 8 * 1024 * 1024)

        let signedAuthHeaders = TestBox<[String?]>([])
        let signedIfRangeHeaders = TestBox<[String?]>([])
        let signedCookieHeaders = TestBox<[String?]>([])
        let signedRanges = TestBox<[ResourceByteRange]>([])
        let requestLog = TestBox<[String]>([])

        // 模拟 Alist 外部签名存储主机：不同端口即不同 origin。
        let signedServer = try LoopbackHTTPServer { request in
            requestLog.value.append("B \(request.method) \(request.target)")
            guard request.method == "GET",
                  request.target.hasPrefix("/signed/loopback-large.wav") else {
                return .init(status: 404)
            }
            signedAuthHeaders.value.append(request.header("authorization"))
            signedIfRangeHeaders.value.append(request.header("if-range"))
            signedCookieHeaders.value.append(request.header("cookie"))
            guard let range = Self.parseByteRange(
                request.header("range"),
                totalLength: totalSize
            ) else {
                return .init(status: 416)
            }
            signedRanges.value.append(range)
            let slice = media.subdata(
                in: Int(range.lowerBound)..<(Int(range.upperBound) + 1)
            )
            return .init(
                status: 206,
                headers: [
                    "Content-Type": "audio/wav",
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(totalSize)",
                    // 与 DAV etag 不同：证明跨 origin 响应不参与快照 validator 比较。
                    "ETag": "\"signed-copy-v9\""
                ],
                body: slice
            )
        }
        defer { signedServer.stop() }

        let originIfRangeHeaders = TestBox<[String?]>([])
        let signedLocation = "http://127.0.0.1:\(signedServer.port)/signed/loopback-large.wav?sig=fixture"
        let davServer = try LoopbackHTTPServer { request in
            requestLog.value.append("A \(request.method) \(request.target)")
            switch (request.method, request.target) {
            case ("PROPFIND", "/dav/"), ("PROPFIND", "/dav"):
                return .init(
                    status: 207,
                    headers: ["Content-Type": "application/xml"],
                    body: Self.loopbackDirectoryXML(size: totalSize)
                )
            // 适配器的 PROPFIND 统一使用目录形式 URL（带尾斜杠）。
            case ("PROPFIND", "/dav/loopback-large.wav"),
                 ("PROPFIND", "/dav/loopback-large.wav/"):
                return .init(
                    status: 207,
                    headers: ["Content-Type": "application/xml"],
                    body: Self.loopbackFileXML(size: totalSize)
                )
            case ("HEAD", "/dav/loopback-large.wav"):
                // 与真实 Alist 一致：HEAD 报大小但不声明 Range。
                return .init(
                    status: 200,
                    headers: [
                        "Content-Type": "audio/wav",
                        "Content-Length": "\(totalSize)"
                    ]
                )
            case ("GET", "/dav/loopback-large.wav"):
                originIfRangeHeaders.value.append(request.header("if-range"))
                return .init(status: 302, headers: ["Location": signedLocation])
            default:
                return .init(status: 404)
            }
        }
        defer { davServer.stop() }

        let endpoint = try #require(URL(string: "http://127.0.0.1:\(davServer.port)/dav/"))
        let source = ResourceSource(
            id: UUID(),
            name: "回环 Alist",
            kind: .alist,
            endpoint: endpoint.absoluteString,
            status: .disconnected,
            itemCountDescription: ""
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 10
        let adapter = try WebDAVSourceAdapter(
            source: source,
            endpoint: endpoint,
            username: "user",
            password: "pass",
            session: URLSession(configuration: sessionConfiguration)
        )
        let registry = try SourceRegistry(sources: [source], adapters: [adapter])

        do {
            try await runLoopbackPlaybackFlow(
                adapter: adapter,
                registry: registry,
                totalSize: totalSize,
                signedRanges: signedRanges,
                signedAuthHeaders: signedAuthHeaders,
                signedIfRangeHeaders: signedIfRangeHeaders,
                signedCookieHeaders: signedCookieHeaders,
                originIfRangeHeaders: originIfRangeHeaders
            )
        } catch {
            Issue.record("回环流程失败：\(error)；请求轨迹：\(requestLog.value)")
            throw error
        }
    }

    @MainActor
    private func runLoopbackPlaybackFlow(
        adapter: WebDAVSourceAdapter,
        registry: SourceRegistry,
        totalSize: Int,
        signedRanges: TestBox<[ResourceByteRange]>,
        signedAuthHeaders: TestBox<[String?]>,
        signedIfRangeHeaders: TestBox<[String?]>,
        signedCookieHeaders: TestBox<[String?]>,
        originIfRangeHeaders: TestBox<[String?]>
    ) async throws {
        let item = try #require(try await adapter.listResources(at: .root).first)
        #expect(item.metadata.byteSize == Int64(totalSize))

        let session = try await ResourceAccessService(registry: registry).makeSession(for: item)
        let metadata = try await session.fetchMetadata()
        #expect(metadata.acceptsRanges)
        #expect(metadata.byteSize == Int64(totalSize))
        #expect(metadata.revision == .etag("\"loopback-v1\""))

        let engine = try AVMediaPlayerEngine(
            session: session,
            metadata: metadata,
            resourcePath: item.path
        )
        try await engine.prepare(expectedMediaType: .audio)
        #expect(engine.duration > 600)
        #expect(engine.play())
        try await Task.sleep(for: .milliseconds(300))
        engine.seek(to: engine.duration * 0.85)
        _ = engine.play()

        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if signedRanges.value.contains(where: { $0.upperBound >= Int64(totalSize / 2) }) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        engine.pause()

        let ranges = signedRanges.value
        #expect(!ranges.isEmpty)
        #expect(ranges.allSatisfy { ($0.validatedLength ?? .max) <= 4 * 1024 * 1024 })
        #expect(ranges.contains { $0.upperBound >= Int64(totalSize / 2) })
        // 脱敏：外部签名主机绝不接收来源凭证、Cookie 或 DAV validator。
        #expect(signedAuthHeaders.value.allSatisfy { $0 == nil })
        #expect(signedIfRangeHeaders.value.allSatisfy { $0 == nil })
        #expect(signedCookieHeaders.value.allSatisfy { $0 == nil })
        // 同源 origin 的分片请求携带快照强 ETag 的 If-Range。
        #expect(originIfRangeHeaders.value.contains("\"loopback-v1\""))

        engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await session.fetchMetadata()
        }
    }

    /// 以 1 秒 PCM 块拼接生成指定时长的标准 WAV，头部块大小与总长一致。
    private static func makeLoopbackWAV(secondsOfAudio: Int) -> Data {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = UInt32(channels * bitsPerSample / 8)
        let frameCount = UInt32(secondsOfAudio) * sampleRate
        let dataSize = frameCount * blockAlign

        var header = Data()
        func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var littleEndianValue = value.littleEndian
            withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
        }
        header.append(contentsOf: Data("RIFF".utf8))
        appendLittleEndian(UInt32(36) + dataSize, to: &header)
        header.append(contentsOf: Data("WAVE".utf8))
        header.append(contentsOf: Data("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(channels, to: &header)
        appendLittleEndian(sampleRate, to: &header)
        appendLittleEndian(sampleRate * blockAlign, to: &header)
        appendLittleEndian(UInt16(blockAlign), to: &header)
        appendLittleEndian(bitsPerSample, to: &header)
        header.append(contentsOf: Data("data".utf8))
        appendLittleEndian(dataSize, to: &header)

        // 预生成 1 秒 400Hz 正弦块（周期整除采样率，块间无相位断裂），重复拼接。
        var secondBlock = Data()
        secondBlock.reserveCapacity(Int(sampleRate) * Int(blockAlign))
        let amplitude = Double(Int16.max) * 0.2
        for frame in 0..<Int(sampleRate) {
            let phase = 2 * Double.pi * 400 * Double(frame) / Double(sampleRate)
            appendLittleEndian(Int16(sin(phase) * amplitude), to: &secondBlock)
        }

        var wav = header
        wav.reserveCapacity(header.count + Int(dataSize))
        for _ in 0..<secondsOfAudio {
            wav.append(secondBlock)
        }
        return wav
    }

    /// 解析 `bytes=a-b` 请求头；只接受显式双边界且落在总长内的区间。
    private static func parseByteRange(
        _ headerValue: String?,
        totalLength: Int
    ) -> ResourceByteRange? {
        guard let headerValue,
              headerValue.hasPrefix("bytes="),
              let dashIndex = headerValue.dropFirst(6).firstIndex(of: "-") else {
            return nil
        }
        let spec = headerValue.dropFirst(6)
        guard let lower = Int64(spec[spec.startIndex..<dashIndex]),
              let upper = Int64(spec[spec.index(after: dashIndex)...]),
              lower >= 0,
              upper >= lower,
              upper < Int64(totalLength) else {
            return nil
        }
        return ResourceByteRange(lowerBound: lower, upperBound: upper)
    }

    private static func loopbackDirectoryXML(size: Int) -> Data {
        Data(
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
                <d:href>/dav/loopback-large.wav</d:href>
                <d:propstat><d:prop>
                  <d:displayname>loopback-large.wav</d:displayname>
                  <d:resourcetype/>
                  <d:getcontentlength>\(size)</d:getcontentlength>
                  <d:getetag>"loopback-v1"</d:getetag>
                  <d:getcontenttype>audio/wav</d:getcontenttype>
                </d:prop></d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8
        )
    }

    private static func loopbackFileXML(size: Int) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/dav/loopback-large.wav</d:href>
                <d:propstat><d:prop>
                  <d:displayname>loopback-large.wav</d:displayname>
                  <d:resourcetype/>
                  <d:getcontentlength>\(size)</d:getcontentlength>
                  <d:getetag>"loopback-v1"</d:getetag>
                  <d:getcontenttype>audio/wav</d:getcontenttype>
                </d:prop></d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8
        )
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

/// 真实回环 TCP HTTP 服务器：线程每连接、keep-alive、可编程路由。
///
/// 只用于集成测试。与 `URLProtocol` 桩不同，请求经过真实的 URLSession
/// 网络栈（连接复用、重定向、超时），能验证传输契约在真实 socket 上的行为。
/// handler 在连接线程同步执行，必须自身线程安全。
private final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        /// 路径（含可选 query），未做百分号解码。
        let target: String
        /// 头字段名统一小写。
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data

        init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    let port: UInt16
    private let listenFD: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var isStopped = false

    init(handler: @escaping Handler) throws {
        self.handler = handler

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: assigned.sin_port)

        let acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread.name = "LoopbackHTTPServer.accept"
        acceptThread.start()
    }

    func stop() {
        lock.lock()
        let alreadyStopped = isStopped
        isStopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        // shutdown 会唤醒阻塞中的 accept；单独 close 在 Darwin 上不保证。
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    deinit {
        stop()
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func acceptLoop() {
        while !stopped {
            var clientAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &length)
                }
            }
            guard clientFD >= 0 else {
                if stopped { return }
                continue
            }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigpipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            let connectionThread = Thread { [weak self] in
                self?.serve(clientFD)
            }
            connectionThread.name = "LoopbackHTTPServer.connection"
            connectionThread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        while !stopped {
            guard let request = readRequest(fd, buffer: &buffer) else { return }
            let response = handler(request)
            guard write(response, method: request.method, to: fd) else { return }
        }
    }

    private func readRequest(_ fd: Int32, buffer: inout Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard receiveChunk(fd, into: &buffer) else { return nil }
        }
        guard let separatorRange = buffer.range(of: separator) else { return nil }
        let headData = Data(buffer[buffer.startIndex..<separatorRange.lowerBound])
        var remainder = Data(buffer[separatorRange.upperBound...])

        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 3 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        while remainder.count < contentLength {
            guard receiveChunk(fd, into: &remainder) else { return nil }
        }
        let body = Data(remainder.prefix(contentLength))
        buffer = Data(remainder.dropFirst(contentLength))
        return Request(method: method, target: target, headers: headers, body: body)
    }

    private func receiveChunk(_ fd: Int32, into buffer: inout Data) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let received = recv(fd, &chunk, chunk.count, 0)
        guard received > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<received])
        return true
    }

    private func write(_ response: Response, method: String, to fd: Int32) -> Bool {
        var headers = response.headers
        // HEAD 允许 handler 显式声明完整大小；其余响应由服务器按正文计算。
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(response.body.count)
        }
        if headers["Connection"] == nil {
            headers["Connection"] = "keep-alive"
        }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(for: response.status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        if method != "HEAD" {
            payload.append(response.body)
        }
        return payload.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return raw.isEmpty }
            var offset = 0
            while offset < raw.count {
                let sent = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 207: "Multi-Status"
        case 302: "Found"
        case 404: "Not Found"
        case 416: "Range Not Satisfiable"
        default: "Status"
        }
    }
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
