import Foundation

/// 测试专用 URLProtocol：按 URL 把请求路由到预置处理器，全程不发起真实网络请求。
final class MockURLProtocol: URLProtocol {
    /// 一次请求的预期结果。
    enum Outcome: Sendable {
        /// 返回指定状态码、响应头与响应体。
        case respond(status: Int, headers: [String: String], body: Data)
        /// 以指定 URLError 失败。
        case fail(URLError.Code)
        /// 永不完成，直到请求被取消；用于测试取消语义。
        case hang
    }

    typealias Handler = @Sendable (URLRequest) -> Outcome

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [URL: Handler] = [:]

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

    /// 构造只经过 MockURLProtocol 的 URLSession。
    static func makeSession(requestTimeout: TimeInterval = 5) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: configuration)
    }

    private var delivered = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        defer { lock.unlock() }
        return handlers[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = request.url.flatMap { Self.handlers[$0] }
        Self.lock.unlock()

        guard let handler else {
            deliver { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
            return
        }

        switch handler(request) {
        case .respond(let status, let headers, let body):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: "HTTP/1.1",
                      headerFields: headers
                  ) else {
                deliver { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
                return
            }
            // 自定义 URLProtocol 不会自动跟随重定向：需要显式把重定向上报给会话。
            if (300..<400).contains(status),
               let location = headers.first(where: { $0.key.lowercased() == "location" })?.value,
               let redirectURL = URL(string: location, relativeTo: url)?.absoluteURL {
                var redirected = URLRequest(url: redirectURL)
                redirected.httpMethod = request.httpMethod
                deliver {
                    client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                }
                return
            }
            deliver {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        case .fail(let code):
            deliver { client?.urlProtocol(self, didFailWithError: URLError(code)) }
        case .hang:
            break
        }
    }

    override func stopLoading() {
        deliver { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    }

    private func deliver(_ body: () -> Void) {
        guard !delivered else { return }
        delivered = true
        body()
    }
}

/// 测试用线程安全盒子，用于在 @Sendable 闭包中收集观察值。
final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}
