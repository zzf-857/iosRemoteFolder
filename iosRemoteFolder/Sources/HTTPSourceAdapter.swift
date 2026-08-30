import Foundation
import UniformTypeIdentifiers

/// Optional redirect policy feedback used by WebDAV requests. URLSession's
/// async convenience APIs surface a rejected redirect as cancellation (and a
/// custom URLProtocol may surface it as timeout), so the policy carries the
/// more specific source error back to the request boundary.
protocol HTTPRedirectFailureReporting: AnyObject, Sendable {
    func consumeUnsafeRedirect() -> Bool

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    )

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    )
}

/// Scopes unsafe-redirect attribution to exactly one logical request.
///
/// The shared WebDAV redirect policy decides whether a redirect is allowed,
/// but its decision must be attributed to the request that triggered it. A
/// shared consumable flag lets concurrent requests steal each other's
/// rejection, so every request wraps the policy in one of these reporters and
/// consults only its own recorder after a failure.
final class RequestScopedRedirectReporter: NSObject,
    URLSessionTaskDelegate,
    HTTPRedirectFailureReporting,
    @unchecked Sendable {
    private let policy: any HTTPRedirectFailureReporting
    private let lock = NSLock()
    private var sawRejection = false

    init(policy: any HTTPRedirectFailureReporting) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        policy.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        ) { [weak self] decision in
            if decision == nil, let self {
                self.lock.lock()
                self.sawRejection = true
                self.lock.unlock()
            }
            completionHandler(decision)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        policy.urlSession(session, task: task, didCompleteWithError: error)
    }

    func consumeUnsafeRedirect() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = sawRejection
        sawRejection = false
        return value
    }
}

/// Per-task delegate for strict, snapshot-backed Range reads.
///
/// `download(for:delegate:)` only guarantees task-level callbacks for its
/// delegate argument. `didCreateTask` is synchronous and runs before resume, so
/// observing the task's documented `Progress` object here catches a bad final
/// response or an oversized transfer without relying on download-only delegate
/// callbacks. The response body itself stays in URLSession's temporary file.
private final class BoundedRangeTaskDelegate: NSObject,
    URLSessionTaskDelegate,
    HTTPRedirectFailureReporting,
    @unchecked Sendable {
    private struct State {
        var responseWasChecked = false
        var failure: ResourceSourceError?
        var invalidatesRangeCapability = false
        var observations: [NSKeyValueObservation] = []
    }

    private let maximumBytes: Int64
    private let forwardingDelegate: (any HTTPRedirectFailureReporting)?
    private let validateResponse: @Sendable (HTTPURLResponse) -> ResourceSourceError?
    /// `If-Range` 请求里 200 表示对象已变化而不是不支持 Range；此时失败
    /// 不得清除已验证的 Range 能力。
    private let treats200AsCapabilityLoss: Bool
    private let lock = NSLock()
    private var state = State()

    init(
        maximumBytes: Int64,
        forwardingDelegate: (any URLSessionTaskDelegate)?,
        treats200AsCapabilityLoss: Bool = true,
        validateResponse: @escaping @Sendable (HTTPURLResponse) -> ResourceSourceError?
    ) {
        self.maximumBytes = maximumBytes
        self.forwardingDelegate = forwardingDelegate as? any HTTPRedirectFailureReporting
        self.treats200AsCapabilityLoss = treats200AsCapabilityLoss
        self.validateResponse = validateResponse
    }

    func urlSession(
        _ session: URLSession,
        didCreateTask task: URLSessionTask
    ) {
        let progress = task.progress
        let totalObservation = progress.observe(
            \.totalUnitCount,
            options: [.initial, .new]
        ) { [weak self, weak task] _, _ in
            guard let self, let task else { return }
            inspect(task)
        }
        let completedObservation = progress.observe(
            \.completedUnitCount,
            options: [.initial, .new]
        ) { [weak self, weak task] _, _ in
            guard let self, let task else { return }
            inspect(task)
        }

        lock.lock()
        state.observations = [totalObservation, completedObservation]
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let forwardingDelegate else {
            completionHandler(request)
            return
        }
        forwardingDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        forwardingDelegate?.urlSession(
            session,
            task: task,
            didCompleteWithError: error
        )
    }

    func consumeUnsafeRedirect() -> Bool {
        forwardingDelegate?.consumeUnsafeRedirect() ?? false
    }

    func failure() -> ResourceSourceError? {
        lock.lock()
        defer { lock.unlock() }
        return state.failure
    }

    func invalidatesRangeCapability() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.invalidatesRangeCapability
    }

    func stopObserving() {
        let observations: [NSKeyValueObservation]
        lock.lock()
        observations = state.observations
        state.observations.removeAll()
        lock.unlock()
        observations.forEach { $0.invalidate() }
    }

    private func inspect(_ task: URLSessionTask) {
        let response = task.response as? HTTPURLResponse
        let bytesReceived = task.countOfBytesReceived
        let bytesExpected = task.countOfBytesExpectedToReceive
        var shouldCancel = false

        lock.lock()
        if state.failure == nil,
           !state.responseWasChecked,
           let response,
           !Self.isIntermediateResponse(response.statusCode) {
            state.responseWasChecked = true
            state.failure = validateResponse(response)
            if state.failure != nil,
               response.statusCode == 200,
               treats200AsCapabilityLoss {
                state.invalidatesRangeCapability = true
            }
        }
        if state.failure == nil,
           (bytesReceived > maximumBytes
                || (state.responseWasChecked
                    && bytesExpected >= 0
                    && bytesExpected > maximumBytes)) {
            state.failure = .invalidResponse
        }
        shouldCancel = state.failure != nil
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    private static func isIntermediateResponse(_ statusCode: Int) -> Bool {
        (300..<400).contains(statusCode) || statusCode == 401 || statusCode == 407
    }
}

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
/// 能力边界：支持连接探测（HEAD 未声明 Range 或返回 405/501 时，降级为
/// 1 字节 Range GET 并把有效证据回写能力缓存）、HEAD 元数据（206 探测时从 `Content-Range` 解析
/// 总长度）、GET 数据读取和可选 Range。服务器未确认支持 Range 前不声称
/// `rangeRead`；Range 能力按“逻辑路径 + 直链 URL”缓存已验证证据。
/// 206 分片必须通过 `Content-Range` 单位/起止/总长度与响应体长度校验才会
/// 交给查看器；枚举阶段会拒绝包含非 http/https scheme 的来源。
/// 服务器忽略 Range 头返回全量 200 时，用可取消的流式读取只消费请求区间，
/// 并在超过大小预算时返回可行动错误，不把整文件载入内存。
struct HTTPSourceAdapter: ResourceSourceAdapter {
    /// 200 全量回退时允许消费的最大字节数；超过即返回 `responseTooLarge`。
    static let defaultMaxRangeFallbackBytes: Int64 = 50 * 1024 * 1024

