import Foundation
import os.lock
import UniformTypeIdentifiers

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
    private var serverAdvertisesRanges = false
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
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    func connect() async throws {
        _ = try await propfind(path: .root, depth: 0)
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        let entries = try await propfind(path: path, depth: 1)
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
        let entries = try await propfind(path: path, depth: 0)
        guard let entry = entries.first(where: { (try? logicalPath(from: $0.href)) == path }) else {
            throw ResourceSourceError.notFound
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
        let httpAdapter = HTTPSourceAdapter(
            source: source,
            descriptors: [descriptor],
            session: session,
            taskDelegate: redirectDelegate,
            timeout: timeout
        )

        let metadata: ResourceMetadata
        do {
            // HEAD/Range probing supplies concrete Accept-Ranges and a second
            // revision source where the DAV property set is incomplete.
            let httpMetadata = try await httpAdapter.fetchMetadata(for: item)
            metadata = merge(dav: davMetadata, http: httpMetadata)
        } catch ResourceSourceError.httpStatus(let code) where code == 405 || code == 501 {
            metadata = davMetadata
        } catch ResourceSourceError.invalidResponse {
            // A malformed optional probe must not discard otherwise valid DAV
            // metadata; it only means Range evidence remains conservative.
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
            taskDelegate: redirectDelegate,
            timeout: timeout
        )
        return try await httpAdapter.readData(for: item, range: range)
    }

    // MARK: - WebDAV request and response mapping

    private func propfind(path: ResourcePath, depth: Int) async throws -> [DAVEntry] {
        guard depth == 0 || depth == 1 else {
            throw ResourceSourceError.invalidReference
        }

        var request = URLRequest(
            url: resourceURL(for: path, isDirectory: true),
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
        do {
            (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        } catch {
            if redirectDelegate.consumeUnsafeRedirect() {
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
        if let ranges = Self.headerValue("Accept-Ranges", in: httpResponse) {
            serverAdvertisesRanges = ranges.caseInsensitiveCompare("bytes") == .orderedSame
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
        let kind: ResourceKind = entry.isCollection
            ? .folder
            : Self.kind(for: entry.name, mimeType: entry.mimeType)
        var capabilities: ResourceCapability = entry.isCollection
            ? [.list]
            : [.read, .download, .directURL]
        if !entry.isCollection && metadata.acceptsRanges {
            capabilities.insert(.rangeRead)
        }
        return ResourceItem(
            sourceID: source.id,
            logicalPath: path,
            name: entry.name,
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
        let acceptsRanges = !isDirectory && serverAdvertisesRanges
        return ResourceMetadata(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            mimeType: mimeType,
            typeIdentifier: isDirectory ? nil : Self.typeIdentifier(name: entry.name, mimeType: mimeType),
            isDirectory: isDirectory,
            acceptsRanges: acceptsRanges,
            revision: ResourceRevision.strongest(
                etag: entry.etag,
                serverVersion: entry.serverVersion,
                modifiedAt: modifiedAt,
                byteSize: byteSize
            )
        )
    }

    private func merge(dav: ResourceMetadata, http: ResourceMetadata) -> ResourceMetadata {
        let byteSize = http.byteSize ?? dav.byteSize
        let modifiedAt = http.modifiedAt ?? dav.modifiedAt
        let mimeType = http.mimeType ?? dav.mimeType
        let typeIdentifier = http.typeIdentifier ?? dav.typeIdentifier
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
            mimeType: mimeType,
            typeIdentifier: typeIdentifier,
            isDirectory: false,
            acceptsRanges: http.acceptsRanges,
            revision: revision
        )
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
/// Redirects can otherwise move a request carrying Basic Authorization to a
/// different host or out of the configured `/dav/` root. The delegate refuses
/// those redirects before URLSession creates the follow-up request.
private final class WebDAVRedirectDelegate: NSObject, URLSessionTaskDelegate, HTTPRedirectFailureReporting, Sendable {
    private let scheme: String
    private let host: String
    private let port: Int
    private let basePathComponents: [String]
    private let authorization: String?
    private let rejection = OSAllocatedUnfairLock(initialState: false)

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
              allows(url),
              let expectedMethod = task.currentRequest?.httpMethod
                ?? task.originalRequest?.httpMethod,
              request.httpMethod?.uppercased() == expectedMethod.uppercased() else {
            rejection.withLock { $0 = true }
            task.cancel()
            completionHandler(nil)
            return
        }

        var safeRequest = request
        if let authorization {
            safeRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        } else {
            safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(safeRequest)
    }

    func consumeUnsafeRedirect() -> Bool {
        rejection.withLock {
            let wasRejected = $0
            $0 = false
            return wasRejected
        }
    }

    private func allows(_ url: URL) -> Bool {
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
}

private final class DAVXMLParser: NSObject, XMLParserDelegate {
    private struct Draft {
        var href: String?
        var displayName: String?
        var byteSize: Int64?
        var modifiedAt: Date?
        var mimeType: String?
        var etag: String?
        var serverVersion: String?
        var isCollection = false
        var statusCode: Int?
    }

    private var current: Draft?
    private var activeProperty: String?
    private var propertyText = ""
    private var parseError: Error?
    private var sawMultistatus = false
    private var elementStack: [String] = []
    private(set) var entries: [WebDAVSourceAdapter.DAVEntry] = []

    func parse(_ data: Data) throws -> [WebDAVSourceAdapter.DAVEntry] {
        current = nil
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
            guard current == nil else {
                parseError = ResourceSourceError.invalidResponse
                return
            }
            current = Draft()
            return
        }
        guard current != nil else { return }
        if local == "collection" {
            current?.isCollection = true
            return
        }
        if Self.propertyNames.contains(local) {
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
        guard local == "response", let current else { return }
        guard let href = current.href, !href.isEmpty else {
            parseError = ResourceSourceError.invalidResponse
            self.current = nil
            return
        }
        entries.append(
            WebDAVSourceAdapter.DAVEntry(
                href: href,
                name: current.displayName ?? "",
                isCollection: current.isCollection,
                byteSize: current.byteSize,
                modifiedAt: current.modifiedAt,
                mimeType: current.mimeType,
                etag: current.etag,
                serverVersion: current.serverVersion,
                statusCode: current.statusCode
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
        case "href": current?.href = value
        case "displayname": current?.displayName = value.isEmpty ? nil : value
        case "getcontentlength": current?.byteSize = Int64(value)
        case "getlastmodified": current?.modifiedAt = Self.parseHTTPDate(value)
        case "getetag": current?.etag = value.isEmpty ? nil : value
        case "getcontenttype": current?.mimeType = value.isEmpty ? nil : value
        case "getcontentversion": current?.serverVersion = value.isEmpty ? nil : value
        case "status": current?.statusCode = Self.parseStatusCode(value)
        default: break
        }
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
