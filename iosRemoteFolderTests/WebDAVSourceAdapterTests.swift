import Foundation
import Testing

@testable import iosRemoteFolder

@Suite("WebDAV 来源适配器", .serialized)
struct WebDAVSourceAdapterTests {
    private static let endpoint = URL(string: "https://dav.test/dav/")!
    private static let fileURL = URL(string: "https://dav.test/dav/%E8%B5%84%E6%96%99%20%23%3F%25.txt")!
    private static let fileDirectoryURL = URL(string: "https://dav.test/dav/%E8%B5%84%E6%96%99%20%23%3F%25.txt/")!
    private static let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let source = ResourceSource(
        id: sourceID,
        name: "测试 WebDAV",
        kind: .webdav,
        endpoint: endpoint.absoluteString,
        status: .disconnected,
        itemCountDescription: ""
    )

    @Test("PROPFIND 解析 namespace、保留字符路径与 Basic Auth，并支持 Range 读取")
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
        #expect(item.capabilities.contains(.rangeRead))
        #expect(data == Data("bcd".utf8))
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
}

/// WebDAV tests use an isolated protocol because the existing HTTP fixture is
/// intentionally reset by its own suite while suites may run concurrently.
private final class WebDAVMockURLProtocol: URLProtocol {
    enum Outcome: Sendable {
        case respond(status: Int, headers: [String: String], body: Data)
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
        }
    }

    override func stopLoading() {}

    private func deliver(_ body: () -> Void) {
        guard !delivered else { return }
        delivered = true
        body()
    }
}