    /// 生产远端请求不复用应用共享的缓存、Cookie 或凭证状态。
    static func makeDefaultSessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

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
    /// WebDAV 可注入同源重定向策略；普通 HTTP 直链保持系统既有策略。
    private let taskDelegate: URLSessionTaskDelegate?
    private let timeout: TimeInterval
    private let maxRangeFallbackBytes: Int64
    /// 已验证的 Range 能力缓存：只有服务端响应证据才能写入。
    private let verifiedRangeCapability = VerifiedRangeCapability()

    init(
        source: ResourceSource,
        descriptors: [HTTPResourceDescriptor],
        session: URLSession? = nil,
        taskDelegate: URLSessionTaskDelegate? = nil,
        timeout: TimeInterval = 15,
        maxRangeFallbackBytes: Int64 = HTTPSourceAdapter.defaultMaxRangeFallbackBytes
    ) {
        self.source = source
        self.taskDelegate = taskDelegate
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
            self.session = URLSession(
                configuration: Self.makeDefaultSessionConfiguration(timeout: timeout)
            )
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
            if Self.acceptsByteRanges(response) {
                verifiedRangeCapability.set(true, for: key)
                return
            }
        } catch ResourceSourceError.httpStatus(let code) where code == 405 || code == 501 {
            // HEAD is optional. Continue with the same real Range probe used
            // when HEAD succeeds without advertising byte ranges.
        } catch ResourceSourceError.httpStatus(let code) where code == 416 {
            verifiedRangeCapability.set(false, for: key)
            return
        }

