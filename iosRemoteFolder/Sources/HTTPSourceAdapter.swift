import Foundation
import UniformTypeIdentifiers

/// HTTP/HTTPS 资源描述：一个来源由一组预先配置的远端 URL 组成。
///
/// Scheme 契约：`url` 只允许 `http` 与 `https`；其他 scheme 会在 adapter
/// 边界被拒绝并映射为 `ResourceSourceError.invalidReference`。
struct HTTPResourceDescriptor: Hashable, Sendable {
    /// 来源内的逻辑路径，作为 `ResourceItem.path`。
    var path: String
    /// 展示名称。
    var name: String
    /// 资源类型。
    var kind: ResourceKind
    /// 直链 URL，只允许 http/https scheme。
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
/// 能力边界：支持连接探测（HEAD，405/501 时降级为 1 字节 Range GET，并把
/// 有效证据回写能力缓存）、HEAD 元数据（206 探测时从 `Content-Range` 解析
/// 总长度）、GET 数据读取和可选 Range。服务器未确认支持 Range 前不声称
/// `rangeRead`；Range 能力按“逻辑路径 + 直链 URL”缓存已验证证据。
/// 206 分片必须通过 `Content-Range` 单位/起止/总长度与响应体长度校验才会
/// 交给查看器；枚举阶段会拒绝包含非 http/https scheme 的来源。
/// 服务器忽略 Range 头返回全量 200 时，用可取消的流式读取只消费请求区间，
/// 并在超过大小预算时返回可行动错误，不把整文件载入内存。
struct HTTPSourceAdapter: ResourceSourceAdapter {
    /// 200 全量回退时允许消费的最大字节数；超过即返回 `responseTooLarge`。
    static let defaultMaxRangeFallbackBytes: Int64 = 50 * 1024 * 1024

    let source: ResourceSource
    let descriptors: [HTTPResourceDescriptor]

    /// Adapter 持有的 descriptor 路径均在初始化时替换为 `ResourcePath.normalized`。
    /// 规范化逻辑路径 -> canonical descriptor 的精确映射；构建时检测重复逻辑路径与非法配置。
    private let pathToDescriptor: [String: HTTPResourceDescriptor]
    /// 是否存在规范化后重复的逻辑路径；出现时所有列举/引用/读取都必须明确报 `invalidReference`。
    private let hasPathConflict: Bool
    /// 是否存在非法 scheme 或无法规范化逻辑路径的 descriptor。
    private let hasInvalidDescriptor: Bool

    private let session: URLSession
    private let timeout: TimeInterval
    private let maxRangeFallbackBytes: Int64
    /// 已验证的 Range 能力缓存：只有服务端响应证据才能写入。
    private let verifiedRangeCapability = VerifiedRangeCapability()

