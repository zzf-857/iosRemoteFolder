import Foundation

/// HTTP/HTTPS 直链资源描述：一个来源由一组预先配置的直链组成。
struct HTTPResourceDescriptor: Hashable, Sendable {
    /// 来源内的逻辑路径，作为 `ResourceItem.path`。
    var path: String
    /// 展示名称。
    var name: String
    /// 资源类型。
    var kind: ResourceKind
    /// 直链 URL。
    var url: URL
    /// 需要附加的请求头（可含鉴权头；禁止写入日志或持久化模型）。
    var headers: [String: String]

    init(
        path: String,
        name: String,
        kind: ResourceKind,
        url: URL,
        headers: [String: String] = [:]
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.url = url
        self.headers = headers
    }
}

/// HTTP/HTTPS 直链来源 adapter。
///
/// 能力边界：支持连接探测（HEAD）、HEAD 元数据（405/501 时降级为 Range GET 探测）、
/// GET 数据读取和可选 Range。服务器未确认支持 Range 前不声称 `rangeRead`；
/// 服务器忽略 Range 头返回全量 200 时，在本地切片降级，不伪造 206。
struct HTTPSourceAdapter: ResourceSourceAdapter {
    let source: ResourceSource
    let descriptors: [HTTPResourceDescriptor]

    private let session: URLSession
    private let timeout: TimeInterval

    init(
        source: ResourceSource,
        descriptors: [HTTPResourceDescriptor],
        session: URLSession? = nil,
        timeout: TimeInterval = 15
    ) {
        self.source = source
        self.descriptors = descriptors
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    func connect() async throws {
        // 没有配置直链时无需网络探测，直接视为可连接。
        guard let probe = descriptors.first else { return }
        _ = try await performRequest(method: "HEAD", descriptor: probe, headers: [:])
    }

    func listResources() async throws -> [ResourceItem] {
        descriptors.map { descriptor in
            ResourceItem(
                name: descriptor.name,
                kind: descriptor.kind,
                sourceID: source.id,
                path: descriptor.path,
                sizeDescription: "待探测",
                modifiedDescription: "直链资源",
                capabilities: [.read, .download, .directURL],
                accent: .recommended(for: descriptor.kind)
            )
        }
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        let descriptor = try descriptor(for: item)
        return .remoteHTTP(
            .init(
                url: descriptor.url,
                method: "GET",
                headers: descriptor.headers,
                supportsRange: false
            )
        )
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        let descriptor = try descriptor(for: item)
        do {
            let (_, response) = try await performRequest(method: "HEAD", descriptor: descriptor, headers: [:])
            return Self.metadata(from: response)
        } catch ResourceSourceError.httpStatus(let code) where code == 405 || code == 501 {
            // 服务器不支持 HEAD：用 1 字节 Range GET 探测，同时确认 Range 支持。
            let (_, response) = try await performRequest(
                method: "GET",
                descriptor: descriptor,
                headers: ["Range": "bytes=0-0"]
            )
            var metadata = Self.metadata(from: response)
            metadata.acceptsRanges = response.statusCode == 206
            return metadata
        }
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        let descriptor = try descriptor(for: item)
        var headers: [String: String] = [:]
        if let range {
            headers["Range"] = range.httpHeaderValue
        }
        let (data, response) = try await performRequest(method: "GET", descriptor: descriptor, headers: headers)
        guard let range else { return data }
        if response.statusCode == 206 {
            return data
        }
        // 明确降级：服务器忽略了 Range 头并返回全量内容，在本地截取请求区间。
        guard let clamped = range.clamped(toTotalLength: Int64(data.count)) else {
            return Data()
        }
        return data.subdata(in: Int(clamped.lowerBound)..<Int(clamped.upperBound + 1))
    }

    // MARK: - Private

    private func descriptor(for item: ResourceItem) throws -> HTTPResourceDescriptor {
        guard item.sourceID == source.id,
              let descriptor = descriptors.first(where: { $0.path == item.path }) else {
            throw ResourceSourceError.invalidReference
        }
        return descriptor
    }

    private func performRequest(
        method: String,
        descriptor: HTTPResourceDescriptor,
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: descriptor.url, timeoutInterval: timeout)
        request.httpMethod = method
        for (field, value) in descriptor.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResourceSourceError.mapping(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResourceSourceError.unavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ResourceSourceError.http(statusCode: httpResponse.statusCode)
        }
        return (data, httpResponse)
    }

    private static func metadata(from response: HTTPURLResponse) -> ResourceMetadata {
        let byteSize = response.expectedContentLength >= 0 ? Int64(response.expectedContentLength) : nil
        var acceptsRanges = false
        var modifiedAt: Date?
        for (rawField, rawValue) in response.allHeaderFields {
            guard let field = rawField as? String, let value = rawValue as? String else { continue }
            if field.caseInsensitiveCompare("Accept-Ranges") == .orderedSame {
                acceptsRanges = value.caseInsensitiveCompare("bytes") == .orderedSame
            }
            if field.caseInsensitiveCompare("Last-Modified") == .orderedSame {
                modifiedAt = parseHTTPDate(value)
            }
        }
        return ResourceMetadata(
            byteSize: byteSize,
            contentType: response.mimeType,
            modifiedAt: modifiedAt,
            acceptsRanges: acceptsRanges
        )
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