        // A number of gateways answer HEAD themselves but only reveal byte-range
        // support after redirecting a real GET.
        do {
            _ = try await probeRangeMetadata(descriptor: descriptor, key: key)
        } catch ResourceSourceError.httpStatus(let code) where code == 416 {
            // A reachable endpoint that rejects bytes=0-0 can still connect, but
            // it has not proved a usable random-read contract.
            verifiedRangeCapability.set(false, for: key)
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
            if metadata.acceptsRanges {
                verifiedRangeCapability.set(true, for: key)
                return metadata
            }
            do {
                let rangeMetadata = try await probeRangeMetadata(
                    descriptor: descriptor,
                    key: key
                )
                return Self.mergingRangeEvidence(base: metadata, probe: rangeMetadata)
            } catch ResourceSourceError.httpStatus(let code) where code == 416 {
                verifiedRangeCapability.set(false, for: key)
                return metadata
            }
        } catch ResourceSourceError.httpStatus(let code) where code == 405 || code == 501 {
            return try await probeRangeMetadata(
                descriptor: descriptor,
                key: key
            )
        }
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        let descriptor = try descriptor(for: item)
        guard let range else {
            // 快照已声明完整大小时走有界下载：正文写入临时文件、超出预算即取消、
            // 交付前执行精确长度校验，不再无界缓冲整个响应体。
            if let expectedLength = item.metadata.byteSize, expectedLength >= 0 {
                return try await readBoundedFullBody(
                    descriptor: descriptor,
                    expectedLength: expectedLength,
                    snapshotRevision: item.metadata.revision
                )
            }
            // 无已知大小的读取保留既有行为与错误映射。
            let (data, _) = try await performRequest(method: "GET", descriptor: descriptor, headers: [:])
            return data
        }
        guard range.validatedLength != nil else {
            throw ResourceSourceError.invalidReference
        }

        let key = capabilityKey(for: descriptor)
        let expectedTotalLength = item.metadata.acceptsRanges
            ? item.metadata.byteSize.flatMap { $0 > 0 ? $0 : nil }
            : nil

        if let expectedTotalLength {
            return try await readStrictRange(
                descriptor: descriptor,
                range: range,
                expectedTotalLength: expectedTotalLength,
                snapshotRevision: item.metadata.revision,
                key: key
            )
        }