    init(
        source: ResourceSource,
        descriptors: [HTTPResourceDescriptor],
        session: URLSession? = nil,
        timeout: TimeInterval = 15,
        maxRangeFallbackBytes: Int64 = HTTPSourceAdapter.defaultMaxRangeFallbackBytes
    ) {
        self.source = source
        self.timeout = timeout
        self.maxRangeFallbackBytes = maxRangeFallbackBytes

        var canonicalDescriptors: [HTTPResourceDescriptor] = []
        var map: [String: HTTPResourceDescriptor] = [:]
        var conflict = false
        var invalidDescriptor = false
        for rawDescriptor in descriptors {
            var descriptor = rawDescriptor
            if !(descriptor.url.scheme?.lowercased() == "http" || descriptor.url.scheme?.lowercased() == "https") {
                invalidDescriptor = true
            }
            if descriptor.kind == .folder {
                invalidDescriptor = true
            }
            guard let canonicalPath = ResourcePath(rawValue: descriptor.path) else {
                invalidDescriptor = true
                continue
            }
            // 从此处起，身份、字典寻址和能力缓存都只消费这一个 canonical 值。
            descriptor.path = canonicalPath.normalized
            canonicalDescriptors.append(descriptor)
            let normalized = canonicalPath.normalized
            if map[normalized] != nil {
                conflict = true
            }
            map[normalized] = descriptor
        }
        // 文件/虚拟目录同路径冲突：若某规范化路径是另一路径的严格前缀
        // （例如同时配置 `/a` 与 `/a/b`），同一路径既要做文件又要做目录，
        // 虚拟树无法一致，整体拒绝，避免 SwiftUI 看到同一身份的两个冲突节点。
        var prefixConflict = false
        let normalizedPaths = Array(map.keys)
        for a in normalizedPaths {
            guard let pa = ResourcePath(rawValue: a) else { continue }
            for b in normalizedPaths where a != b {
                guard let pb = ResourcePath(rawValue: b) else { continue }
                if pa.isUnder(pb) || pb.isUnder(pa) {
                    prefixConflict = true
                    break
                }
            }
            if prefixConflict { break }
        }
        self.descriptors = canonicalDescriptors
        self.pathToDescriptor = map
        self.hasPathConflict = conflict || prefixConflict
        self.hasInvalidDescriptor = invalidDescriptor

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    func connect() async throws {
        // 配置非法（重复逻辑路径或非 http/https scheme）时整体拒绝，
        // 避免把无效来源暴露给下游直到引用或读取时才失败。
        guard !hasInvalidDescriptor, !hasPathConflict else {
            throw ResourceSourceError.invalidReference
        }
        // 没有配置直链时无需网络探测，直接视为可连接。
        guard let probe = descriptors.first else { return }
        let descriptor = try validated(probe)
        let key = capabilityKey(for: descriptor)
        do {
            let response = try await probeResponse(method: "HEAD", descriptor: descriptor)
            // HEAD 成功时，Accept-Ranges: bytes 是唯一有效证据；缺失或其他值
            // 明确写入 false，避免陈旧的 true 证据残留在缓存中。
            verifiedRangeCapability.set(Self.acceptsByteRanges(response), for: key)
        } catch ResourceSourceError.httpStatus(let code) where code == 405 || code == 501 {
            // 服务器不支持 HEAD：降级为 1 字节 Range GET 探测。
            // 探测只看状态与响应头，不消费响应体。
            let response = try await probeResponse(
                method: "GET",
                descriptor: descriptor,
                headers: ["Range": "bytes=0-0"]
            )
            // 与 fetchMetadata 共用同一证据规则：只有 Content-Range 完整校验通过的
            // 206 才算有效证据；malformed 206 一律不得缓存为支持 Range。
            verifiedRangeCapability.set(Self.verifiedRangeProbeEvidence(from: response), for: key)
        }
    }

    /// 在已配置直链上构建可浏览的虚拟目录树：进入任意目录只返回该层的直接子项
    /// （文件或必要的虚拟文件夹），不把所有深层资源平铺在根目录。
    /// 规范化后出现重复逻辑路径时整体拒绝（不会静默选择某一项）。
    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        guard !hasInvalidDescriptor, !hasPathConflict else {
            throw ResourceSourceError.invalidReference
        }
        var folderNames: [String: String] = [:]   // 规范化文件夹路径 -> 展示名
        var fileItems: [ResourceItem] = []
        for (normalized, descriptor) in pathToDescriptor {
            guard let descriptorPath = ResourcePath(rawValue: normalized) else { continue }
            guard descriptorPath.isUnder(path) else { continue }
            let remaining = descriptorPath.components.dropFirst(path.components.count)
            guard !remaining.isEmpty else { continue }
            if remaining.count == 1 {
                fileItems.append(makeFileItem(descriptor, path: descriptorPath))
            } else {
                guard let folderName = remaining.first,
                      let folderPath = path.child(folderName) else { continue }
                folderNames[folderPath.normalized] = folderName
            }
        }
        let folders = folderNames.map { (folderPath, folderName) in
            ResourceItem(
                sourceID: source.id,
                logicalPath: ResourcePath(rawValue: folderPath)!,
                name: folderName,
                kind: .folder,
                metadata: ResourceMetadata(isDirectory: true),
                capabilities: [.list],
                accent: .recommended(for: .folder)
            )
        }
        let sortedFolders = folders.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let sortedFiles = fileItems.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return sortedFolders + sortedFiles
    }

