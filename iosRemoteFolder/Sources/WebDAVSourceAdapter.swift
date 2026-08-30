import Foundation
import os.lock
import UniformTypeIdentifiers

/// One transport invariant shared by the form, persistence, and adapter
/// boundaries: clear-text HTTP remains available only for anonymous sources.
enum RemoteSourceTransportPolicy {
    static func permitsCredentials(endpoint: URL, hasCredentials: Bool) -> Bool {
        !hasCredentials || endpoint.scheme?.lowercased() == "https"
    }
}

/// Standard WebDAV / Alist `/dav/` source adapter.
///
/// Directory facts come from a namespaced `PROPFIND`. Content reads are delegated
/// to the existing HTTP adapter so GET, Range, cancellation and response-size
/// rules remain identical across direct HTTP and WebDAV sources. Credentials are
/// held only by this in-memory adapter and are never projected into domain items.
actor WebDAVSourceAdapter: ResourceSourceAdapter {
    nonisolated let source: ResourceSource

    private let endpoint: URL
    private let requestHeaders: [String: String]
    private let redirectDelegate: WebDAVRedirectDelegate
    private let session: URLSession
    private let timeout: TimeInterval
    private var metadataByPath: [String: ResourceMetadata] = [:]
    private static let maxPropfindResponseBytes = 2 * 1024 * 1024

    init(
        source: ResourceSource,
        endpoint: URL,
        username: String? = nil,
        password: String? = nil,
        session: URLSession? = nil,
        timeout: TimeInterval = 15
    ) throws {
        guard source.kind == .webdav || source.kind == .alist else {
            throw ResourceSourceError.invalidReference
        }
        guard timeout > 0, timeout.isFinite else {
            throw ResourceSourceError.invalidReference
        }
        let normalizedEndpoint = try Self.normalizedEndpoint(endpoint)
        self.timeout = timeout

        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPassword = password ?? ""
        guard RemoteSourceTransportPolicy.permitsCredentials(
            endpoint: normalizedEndpoint,
            hasCredentials: !trimmedUsername.isEmpty || !trimmedPassword.isEmpty
        ) else {
            throw ResourceSourceError.insecureCredentialTransport
        }
        let authorizationHeader: String?
        if !trimmedUsername.isEmpty || !trimmedPassword.isEmpty {
            let credential = Data("\(trimmedUsername):\(trimmedPassword)".utf8)
                .base64EncodedString()
            let header = "Basic \(credential)"
            authorizationHeader = header
            self.requestHeaders = ["Authorization": header]
        } else {
            authorizationHeader = nil
            self.requestHeaders = [:]
        }
        self.source = source
        self.endpoint = normalizedEndpoint
        self.redirectDelegate = try WebDAVRedirectDelegate(
            endpoint: normalizedEndpoint,
            authorization: authorizationHeader
        )

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func connect() async throws {
        _ = try await propfind(path: .root, depth: 0, isCollection: true)
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        let entries = try await propfind(path: path, depth: 1, isCollection: true)
        var seenKinds: [String: Bool] = [:]
        var items: [ResourceItem] = []

        for entry in entries {
            let itemPath = try logicalPath(from: entry.href)
            guard itemPath != path else { continue }
            guard itemPath.isUnder(path) else {
                throw ResourceSourceError.invalidResponse
            }
            guard itemPath.components.count == path.components.count + 1 else {
                // A compliant Depth: 1 response should not contain grandchildren.
                continue
            }

            let isDirectory = entry.isCollection
            if let previousKind = seenKinds[itemPath.normalized], previousKind != isDirectory {
                throw ResourceSourceError.invalidReference
            }
            guard seenKinds.updateValue(isDirectory, forKey: itemPath.normalized) == nil else {
                throw ResourceSourceError.invalidReference
            }

            let metadata = metadata(for: entry, isDirectory: isDirectory)
            metadataByPath[itemPath.normalized] = metadata
            items.append(makeItem(entry: entry, path: itemPath, metadata: metadata))
        }

        return items.sorted {
            if $0.kind == .folder, $1.kind != .folder { return true }
            if $0.kind != .folder, $1.kind == .folder { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        let path = try validatedFilePath(for: item)
        let supportsRange = metadataByPath[path.normalized]?.acceptsRanges
            ?? item.metadata.acceptsRanges
        return .remoteHTTP(
            .init(
                url: resourceURL(for: path, isDirectory: false),
                method: "GET",
                headers: requestHeaders,
                supportsRange: supportsRange
            )
        )
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        let path = try validatedFilePath(for: item)
        let entries = try await propfind(path: path, depth: 0, isCollection: false)
        let matchingEntries = try entries.filter { entry in
            try logicalPath(from: entry.href) == path
        }
        guard matchingEntries.count == 1, let entry = matchingEntries.first else {
            if matchingEntries.isEmpty {
                throw ResourceSourceError.notFound
            }
            throw ResourceSourceError.invalidReference
        }
        guard !entry.isCollection else {
            throw ResourceSourceError.invalidReference
        }

        let davMetadata = metadata(for: entry, isDirectory: false)
        let descriptor = HTTPResourceDescriptor(
            path: path.normalized,
            name: item.name,
            kind: item.kind,
            url: resourceURL(for: path, isDirectory: false),
            headers: requestHeaders
        )
        // 每个逻辑操作使用独立的 redirect 记录器，保证拒绝跳转的错误只
        // 归属到触发它的请求，不被并发请求消费。
        let httpAdapter = HTTPSourceAdapter(
            source: source,
            descriptors: [descriptor],
            session: session,
            taskDelegate: RequestScopedRedirectReporter(policy: redirectDelegate),
            timeout: timeout
        )

        let httpMetadata: ResourceMetadata?
        do {
            // HEAD/Range probing supplies concrete Accept-Ranges and a second
            // revision source where the DAV property set is incomplete.
            httpMetadata = try await httpAdapter.fetchMetadata(for: item)
        } catch ResourceSourceError.httpStatus(let code) where code == 405 || code == 501 {
            httpMetadata = nil
        } catch ResourceSourceError.invalidResponse {
            // A malformed optional probe must not discard otherwise valid DAV
            // metadata; it only means Range evidence remains conservative.
            httpMetadata = nil
        }

        // Keep the optional transport probe separate from consistency checks:
        // once both metadata sets are valid, conflicting object sizes are fatal.
        let metadata: ResourceMetadata
        if let httpMetadata {
            metadata = try merge(dav: davMetadata, http: httpMetadata)
        } else {
            metadata = davMetadata
        }

        metadataByPath[path.normalized] = metadata
        return metadata
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        let path = try validatedFilePath(for: item)
        let descriptor = HTTPResourceDescriptor(
            path: path.normalized,
            name: item.name,
            kind: item.kind,
            url: resourceURL(for: path, isDirectory: false),
            headers: requestHeaders
        )
        let httpAdapter = HTTPSourceAdapter(
            source: source,
            descriptors: [descriptor],
            session: session,
            taskDelegate: RequestScopedRedirectReporter(policy: redirectDelegate),
            timeout: timeout
        )
        return try await httpAdapter.readData(for: item, range: range)
    }

    // MARK: - WebDAV request and response mapping

    private func propfind(
        path: ResourcePath,
        depth: Int,
        isCollection: Bool
    ) async throws -> [DAVEntry] {
        guard depth == 0 || depth == 1 else {
            throw ResourceSourceError.invalidReference
        }

        var request = URLRequest(
            url: resourceURL(for: path, isDirectory: isCollection),
            timeoutInterval: timeout
        )
        request.httpMethod = "PROPFIND"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (field, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = Data(Self.propfindBody.utf8)

        let data: Data
        let response: URLResponse
        let redirectReporter = RequestScopedRedirectReporter(policy: redirectDelegate)
        do {
            (data, response) = try await session.data(for: request, delegate: redirectReporter)
        } catch {
            if redirectReporter.consumeUnsafeRedirect() {
                throw ResourceSourceError.unsafeRedirect
            }
            throw ResourceSourceError.mapping(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResourceSourceError.unavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if (300..<400).contains(httpResponse.statusCode) {
                throw ResourceSourceError.unsafeRedirect
            }
            throw ResourceSourceError.http(statusCode: httpResponse.statusCode)
        }
        if let contentLength = Self.headerValue("Content-Length", in: httpResponse)
            .flatMap(Int64.init),
           contentLength > Int64(Self.maxPropfindResponseBytes) {
            throw ResourceSourceError.responseTooLarge
        }
        guard data.count <= Self.maxPropfindResponseBytes else {
            throw ResourceSourceError.responseTooLarge
        }
        let parser = DAVXMLParser()
        let entries: [DAVEntry]
        do {
            entries = try parser.parse(data)
        } catch {
            throw ResourceSourceError.invalidResponse
        }
        guard !entries.isEmpty else {
            throw ResourceSourceError.invalidResponse
        }
        return entries.filter { entry in
            guard let status = entry.statusCode else { return true }
            return (200..<300).contains(status)
        }
    }

    private func validatedFilePath(for item: ResourceItem) throws -> ResourcePath {
        guard item.sourceID == source.id,
              item.id.sourceID == source.id,
              item.id.logicalPath == item.path,
              item.kind != .folder,
              !item.metadata.isDirectory,
              let path = ResourcePath(rawValue: item.path),
              path.normalized == item.path else {
            throw ResourceSourceError.invalidReference
        }
        return path
    }

    private func makeItem(
        entry: DAVEntry,
        path: ResourcePath,
        metadata: ResourceMetadata
    ) -> ResourceItem {
        let displayName = entry.name.isEmpty
            ? (path.components.last ?? path.normalized)
            : entry.name
        let kind: ResourceKind = entry.isCollection
            ? .folder
            : Self.kind(for: displayName, mimeType: entry.mimeType)
        var capabilities: ResourceCapability = entry.isCollection
            ? [.list]
            : [.read, .download, .directURL]
        if !entry.isCollection && metadata.acceptsRanges {
            capabilities.insert(.rangeRead)
        }
        return ResourceItem(
            sourceID: source.id,
            logicalPath: path,
            name: displayName,
            kind: kind,
            metadata: metadata,
            capabilities: capabilities,
            accent: .recommended(for: kind)
        )
    }

    private func metadata(for entry: DAVEntry, isDirectory: Bool) -> ResourceMetadata {
        let byteSize = isDirectory ? nil : entry.byteSize
        let mimeType = isDirectory ? nil : entry.mimeType
        let modifiedAt = entry.modifiedAt
        return ResourceMetadata(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            mimeType: mimeType,
            typeIdentifier: isDirectory ? nil : Self.typeIdentifier(name: entry.name, mimeType: mimeType),
            isDirectory: isDirectory,
            acceptsRanges: false,
            revision: ResourceRevision.strongest(
                etag: entry.etag,
                serverVersion: entry.serverVersion,
                modifiedAt: modifiedAt,
                byteSize: byteSize
            )
        )
    }

    private func merge(dav: ResourceMetadata, http: ResourceMetadata) throws -> ResourceMetadata {
        if let davByteSize = dav.byteSize,
           let httpByteSize = http.byteSize,
           davByteSize != httpByteSize {
            throw ResourceSourceError.invalidResponse
        }
        let byteSize = http.byteSize ?? dav.byteSize
        let modifiedAt = http.modifiedAt ?? dav.modifiedAt
        let contentType = Self.preferredContentType(dav: dav, http: http)
        let revision = ResourceRevision.strongest(
            etag: Self.etag(from: dav.revision) ?? Self.etag(from: http.revision),
            serverVersion: Self.serverVersion(from: dav.revision)
                ?? Self.serverVersion(from: http.revision),
            modifiedAt: modifiedAt,
            byteSize: byteSize
        )
        return ResourceMetadata(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            mimeType: contentType.mimeType,
            typeIdentifier: contentType.typeIdentifier,
            isDirectory: false,
            acceptsRanges: http.acceptsRanges,
            revision: revision
        )
    }

    private static func preferredContentType(
        dav: ResourceMetadata,
        http: ResourceMetadata
    ) -> (mimeType: String?, typeIdentifier: String?) {
        let davMIME = normalizedMIMEType(dav.mimeType)
        let httpMIME = normalizedMIMEType(http.mimeType)
        let preferHTTP: Bool

        if davMIME == nil {
            preferHTTP = true
        } else if let davMIME, isGenericMIMEType(davMIME),
                  let httpMIME, !isGenericMIMEType(httpMIME) {
            preferHTTP = true
        } else if let davMIME, let httpMIME,
                  contentFamily(mimeType: davMIME, typeIdentifier: dav.typeIdentifier)
                    == contentFamily(mimeType: httpMIME, typeIdentifier: http.typeIdentifier),
                  contentFamily(mimeType: davMIME, typeIdentifier: dav.typeIdentifier) != nil,
                  mimeSpecificity(httpMIME) > mimeSpecificity(davMIME) {
            preferHTTP = true
        } else {
            // WebDAV getcontenttype describes the listed resource. Some Alist
            // backends return a generic or conflicting Content-Type for HEAD.
            preferHTTP = false
        }

        let primary = preferHTTP ? http : dav
        let secondary = preferHTTP ? dav : http
        let mimeType = primary.mimeType ?? secondary.mimeType
        let typeIdentifier = primary.typeIdentifier
            ?? mimeType.flatMap { normalizedMIMEType($0) }
                .flatMap { UTType(mimeType: $0)?.identifier }
            ?? secondary.typeIdentifier
        return (mimeType, typeIdentifier)
    }

    private enum ContentFamily {
        case pdf
        case text
        case image
        case video
        case audio
    }

    private static func contentFamily(
        mimeType: String?,
        typeIdentifier: String?
    ) -> ContentFamily? {
        let type = typeIdentifier.flatMap(UTType.init)
            ?? mimeType.flatMap { UTType(mimeType: $0) }
        if type?.conforms(to: .pdf) == true { return .pdf }
        if type?.conforms(to: .text) == true { return .text }
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .movie) == true { return .video }
        if type?.conforms(to: .audio) == true { return .audio }
        return nil
    }

    private static func normalizedMIMEType(_ value: String?) -> String? {
        guard let value = value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func isGenericMIMEType(_ mimeType: String) -> Bool {
        switch mimeType {
        case "application/octet-stream", "binary/octet-stream", "application/binary",
             "application/x-binary", "application/unknown", "application/x-unknown":
            return true
        default:
            return false
        }
    }

    private static func mimeSpecificity(_ mimeType: String) -> Int {
        if isGenericMIMEType(mimeType) { return 0 }
        if mimeType == "text/plain" { return 1 }
        return 2
    }

    private func resourceURL(for path: ResourcePath, isDirectory: Bool) -> URL {
        guard !path.isRoot else { return endpoint }
        var result = endpoint
        for component in path.components {
            result.appendPathComponent(component, isDirectory: false)
        }
        guard isDirectory else { return result }
        guard var components = URLComponents(url: result, resolvingAgainstBaseURL: false) else {
            return result
        }
        if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        return components.url ?? result
    }

    private func logicalPath(from href: String) throws -> ResourcePath {
        guard let hrefURL = URL(string: href, relativeTo: endpoint)?.absoluteURL,
              Self.sameOrigin(hrefURL, endpoint),
              hrefURL.query == nil,
              hrefURL.fragment == nil else {
            throw ResourceSourceError.invalidResponse
        }

        let baseComponents = try Self.decodedPathComponents(endpoint)
        let hrefComponents = try Self.decodedPathComponents(hrefURL)
        guard hrefComponents.count >= baseComponents.count,
              Array(hrefComponents.prefix(baseComponents.count)) == baseComponents else {
            throw ResourceSourceError.invalidResponse
        }
        let relative = hrefComponents.dropFirst(baseComponents.count)
        let logical = relative.isEmpty ? "/" : "/" + relative.joined(separator: "/")
        guard let path = ResourcePath(rawValue: logical) else {
            throw ResourceSourceError.invalidResponse
        }
        return path
    }

    nonisolated static func normalizedEndpoint(_ endpoint: URL) throws -> URL {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              endpoint.host != nil,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ResourceSourceError.invalidReference
        }
        let encodedPath = components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath
        components.percentEncodedPath = encodedPath.hasSuffix("/")
            ? encodedPath
            : encodedPath + "/"
        guard let normalized = components.url else {
            throw ResourceSourceError.invalidReference
        }
        return normalized
    }

    private static func decodedPathComponents(_ url: URL) throws -> [String] {
        let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
            ?? url.path
        return try encoded
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { component in
                guard let decoded = String(component).removingPercentEncoding else {
                    throw ResourceSourceError.invalidResponse
                }
                return decoded
            }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort(for: lhs)) == (rhs.port ?? defaultPort(for: rhs))
    }

    private static func defaultPort(for url: URL) -> Int {
        url.scheme?.lowercased() == "https" ? 443 : 80
    }

    private static func typeIdentifier(name: String, mimeType: String?) -> String? {
        if let mimeType, let type = UTType(mimeType: mimeType) {
            return type.identifier
        }
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension),
              !URL(fileURLWithPath: name).pathExtension.isEmpty else {
            return nil
        }
        return type.identifier
    }

    private static func kind(for name: String, mimeType: String?) -> ResourceKind {
        let type = mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
        if type?.conforms(to: .pdf) == true { return .pdf }
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .movie) == true { return .video }
        if type?.conforms(to: .audio) == true { return .audio }
        if type?.conforms(to: .text) == true {
            return name.lowercased().hasSuffix(".md") || name.lowercased().hasSuffix(".markdown")
                ? .markdown
                : .text
        }
        return .unknown
    }

    private static func etag(from revision: ResourceRevision) -> String? {
        guard case .etag(let value) = revision else { return nil }
        return value
    }

    private static func serverVersion(from revision: ResourceRevision) -> String? {
        guard case .serverVersion(let value) = revision else { return nil }
        return value
    }

    private static func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { key, _ in
            (key as? String)?.caseInsensitiveCompare(name) == .orderedSame
        }.flatMap { $0.value as? String }
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8" ?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:resourcetype />
        <d:displayname />
        <d:getcontentlength />
        <d:getlastmodified />
        <d:getetag />
        <d:getcontenttype />
        <d:getcontentversion />
      </d:prop>
    </d:propfind>
    """

    fileprivate struct DAVEntry: Sendable {
        let href: String
        let name: String
        let isCollection: Bool
        let byteSize: Int64?
        let modifiedAt: Date?
        let mimeType: String?
        let etag: String?
        let serverVersion: String?
        let statusCode: Int?
    }
}

/// URLSession task delegate used only by WebDAV/Alist requests.
///
/// DAV and authentication requests remain inside the configured root. Content
/// GET/HEAD requests may follow a storage-provider redirect only after every
/// source header is removed; the signed target URL remains request-local.
private final class WebDAVRedirectDelegate: NSObject, URLSessionTaskDelegate, HTTPRedirectFailureReporting, Sendable {
    private struct RedirectState: Sendable {
        var hasLeftTrustedRoot = false
        var hopCount = 0
    }

    private let scheme: String
    private let host: String
    private let port: Int
    private let basePathComponents: [String]
    private let authorization: String?
    private let redirectStates = OSAllocatedUnfairLock(
        initialState: [Int: RedirectState]()
    )
    private static let maximumRedirectHops = 10

    init(endpoint: URL, authorization: String?) throws {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = endpoint.host?.lowercased(),
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding else {
            throw ResourceSourceError.invalidReference
        }

        let pathComponents = decodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !pathComponents.contains("."), !pathComponents.contains("..") else {
            throw ResourceSourceError.invalidReference
        }

        self.scheme = scheme
        self.host = host
        self.port = endpoint.port ?? (scheme == "https" ? 443 : 80)
        self.basePathComponents = pathComponents
        self.authorization = authorization
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let responseURL = response.url,
              let expectedMethod = task.originalRequest?.httpMethod,
              request.httpMethod?.uppercased() == expectedMethod.uppercased() else {
            reject(task: task, completionHandler: completionHandler)
            return
        }

        let state = redirectStates.withLock { states -> RedirectState? in
            var state = states[task.taskIdentifier] ?? RedirectState()
            state.hopCount += 1
            guard state.hopCount <= Self.maximumRedirectHops else {
                states[task.taskIdentifier] = nil
                return nil
            }
            if !allowsTrustedRoot(responseURL) {
                state.hasLeftTrustedRoot = true
            }
            states[task.taskIdentifier] = state
            return state
        }
        guard let state,
              !Self.isHTTPSDowngrade(from: responseURL, to: url) else {
            reject(task: task, completionHandler: completionHandler)
            return
        }

        if allowsTrustedRoot(url) {
            guard !state.hasLeftTrustedRoot else {
                reject(task: task, completionHandler: completionHandler)
                return
            }
            var safeRequest = request
            if let authorization {
                safeRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
            } else {
                safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(safeRequest)
            return
        }

        guard allowsExternalContent(url, method: expectedMethod) else {
            reject(task: task, completionHandler: completionHandler)
            return
        }
        redirectStates.withLock { states in
            guard var state = states[task.taskIdentifier] else { return }
            state.hasLeftTrustedRoot = true
            states[task.taskIdentifier] = state
        }

        // Do not forward any source-defined header to a signed storage URL.
        // Only pure transport semantics survive the rebuild: Range (fragment
        // addressing) and Accept-Encoding (the strict length contract requires
        // identity bodies). If-Range carries the DAV origin's validator, which
        // an unrelated signed content host would treat as a mismatch and
        // answer with a full 200, so it must not cross the origin boundary.
        let originalRequest = task.originalRequest
        var safeRequest = URLRequest(url: url)
        safeRequest.httpShouldHandleCookies = false
        safeRequest.httpMethod = expectedMethod
        safeRequest.timeoutInterval = request.timeoutInterval
        for field in ["Range", "Accept-Encoding"] {
            if let value = originalRequest?.value(forHTTPHeaderField: field) {
                safeRequest.setValue(value, forHTTPHeaderField: field)
            }
        }
        completionHandler(safeRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        redirectStates.withLock { states in
            states[task.taskIdentifier] = nil
        }
    }

    /// 拒绝归属由每个请求自己的 `RequestScopedRedirectReporter` 记录；
    /// 共享策略不再保存可被并发请求错误消费的全局标志。
    func consumeUnsafeRedirect() -> Bool {
        false
    }

    private func reject(
        task: URLSessionTask,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        redirectStates.withLock { states in
            states[task.taskIdentifier] = nil
        }
        task.cancel()
        completionHandler(nil)
    }

    private static func isHTTPSDowngrade(from source: URL, to target: URL) -> Bool {
        source.scheme?.lowercased() == "https"
            && target.scheme?.lowercased() == "http"
    }

    private func allowsTrustedRoot(_ url: URL) -> Bool {
        guard let candidateScheme = url.scheme?.lowercased(),
              let candidateHost = url.host?.lowercased(),
              candidateScheme == scheme,
              candidateHost == host,
              (url.port ?? (candidateScheme == "https" ? 443 : 80)) == port,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding else {
            return false
        }

        let pathComponents = decodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !pathComponents.contains("."),
              !pathComponents.contains(".."),
              pathComponents.starts(with: basePathComponents) else {
            return false
        }
        return true
    }

    private func allowsExternalContent(_ url: URL, method: String) -> Bool {
        let normalizedMethod = method.uppercased()
        guard normalizedMethod == "GET" || normalizedMethod == "HEAD",
              let candidateScheme = url.scheme?.lowercased(),
              candidateScheme == "http" || candidateScheme == "https",
              !(scheme == "https" && candidateScheme == "http"),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding else {
            return false
        }
        let pathComponents = decodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return !pathComponents.contains(".") && !pathComponents.contains("..")
    }
}

private final class DAVXMLParser: NSObject, XMLParserDelegate {
    private struct PropertyDraft {
        var displayName: String?
        var byteSize: Int64?
        var modifiedAt: Date?
        var mimeType: String?
        var etag: String?
        var serverVersion: String?
        var isCollection = false
        var sawResourceType = false
    }

    private struct PropstatDraft {
        var properties = PropertyDraft()
        var statusCode: Int?
    }

    private struct Draft {
        var href: String?
        var properties = PropertyDraft()
        var responseStatusCode: Int?
        var firstFailedPropstatStatus: Int?
        var acceptedPropstat = false
    }

    private var current: Draft?
    private var currentPropstat: PropstatDraft?
    private var activeProperty: String?
    private var propertyText = ""
    private var parseError: Error?
    private var sawMultistatus = false
    private var elementStack: [String] = []
    private(set) var entries: [WebDAVSourceAdapter.DAVEntry] = []

    func parse(_ data: Data) throws -> [WebDAVSourceAdapter.DAVEntry] {
        current = nil
        currentPropstat = nil
        activeProperty = nil
        propertyText = ""
        parseError = nil
        sawMultistatus = false
        elementStack = []
        entries = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parseError == nil, sawMultistatus, elementStack.isEmpty else {
            throw parseError ?? ResourceSourceError.invalidResponse
        }
        return entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = Self.localName(qName ?? elementName)
        elementStack.append(local)
        guard namespaceURI == Self.davNamespace else {
            // DAV response elements are namespace-sensitive. Provider-specific
            // extension elements are ignored, while lookalike roots/responses fail.
            if local == "multistatus" || local == "response" {
                parseError = ResourceSourceError.invalidResponse
            }
            return
        }
        if local == "multistatus" {
            guard elementStack.count == 1, !sawMultistatus else {
                parseError = ResourceSourceError.invalidResponse
                return
            }
            sawMultistatus = true
            return
        }
        guard sawMultistatus else {
            parseError = ResourceSourceError.invalidResponse
            return
        }
        if local == "response" {
            guard current == nil, currentPropstat == nil else {
                parseError = ResourceSourceError.invalidResponse
                return
            }
            current = Draft()
            return
        }
        guard current != nil else { return }
        if local == "propstat" {
            guard currentPropstat == nil,
                  elementStack.dropLast().last == "response" else {
                parseError = ResourceSourceError.invalidResponse
                return
            }
            currentPropstat = PropstatDraft()
            return
        }
        if local == "resourcetype" {
            if currentPropstat != nil {
                currentPropstat?.properties.sawResourceType = true
            } else {
                current?.properties.sawResourceType = true
            }
            return
        }
        if local == "collection" {
            if currentPropstat != nil {
                currentPropstat?.properties.isCollection = true
            } else {
                current?.properties.isCollection = true
            }
            return
        }
        if Self.propertyNames.contains(local) {
            guard activeProperty == nil else {
                parseError = ResourceSourceError.invalidResponse
                return
            }
            activeProperty = local
            propertyText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeProperty != nil else { return }
        propertyText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = Self.localName(qName ?? elementName)
        defer { _ = elementStack.popLast() }
        if activeProperty == local {
            assign(property: local, text: propertyText)
            activeProperty = nil
            propertyText = ""
        }
        if local == "propstat" {
            finishCurrentPropstat()
            return
        }
        guard local == "response", let current else { return }
        guard currentPropstat == nil else {
            parseError = ResourceSourceError.invalidResponse
            self.current = nil
            self.currentPropstat = nil
            return
        }
        guard let href = current.href, !href.isEmpty else {
            parseError = ResourceSourceError.invalidResponse
            self.current = nil
            return
        }
        let properties = current.properties
        let statusCode = current.responseStatusCode
            ?? (current.acceptedPropstat ? 200 : current.firstFailedPropstatStatus)
        entries.append(
            WebDAVSourceAdapter.DAVEntry(
                href: href,
                name: properties.displayName ?? "",
                isCollection: properties.isCollection,
                byteSize: properties.byteSize,
                modifiedAt: properties.modifiedAt,
                mimeType: properties.mimeType,
                etag: properties.etag,
                serverVersion: properties.serverVersion,
                statusCode: statusCode
            )
        )
        self.current = nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    private func assign(property: String, text: String) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch property {
        case "href":
            guard !value.isEmpty else { return }
            if var response = current {
                response.href = merged(response.href, value)
                current = response
            }
        case "displayname":
            assignProperty(\.displayName, value: value.isEmpty ? nil : value)
        case "getcontentlength":
            assignProperty(\.byteSize, value: Int64(value))
        case "getlastmodified":
            assignProperty(\.modifiedAt, value: Self.parseHTTPDate(value))
        case "getetag":
            assignProperty(\.etag, value: value.isEmpty ? nil : value)
        case "getcontenttype":
            assignProperty(\.mimeType, value: value.isEmpty ? nil : value)
        case "getcontentversion":
            assignProperty(\.serverVersion, value: value.isEmpty ? nil : value)
        case "status":
            guard let statusCode = Self.parseStatusCode(value) else {
                parseError = ResourceSourceError.invalidResponse
                return
            }
            if var propstat = currentPropstat {
                propstat.statusCode = merged(propstat.statusCode, statusCode)
                currentPropstat = propstat
            } else if var response = current {
                response.responseStatusCode = merged(response.responseStatusCode, statusCode)
                current = response
            }
        default: break
        }
    }

    private func assignProperty<Value: Equatable>(
        _ keyPath: WritableKeyPath<PropertyDraft, Value?>,
        value: Value?
    ) {
        guard let value else { return }
        if var propstat = currentPropstat {
            let existing = propstat.properties[keyPath: keyPath]
            propstat.properties[keyPath: keyPath] = merged(existing, value)
            currentPropstat = propstat
        } else if var response = current {
            let existing = response.properties[keyPath: keyPath]
            response.properties[keyPath: keyPath] = merged(existing, value)
            current = response
        }
    }

    private func finishCurrentPropstat() {
        guard let propstat = currentPropstat, var current else {
            parseError = ResourceSourceError.invalidResponse
            currentPropstat = nil
            return
        }
        defer { currentPropstat = nil }

        if let statusCode = propstat.statusCode,
           !(200..<300).contains(statusCode) {
            current.firstFailedPropstatStatus = current.firstFailedPropstatStatus ?? statusCode
            self.current = current
            return
        }

        merge(propstat.properties, into: &current.properties)
        current.acceptedPropstat = true
        self.current = current
    }

    private func merge(_ incoming: PropertyDraft, into target: inout PropertyDraft) {
        target.displayName = merged(target.displayName, incoming.displayName)
        target.byteSize = merged(target.byteSize, incoming.byteSize)
        target.modifiedAt = merged(target.modifiedAt, incoming.modifiedAt)
        target.mimeType = merged(target.mimeType, incoming.mimeType)
        target.etag = merged(target.etag, incoming.etag)
        target.serverVersion = merged(target.serverVersion, incoming.serverVersion)
        if incoming.sawResourceType {
            if target.sawResourceType, target.isCollection != incoming.isCollection {
                parseError = ResourceSourceError.invalidResponse
            } else {
                target.sawResourceType = true
                target.isCollection = incoming.isCollection
            }
        }
    }

    private func merged<Value: Equatable>(_ existing: Value?, _ incoming: Value?) -> Value? {
        guard let existing else { return incoming }
        guard let incoming else { return existing }
        guard existing == incoming else {
            parseError = ResourceSourceError.invalidResponse
            return existing
        }
        return existing
    }

    private static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }

    private static let davNamespace = "DAV:"

    private static func parseStatusCode(_ value: String) -> Int? {
        let fields = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { return nil }
        return Int(fields[1])
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    private static let propertyNames: Set<String> = [
        "href", "displayname", "getcontentlength", "getlastmodified",
        "getetag", "getcontenttype", "getcontentversion", "status"
    ]
}