        let (response, bytes) = try await performStreamingRequest(
            method: "GET",
            descriptor: descriptor,
            headers: [
                "Range": range.httpHeaderValue,
                "Accept-Encoding": "identity"
            ]
        )
        switch response.statusCode {
        case 206:
            return try await validatedPartialData(
                from: bytes,
                response: response,
                requested: range,
                key: key,
                expectedTotalLength: expectedTotalLength
            )
        case 200:
            if expectedTotalLength != nil {
                bytes.task.cancel()
                verifiedRangeCapability.set(false, for: key)
                throw ResourceSourceError.invalidResponse
            }
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
        guard item.kind != .folder, !item.metadata.isDirectory else {
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
            (data, response) = try await session.data(for: request, delegate: taskDelegate)
        } catch {
            if let redirectPolicy = taskDelegate as? any HTTPRedirectFailureReporting,
               redirectPolicy.consumeUnsafeRedirect() {
                throw ResourceSourceError.unsafeRedirect
            }
            throw ResourceSourceError.mapping(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResourceSourceError.unavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw responseError(for: httpResponse)
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
            (bytes, response) = try await session.bytes(for: request, delegate: taskDelegate)
        } catch {
            if let redirectPolicy = taskDelegate as? any HTTPRedirectFailureReporting,
               redirectPolicy.consumeUnsafeRedirect() {
                throw ResourceSourceError.unsafeRedirect
            }
            throw ResourceSourceError.mapping(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ResourceSourceError.unavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            bytes.task.cancel()
            throw responseError(for: httpResponse)
        }
        return (httpResponse, bytes)
    }

    /// Strict session Range path. The response body is written by URLSession to
    /// a temporary file, with the task delegate cancelling at the first
    /// documented progress update that proves a bad response or an oversized
    /// requested fragment.
    ///
    /// Object validator contract: when the session snapshot carries a strong
    /// ETag, the request sends `If-Range` so an honoring origin answers a
    /// changed object with 200 instead of fragments of a different version;
    /// that 200 maps to `invalidResponse` without touching Range capability.
    /// Same-origin 206 responses additionally have their ETag/Last-Modified
    /// compared against the snapshot revision. Cross-origin signed content
    /// hosts use unrelated validators, so the comparison stays same-origin.
    private func readStrictRange(
        descriptor: HTTPResourceDescriptor,
        range: ResourceByteRange,
        expectedTotalLength: Int64,
        snapshotRevision: ResourceRevision,
        key: CapabilityKey
    ) async throws -> Data {
        guard let expectedLength = range.validatedLength,
              expectedLength > 0,
              range.upperBound < expectedTotalLength else {
            throw ResourceSourceError.invalidReference
        }

        let ifRangeValue = Self.ifRangeValue(for: snapshotRevision)
        let requestOrigin = descriptor.url
        let boundedDelegate = BoundedRangeTaskDelegate(
            maximumBytes: expectedLength,
            forwardingDelegate: taskDelegate,
            treats200AsCapabilityLoss: ifRangeValue == nil
        ) { response in
            if !(200..<300).contains(response.statusCode) {
                return .http(statusCode: response.statusCode)
            }
            guard response.statusCode == 206 else {
                return .invalidResponse
            }
            do {
                try Self.validateStrictPartialResponse(
                    response,
                    requested: range,
                    expectedTotalLength: expectedTotalLength,
                    expectedLength: expectedLength
                )
            } catch let error as ResourceSourceError {
                return error
            } catch {
                return .invalidResponse
            }
            if Self.hasValidatorMismatch(
                response: response,
                snapshot: snapshotRevision,
                requestOrigin: requestOrigin
            ) {
                return .invalidResponse
            }
            return nil
        }
        defer { boundedDelegate.stopObserving() }
        var headers = [
            "Range": range.httpHeaderValue,
            "Accept-Encoding": "identity"
        ]
        if let ifRangeValue {
            headers["If-Range"] = ifRangeValue
        }
        let request = makeRequest(
            method: "GET",
            descriptor: descriptor,
            headers: headers
        )

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(
                for: request,
                delegate: boundedDelegate
            )
        } catch {
            if Task.isCancelled {
                throw ResourceSourceError.cancelled
            }
            if boundedDelegate.consumeUnsafeRedirect() {
                throw ResourceSourceError.unsafeRedirect
            }
            if let failure = boundedDelegate.failure() {
                if boundedDelegate.invalidatesRangeCapability() {
                    verifiedRangeCapability.set(false, for: key)
                }
                throw failure
            }
            throw ResourceSourceError.mapping(error)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResourceSourceError.unavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw responseError(for: httpResponse)
        }
        guard httpResponse.statusCode == 206 else {
            if httpResponse.statusCode == 200, ifRangeValue == nil {
                verifiedRangeCapability.set(false, for: key)
            }
            throw ResourceSourceError.invalidResponse
        }
        try Self.validateStrictPartialResponse(
            httpResponse,
            requested: range,
            expectedTotalLength: expectedTotalLength,
            expectedLength: expectedLength
        )
        if Self.hasValidatorMismatch(
            response: httpResponse,
            snapshot: snapshotRevision,
            requestOrigin: requestOrigin
        ) {
            throw ResourceSourceError.invalidResponse
        }
        guard boundedDelegate.failure() == nil else {
            if boundedDelegate.invalidatesRangeCapability() {
                verifiedRangeCapability.set(false, for: key)
            }
            throw boundedDelegate.failure() ?? ResourceSourceError.invalidResponse
        }

        let data: Data
        do {
            data = try Self.readBoundedTemporaryFile(
                at: temporaryURL,
                expectedLength: expectedLength
            )
        } catch let error as ResourceSourceError {
            throw error
        } catch {
            throw ResourceSourceError.mapping(error)
        }
        guard !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }
        verifiedRangeCapability.set(true, for: key)
        return data
    }