    private func makeFileItem(_ descriptor: HTTPResourceDescriptor, path: ResourcePath) -> ResourceItem {
        ResourceItem(
            sourceID: source.id,
            logicalPath: path,
            name: descriptor.name,
            kind: descriptor.kind,
            metadata: ResourceMetadata(isDirectory: false),
            capabilities: [.read, .download, .directURL],
            accent: .recommended(for: descriptor.kind)
        )
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        let descriptor = try descriptor(for: item)
        // Range 能力只来自已验证的服务端证据；未确认前保持不支持。
        return .remoteHTTP(
            .init(
                url: descriptor.url,
                method: "GET",
                headers: descriptor.headers,
                supportsRange: verifiedRangeCapability.supportsRange(for: capabilityKey(for: descriptor))
            )
        )
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        let descriptor = try descriptor(for: item)
        let key = capabilityKey(for: descriptor)
        do {
            let response = try await probeResponse(method: "HEAD", descriptor: descriptor)
            let metadata = Self.headMetadata(from: response, descriptor: descriptor)
            verifiedRangeCapability.set(metadata.acceptsRanges, for: key)
            return metadata
        } catch ResourceSourceError.httpStatus(let code) where code == 405 || code == 501 {
            // 服务器不支持 HEAD：用 1 字节 Range GET 探测，同时确认 Range 支持。
            let response = try await probeResponse(
                method: "GET",
                descriptor: descriptor,
                headers: ["Range": "bytes=0-0"]
            )
            var metadata = Self.partialGetMetadata(from: response, descriptor: descriptor)
            // 与 connect() 共用同一证据规则：malformed 206 不声明也不缓存 Range 支持。
            metadata.acceptsRanges = Self.verifiedRangeProbeEvidence(from: response)
            verifiedRangeCapability.set(metadata.acceptsRanges, for: key)
            return metadata
        }
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        let descriptor = try descriptor(for: item)
        guard let range else {
            // 完整读取保留既有行为与错误映射。
            let (data, _) = try await performRequest(method: "GET", descriptor: descriptor, headers: [:])
            return data
        }

        let key = capabilityKey(for: descriptor)
        let (response, bytes) = try await performStreamingRequest(
            method: "GET",
            descriptor: descriptor,
            headers: ["Range": range.httpHeaderValue]
        )
        switch response.statusCode {
        case 206:
            return try await validatedPartialData(from: bytes, response: response, requested: range, key: key)
        case 200:
            // 明确降级：只有 200 才视为服务器忽略 Range 的全量回退。
            // 只流式消费请求区间，不把完整响应载入内存。
            verifiedRangeCapability.set(false, for: key)
            return try await sliceFromStream(bytes, range: range)
        default:
            // 其余 2xx（201/203/204…）不是区间请求的合法应答，不得伪装成正常分片。
            bytes.task.cancel()
            throw ResourceSourceError.invalidResponse
        }
    }

    // MARK: - Private

    private func descriptor(for item: ResourceItem) throws -> HTTPResourceDescriptor {
        guard item.sourceID == source.id else { throw ResourceSourceError.invalidReference }
        // 身份一致性：item 的稳定身份必须与来源和规范化路径一致，
        // 拒绝伪造身份或身份与路径矛盾的资源。
        guard item.id.sourceID == source.id, item.id.logicalPath == item.path else {
            throw ResourceSourceError.invalidReference
        }
        guard !hasInvalidDescriptor, !hasPathConflict else { throw ResourceSourceError.invalidReference }
        // 用规范化逻辑路径精确寻址：重复路径在初始化阶段已成冲突并整体拒绝，
        // 不会像 `first(where:)` 那样静默选择某一项。
        guard let descriptor = pathToDescriptor[item.path] else {
            throw ResourceSourceError.invalidReference
        }
        return try validated(descriptor)
    }

    /// 只允许 http/https scheme；其他 scheme 一律视为无效引用。
    private func validated(_ descriptor: HTTPResourceDescriptor) throws -> HTTPResourceDescriptor {
        guard let scheme = descriptor.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ResourceSourceError.invalidReference
        }
        return descriptor
    }

    /// 构造 Range 能力缓存键：descriptor.path 已在初始化时替换为唯一的
    /// `ResourcePath.normalized`，并与身份和 `pathToDescriptor` 寻址共用该值。
    /// URL 是第二维；展示名称与可能含凭证的 headers 不进入键。
    private func capabilityKey(for descriptor: HTTPResourceDescriptor) -> CapabilityKey {
        // Initialization canonicalizes every valid descriptor. Re-parse here so
        // the key visibly consumes the same normalized value as identity and
        // `pathToDescriptor`; invalid input never falls back to a raw path.
        let path = ResourcePath(rawValue: descriptor.path)!
        return CapabilityKey(path: path.normalized, url: descriptor.url)
    }