    /// Bounded full-body path for reads whose session snapshot proves the
    /// complete size. The body is streamed by URLSession into a temporary
    /// file; the per-task delegate cancels as soon as the final response is
    /// not a plain identity 200 or the transfer exceeds the declared size.
    /// Delivery requires the exact snapshot length — a truncated or padded
    /// body maps to `invalidResponse` instead of silently reaching viewers.
    private func readBoundedFullBody(
        descriptor: HTTPResourceDescriptor,
        expectedLength: Int64,
        snapshotRevision: ResourceRevision
    ) async throws -> Data {
        let requestOrigin = descriptor.url
        let boundedDelegate = BoundedRangeTaskDelegate(
            maximumBytes: expectedLength,
            forwardingDelegate: taskDelegate
        ) { response in
            if !(200..<300).contains(response.statusCode) {
                return .http(statusCode: response.statusCode)
            }
            // 完整读取只接受 200；206/204 等其他 2xx 都不是完整正文的合法应答。
            guard response.statusCode == 200 else {
                return .invalidResponse
            }
            if let contentEncoding = Self.headerValue("Content-Encoding", in: response),
               contentEncoding.caseInsensitiveCompare("identity") != .orderedSame {
                return .invalidResponse
            }
            if response.expectedContentLength >= 0,
               response.expectedContentLength != expectedLength {
                return .invalidResponse
            }
            if Self.hasValidatorMismatch(
                response: response,
                snapshot: snapshotRevision,
                requestOrigin: requestOrigin
            ) {
                return .invalidResponse
            }
            return nil
        }
        defer { boundedDelegate.stopObserving() }
        let request = makeRequest(
            method: "GET",
            descriptor: descriptor,
            headers: ["Accept-Encoding": "identity"]
        )

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(
                for: request,
                delegate: boundedDelegate
            )
        } catch {
            if Task.isCancelled {
                throw ResourceSourceError.cancelled
            }
            if boundedDelegate.consumeUnsafeRedirect() {
                throw ResourceSourceError.unsafeRedirect
            }
            if let failure = boundedDelegate.failure() {
                throw failure
            }
            throw ResourceSourceError.mapping(error)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResourceSourceError.unavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw responseError(for: httpResponse)
        }
        guard httpResponse.statusCode == 200 else {
            throw ResourceSourceError.invalidResponse
        }
        // 进度观察是提前中止的手段，不是唯一校验点：完成后的最终响应必须
        // 重新通过同一套合同检查，避免快速完成的传输绕过响应头校验。
        if let contentEncoding = Self.headerValue("Content-Encoding", in: httpResponse),
           contentEncoding.caseInsensitiveCompare("identity") != .orderedSame {
            throw ResourceSourceError.invalidResponse
        }
        if httpResponse.expectedContentLength >= 0,
           httpResponse.expectedContentLength != expectedLength {
            throw ResourceSourceError.invalidResponse
        }
        if Self.hasValidatorMismatch(
            response: httpResponse,
            snapshot: snapshotRevision,
            requestOrigin: requestOrigin
        ) {
            throw ResourceSourceError.invalidResponse
        }
        guard boundedDelegate.failure() == nil else {
            throw boundedDelegate.failure() ?? ResourceSourceError.invalidResponse
        }

        let data: Data
        do {
            data = try Self.readBoundedTemporaryFile(
                at: temporaryURL,
                expectedLength: expectedLength,
                allowsEmpty: true
            )
        } catch let error as ResourceSourceError {
            throw error
        } catch {
            throw ResourceSourceError.mapping(error)
        }
        guard !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }
        return data
    }

    private func responseError(for response: HTTPURLResponse) -> ResourceSourceError {
        if taskDelegate != nil, (300..<400).contains(response.statusCode) {
            return .unsafeRedirect
        }
        return .http(statusCode: response.statusCode)
    }

    /// Performs a real one-byte GET so gateways that omit `Accept-Ranges` from
    /// HEAD can still prove support. A 206 response is body-validated through
    /// the same path as ordinary reads; a 200 response is cancelled immediately
    /// and contributes only response headers, never Range capability.
    private func probeRangeMetadata(
        descriptor: HTTPResourceDescriptor,
        key: CapabilityKey
    ) async throws -> ResourceMetadata {
        let range = ResourceByteRange(lowerBound: 0, upperBound: 0)
        let stream: (HTTPURLResponse, URLSession.AsyncBytes)
        do {
            stream = try await performStreamingRequest(
                method: "GET",
                descriptor: descriptor,
                headers: [
                    "Range": range.httpHeaderValue,
                    "Accept-Encoding": "identity"
                ]
            )
        } catch ResourceSourceError.httpStatus(let code) where code == 416 {
            verifiedRangeCapability.set(false, for: key)
            throw ResourceSourceError.httpStatus(code)
        }
        let (response, bytes) = stream
        switch response.statusCode {
        case 206:
            guard Self.verifiedRangeProbeEvidence(from: response) else {
                bytes.task.cancel()
                verifiedRangeCapability.set(false, for: key)
                throw ResourceSourceError.invalidResponse
            }
            do {
                _ = try await validatedPartialData(
                    from: bytes,
                    response: response,
                    requested: range,
                    key: key
                )
            } catch {
                verifiedRangeCapability.set(false, for: key)
                throw error
            }
            return Self.partialGetMetadata(from: response, descriptor: descriptor)
        case 200:
            bytes.task.cancel()
            verifiedRangeCapability.set(false, for: key)
            return Self.partialGetMetadata(from: response, descriptor: descriptor)
        default:
            bytes.task.cancel()
            verifiedRangeCapability.set(false, for: key)
            throw ResourceSourceError.invalidResponse
        }
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
        key: CapabilityKey,
        expectedTotalLength: Int64? = nil
    ) async throws -> Data {
        guard let contentRange = Self.parseContentRange(from: response) else {
            bytes.task.cancel()
            throw ResourceSourceError.invalidResponse
        }
        if let expectedTotalLength,
           contentRange.total != expectedTotalLength {
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

    private static func validateStrictPartialResponse(
        _ response: HTTPURLResponse,
        requested: ResourceByteRange,
        expectedTotalLength: Int64,
        expectedLength: Int64
    ) throws {
        guard response.statusCode == 206,
              let contentRange = parseContentRange(from: response),
              contentRange.first == requested.lowerBound,
              contentRange.last == requested.upperBound,
              contentRange.total == expectedTotalLength,
              contentRange.last < expectedTotalLength else {
            throw ResourceSourceError.invalidResponse
        }
        if response.expectedContentLength >= 0,
           response.expectedContentLength != expectedLength {
            throw ResourceSourceError.invalidResponse
        }
        if let contentEncoding = headerValue("Content-Encoding", in: response),
           contentEncoding.caseInsensitiveCompare("identity") != .orderedSame {
            throw ResourceSourceError.invalidResponse
        }
    }

    /// Reads at most one byte beyond the expected fragment. This keeps the
    /// in-process allocation bounded even if download progress reporting was
    /// delayed or the temporary file changed unexpectedly.
    private static func readBoundedTemporaryFile(
        at url: URL,
        expectedLength: Int64,
        allowsEmpty: Bool = false
    ) throws -> Data {
        if allowsEmpty, expectedLength == 0 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let probe = try handle.read(upToCount: 1)
            guard probe == nil || probe?.isEmpty == true else {
                throw ResourceSourceError.invalidResponse
            }
            return Data()
        }
        guard expectedLength > 0,
              expectedLength < Int64.max,
              let expectedCount = Int(exactly: expectedLength),
              let readLimit = Int(exactly: expectedLength + 1) else {
            throw ResourceSourceError.invalidResponse
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(expectedCount)

        while data.count < readLimit {
            let remaining = readLimit - data.count
            let chunkSize = min(256 * 1024, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count == expectedCount else {
            throw ResourceSourceError.invalidResponse
        }
        return data
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
        let hasVerifiedPartialEvidence = response.statusCode == 206
            ? verifiedRangeProbeEvidence(from: response)
            : false
        let byteSize: Int64?
        if response.statusCode == 206 {
            // A partial HEAD response has the same single-fragment semantics as
            // a partial GET: never treat Content-Length (often 1) as full size.
            // Without a valid 0-0 probe shape, the response is not evidence for
            // either the complete size or Range support.
            byteSize = hasVerifiedPartialEvidence
                ? contentRangeTotalLength(from: response)
                : nil
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
            acceptsRanges: response.statusCode == 206
                ? hasVerifiedPartialEvidence
                : acceptsByteRanges(response),
            revision: revision(from: response, modifiedAt: modifiedAt, byteSize: byteSize)
        )
    }

    /// Range GET 探测元数据：206 的 `Content-Length` 是单字节分片大小，
    /// 所以完整大小只能来自合法 `Content-Range` 总长度。若服务端忽略 Range
    /// 返回 200，则其 Content-Length 才可能代表完整响应大小。
    private static func partialGetMetadata(
        from response: HTTPURLResponse,
        descriptor: HTTPResourceDescriptor
    ) -> ResourceMetadata {
        let byteSize: Int64?
        if response.statusCode == 206 {
            // A probe response is trustworthy only when its 0-0 evidence and
            // optional fragment length both pass the shared verifier.
            byteSize = verifiedRangeProbeEvidence(from: response)
                ? contentRangeTotalLength(from: response)
                : nil
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
            acceptsRanges: verifiedRangeProbeEvidence(from: response),
            revision: revision(from: response, modifiedAt: modifiedAt, byteSize: byteSize)
        )
    }

    private static func mergingRangeEvidence(
        base: ResourceMetadata,
        probe: ResourceMetadata
    ) -> ResourceMetadata {
        ResourceMetadata(
            byteSize: probe.byteSize ?? base.byteSize,
            modifiedAt: base.modifiedAt ?? probe.modifiedAt,
            mimeType: base.mimeType ?? probe.mimeType,
            typeIdentifier: base.typeIdentifier ?? probe.typeIdentifier,
            isDirectory: false,
            acceptsRanges: probe.acceptsRanges,
            revision: probe.revision.isKnown ? probe.revision : base.revision
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
            "X-Object-Version",
            "X-File-Version",
            "X-Asset-Version",
            "X-Revision",
            "Content-Version"
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

    /// `If-Range` 只允许强 validator：带引号且不含 `W/` 前缀的 ETag。
    /// 弱 ETag 与 modified/size 证据不生成 `If-Range`，只参与响应侧比较。
    private static func ifRangeValue(for revision: ResourceRevision) -> String? {
        guard case .etag(let value) = revision else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.hasPrefix("\""),
              trimmed.hasSuffix("\"") else {
            return nil
        }
        return trimmed
    }

    /// 同源响应携带与快照可比的 validator 时执行版本一致性比较。
    ///
    /// 返回 true 表示证据证明对象已被替换（同长度换版本也会被发现）。
    /// 跨 origin 内容主机的 validator 与来源无关，因此跳过比较；缺失响应头
    /// 视为无证据，不作为失败依据。
    private static func hasValidatorMismatch(
        response: HTTPURLResponse,
        snapshot: ResourceRevision,
        requestOrigin: URL
    ) -> Bool {
        guard let responseURL = response.url,
              sameOrigin(responseURL, requestOrigin) else {
            return false
        }
        switch snapshot {
        case .etag(let expected):
            guard let actual = headerValue("ETag", in: response) else { return false }
            return etagOpaqueValue(expected) != etagOpaqueValue(actual)
        case .modifiedAndSize(let expectedDate, _):
            guard let actualText = headerValue("Last-Modified", in: response),
                  let actualDate = parseHTTPDate(actualText) else {
                return false
            }
            return actualDate != expectedDate
        case .serverVersion, .unknown:
            return false
        }
    }

    /// 比较 ETag 的 opaque 值：忽略弱标记前缀、首尾空白与成对引号。
    /// opaque 值不同即证明对象已变化；弱匹配足以用于变更检测。
    ///
    /// 引号归一是必要的：部分 WebDAV 实现在 PROPFIND `getetag` 里给无引号
    /// 值，而同一对象的 GET 响应头给带引号的 RFC 形式；两者指向同一对象，
    /// 不得因表示差异误判为版本替换。
    private static func etagOpaqueValue(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("W/") || trimmed.hasPrefix("w/") {
            trimmed = String(trimmed.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort(for: lhs)) == (rhs.port ?? defaultPort(for: rhs))
    }

    private static func defaultPort(for url: URL) -> Int {
        url.scheme?.lowercased() == "https" ? 443 : 80
    }

    /// 动态 Range 探测的统一证据规则，`connect()` 与 `fetchMetadata()` 共用。
    ///
    /// 只有同时满足以下条件的 206 才确认 Range 支持：
    /// - `Content-Range` 为合法的 `bytes 0-0/<total>`，与探测区间 `bytes=0-0` 对齐；
    /// - 总长度必须已知且覆盖终点（total > last）；
    /// - 响应携带 `Content-Length` 时必须等于探测分片大小，正文仍必须实际校验为 1 字节。
    /// malformed 206 不是有效证据，绝不能据此把能力缓存为支持 Range。
    private static func verifiedRangeProbeEvidence(from response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 206,
              let contentRange = parseContentRange(from: response),
              contentRange.first == 0,
              contentRange.last == 0,
              let total = contentRange.total,
              total > contentRange.last else {
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