    private func makeRequest(
        method: String,
        descriptor: HTTPResourceDescriptor,
        headers: [String: String]
    ) -> URLRequest {
        var request = URLRequest(url: descriptor.url, timeoutInterval: timeout)
        request.httpMethod = method
        for (field, value) in descriptor.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// 完整下载路径：保留给不带区间的 GET 读取。
    private func performRequest(
        method: String,
        descriptor: HTTPResourceDescriptor,
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        let request = makeRequest(method: method, descriptor: descriptor, headers: headers)
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

    /// 流式请求：校验状态后返回响应与可取消的字节流，不预载响应体。
    private func performStreamingRequest(
        method: String,
        descriptor: HTTPResourceDescriptor,
        headers: [String: String]
    ) async throws -> (HTTPURLResponse, URLSession.AsyncBytes) {
        let request = makeRequest(method: method, descriptor: descriptor, headers: headers)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ResourceSourceError.mapping(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ResourceSourceError.unavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            bytes.task.cancel()
            throw ResourceSourceError.http(statusCode: httpResponse.statusCode)
        }
        return (httpResponse, bytes)
    }

    /// 探测请求：只消费状态与响应头，立即取消任务释放连接，避免拉取全量内容。
    private func probeResponse(
        method: String,
        descriptor: HTTPResourceDescriptor,
        headers: [String: String] = [:]
    ) async throws -> HTTPURLResponse {
        let (response, bytes) = try await performStreamingRequest(
            method: method,
            descriptor: descriptor,
            headers: headers
        )
        bytes.task.cancel()
        return response
    }

    /// 收集 206 分片内容；分片本身很小，仍按区间长度设上限。
    private func collect(_ bytes: URLSession.AsyncBytes, limit: Int64) async throws -> Data {
        var collected = Data()
        do {
            for try await byte in bytes {
                collected.append(byte)
                if Int64(collected.count) >= limit { break }
            }
        } catch {
            bytes.task.cancel()
            throw ResourceSourceError.mapping(error)
        }
        bytes.task.cancel()
        return collected
    }

    /// 校验并读取 206 分片：`Content-Range` 的 bytes 单位、起止位置、总长度
    /// 与响应体实际长度必须全部一致；短响应、非法 `Content-Range` 或长度不符
    /// 都会抛错，绝不把不可信的分片交给查看器。
    private func validatedPartialData(
        from bytes: URLSession.AsyncBytes,
        response: HTTPURLResponse,
        requested: ResourceByteRange,
        key: CapabilityKey
    ) async throws -> Data {
        guard let contentRange = Self.parseContentRange(from: response) else {
            bytes.task.cancel()
            throw ResourceSourceError.invalidResponse
        }
        // 起止必须合法，且与请求区间对齐；否则分片偏移不可信。
        guard contentRange.first >= 0,
              contentRange.last >= contentRange.first,
              contentRange.first == requested.lowerBound,
              contentRange.last <= requested.upperBound else {
            bytes.task.cancel()
            throw ResourceSourceError.invalidResponse
        }
        // 收紧短分片：请求未到达文件尾（响应终点早于请求终点）时，只有明确
        // `total == last + 1` 的真实 EOF 场景才允许短分片；其余短响应一律视为违约。
        let isShort = contentRange.last < requested.upperBound
        if isShort, contentRange.total != contentRange.last + 1 {
            bytes.task.cancel()
            throw ResourceSourceError.invalidResponse
        }
        // 排除理论极端情况（last 为 Int64.max 且 first 为 0）导致的区间长度溢出。
        guard contentRange.last < Int64.max || contentRange.first > 0 else {
            bytes.task.cancel()
            throw ResourceSourceError.invalidResponse
        }
        // 声明了总长度时，终点必须落在总长度内。
        if let total = contentRange.total, total <= contentRange.last {
            bytes.task.cancel()
            throw ResourceSourceError.invalidResponse
        }
        let expectedLength = contentRange.last - contentRange.first + 1
        // 多读一字节用于发现超出声明长度的响应。
        let limit = expectedLength == Int64.max ? expectedLength : expectedLength + 1
        let collected = try await collect(bytes, limit: limit)
        guard Int64(collected.count) == expectedLength else {
            // 短响应（不足）或超出 Content-Range 声明，均视为违约。
            throw ResourceSourceError.invalidResponse
        }
        verifiedRangeCapability.set(true, for: key)
        return collected
    }

    /// 服务器忽略 Range 时的流式切片：跳过区间前的字节，只收集请求区间。
    /// 预算检查在消费每个字节之前进行，总消费量（跳过 + 收集）永不超出上限；
    /// `lowerBound + length` 恰好跨过预算时只会抛错，不可能返回超预算数据。
    /// 支持任务取消。
    private func sliceFromStream(_ bytes: URLSession.AsyncBytes, range: ResourceByteRange) async throws -> Data {
        var skipped: Int64 = 0
        var collected = Data()
        do {
            for try await byte in bytes {
                // 先校验预算再消费，跳过与收集共用同一不变量。
                if skipped + Int64(collected.count) + 1 > maxRangeFallbackBytes {
                    throw ResourceSourceError.responseTooLarge
                }
                if skipped < range.lowerBound {
                    skipped += 1
                    continue
                }
                collected.append(byte)
                if Int64(collected.count) >= range.length { break }
            }
        } catch let error as ResourceSourceError {
            bytes.task.cancel()
            throw error
        } catch {
            bytes.task.cancel()
            throw ResourceSourceError.mapping(error)
        }
        bytes.task.cancel()
        return collected
    }

    /// HEAD 元数据：`Content-Length` 代表完整响应大小；只在
    /// `Accept-Ranges: bytes` 时声称 Range 支持。
    private static func headMetadata(
        from response: HTTPURLResponse,
        descriptor: HTTPResourceDescriptor
    ) -> ResourceMetadata {
        let byteSize: Int64?
        if response.statusCode == 206 {
            // A partial HEAD response has the same single-fragment semantics as
            // a partial GET: never treat Content-Length (often 1) as full size.
            byteSize = contentRangeTotalLength(from: response)
        } else if response.expectedContentLength >= 0 {
            byteSize = Int64(response.expectedContentLength)
        } else {
            byteSize = nil
        }
        let modifiedAt = headerValue("Last-Modified", in: response).flatMap(parseHTTPDate)
        let mimeType = response.mimeType
        return ResourceMetadata(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            mimeType: mimeType,
            typeIdentifier: typeIdentifier(forMIMEType: mimeType, descriptor: descriptor),
            isDirectory: false,
            acceptsRanges: acceptsByteRanges(response),
            revision: revision(from: response, modifiedAt: modifiedAt, byteSize: byteSize)
        )
    }

    /// 405/501 后的探测元数据：206 的 `Content-Length` 是单字节分片大小，
    /// 所以完整大小只能来自合法 `Content-Range` 总长度。若服务端忽略 Range
    /// 返回 200，则其 Content-Length 才可能代表完整响应大小。
    private static func partialGetMetadata(
        from response: HTTPURLResponse,
        descriptor: HTTPResourceDescriptor
    ) -> ResourceMetadata {
        let byteSize: Int64?
        if response.statusCode == 206 {
            byteSize = contentRangeTotalLength(from: response)
        } else if response.statusCode == 200, response.expectedContentLength >= 0 {
            byteSize = Int64(response.expectedContentLength)
        } else {
            byteSize = nil
        }
        let modifiedAt = headerValue("Last-Modified", in: response).flatMap(parseHTTPDate)
        let mimeType = response.mimeType
        return ResourceMetadata(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            mimeType: mimeType,
            typeIdentifier: typeIdentifier(forMIMEType: mimeType, descriptor: descriptor),
            isDirectory: false,
            acceptsRanges: false,
            revision: revision(from: response, modifiedAt: modifiedAt, byteSize: byteSize)
        )
    }

    /// 解析后的 `Content-Range`：仅在格式完全合法时返回，绝不猜测。
    private struct ParsedContentRange {
        let first: Int64
        let last: Int64
        /// 总长度；`*` 表示服务端未声明。
        let total: Int64?
    }

    /// 严格解析 `Content-Range: bytes <first>-<last>/<total|*>`。
    /// 校验 bytes 单位；单位不符、缺少起止或总长度非法时返回 nil。
    private static func parseContentRange(from response: HTTPURLResponse) -> ParsedContentRange? {
        guard let value = headerValue("Content-Range", in: response) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else { return nil }
        let unit = trimmed[..<spaceIndex].trimmingCharacters(in: .whitespaces)
        // 只接受 bytes 单位。
        guard unit.caseInsensitiveCompare("bytes") == .orderedSame else { return nil }
        let rest = trimmed[trimmed.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
        guard let slashIndex = rest.firstIndex(of: "/") else { return nil }
        let rangePart = rest[..<slashIndex].trimmingCharacters(in: .whitespaces)
        let totalPart = rest[rest.index(after: slashIndex)...].trimmingCharacters(in: .whitespaces)
        guard let dashIndex = rangePart.firstIndex(of: "-") else { return nil }
        let firstText = rangePart[..<dashIndex].trimmingCharacters(in: .whitespaces)
        let lastText = rangePart[rangePart.index(after: dashIndex)...].trimmingCharacters(in: .whitespaces)
        guard let first = Int64(firstText), let last = Int64(lastText) else { return nil }
        let total: Int64?
        if totalPart == "*" {
            total = nil
        } else if let parsedTotal = Int64(totalPart) {
            total = parsedTotal
        } else {
            return nil
        }
        return ParsedContentRange(first: first, last: last, total: total)
    }

    /// 解析 `Content-Range` 的总长度；`*` 或格式非法时视为未知，返回 nil。
    private static func contentRangeTotalLength(from response: HTTPURLResponse) -> Int64? {
        guard let parsed = parseContentRange(from: response),
              parsed.first >= 0,
              parsed.last >= parsed.first else {
            return nil
        }
        if let total = parsed.total, total <= parsed.last {
            return nil
        }
        return parsed.total
    }

    private static func revision(
        from response: HTTPURLResponse,
        modifiedAt: Date?,
        byteSize: Int64?
    ) -> ResourceRevision {
        ResourceRevision.strongest(
            etag: headerValue("ETag", in: response),
            serverVersion: serverVersion(from: response),
            modifiedAt: modifiedAt,
            byteSize: byteSize
        )
    }

    /// Different HTTP services use different names for an opaque version token.
    /// All supported spellings feed the same strongest-evidence constructor; the
    /// value itself is never interpreted or exposed in presentation models.
    private static func serverVersion(from response: HTTPURLResponse) -> String? {
        let fields = [
            "X-Resource-Version",
            "X-Server-Version",
            "X-Version",
            "Content-Version",
            "Version"
        ]
        for field in fields {
            if let value = headerValue(field, in: response),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func typeIdentifier(
        forMIMEType mimeType: String?,
        descriptor: HTTPResourceDescriptor
    ) -> String? {
        if let mimeType, let type = UTType(mimeType: mimeType) {
            return type.identifier
        }
        // A descriptor extension is only a fallback after a real HTTP metadata
        // probe; unprobed items still carry nil typed metadata.
        guard let type = UTType(filenameExtension: descriptor.url.pathExtension),
              !descriptor.url.pathExtension.isEmpty else {
            return nil
        }
        return type.identifier
    }

    /// 响应是否声明 `Accept-Ranges: bytes`。
    private static func acceptsByteRanges(_ response: HTTPURLResponse) -> Bool {
        headerValue("Accept-Ranges", in: response)
            .map { $0.caseInsensitiveCompare("bytes") == .orderedSame } ?? false
    }

    /// HEAD 405/501 降级探测的统一证据规则，`connect()` 与 `fetchMetadata()` 共用。
    ///
    /// 只有同时满足以下条件的 206 才确认 Range 支持：
    /// - `Content-Range` 为合法的 `bytes 0-0/<total|*>`，与探测区间 `bytes=0-0` 对齐；
    /// - 声明总长度时必须覆盖终点（total > last）；
    /// - 响应携带 `Content-Length` 时必须等于探测分片大小，缺失则不猜测。
    /// malformed 206 不是有效证据，绝不能据此把能力缓存为支持 Range。
    private static func verifiedRangeProbeEvidence(from response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 206,
              let contentRange = parseContentRange(from: response),
              contentRange.first == 0,
              contentRange.last == 0 else {
            return false
        }
        if let total = contentRange.total, total <= contentRange.last {
            return false
        }
        let fragmentLength = contentRange.last - contentRange.first + 1
        if response.expectedContentLength >= 0,
           response.expectedContentLength != fragmentLength {
            return false
        }
        return true
    }

    private static func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        for (rawField, rawValue) in response.allHeaderFields {
            guard let field = rawField as? String, let value = rawValue as? String else { continue }
            if field.caseInsensitiveCompare(name) == .orderedSame {
                return value
            }
        }
        return nil
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    /// Range 能力缓存键：逻辑路径 + 直链 URL 共同确定一个资源的 Range 能力，
    /// 避免重复路径、或路径不变但 URL 变化时串用能力证据。
    private struct CapabilityKey: Hashable {
        let path: String
        let url: URL
    }

    /// 已验证 Range 能力缓存：线程安全，只在拿到服务端响应证据后写入。
    private final class VerifiedRangeCapability: @unchecked Sendable {
        private let lock = NSLock()
        private var supportByKey: [CapabilityKey: Bool] = [:]

        func set(_ supportsRange: Bool, for key: CapabilityKey) {
            lock.lock()
            defer { lock.unlock() }
            supportByKey[key] = supportsRange
        }

        func supportsRange(for key: CapabilityKey) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return supportByKey[key] ?? false
        }
    }
}
