import Foundation

/// 统一来源适配器协议。
///
/// 查看器、缓存与 UI 只消费 `ResourceItem`、`ResourceReference` 和
/// `ResourceSourceState`，不感知具体协议；每个来源实现一个 adapter。
/// 连接状态由 `SourcesStore` 根据下列异步方法的结果汇总，adapter 自身
/// 不持有 UI 状态。UI 禁止直接调用 URLSession 或 FileManager。
protocol ResourceSourceAdapter: Sendable {
    /// 来源的静态描述；实时连接状态通过 `SourcesStore` 报告。
    var source: ResourceSource { get }

    /// 探测并建立连接。失败时抛出可行动的 `ResourceSourceError`。
    func connect() async throws

    /// 列举指定逻辑目录下的直接子项（文件夹与文件），这是唯一必需的列举语义。
    /// 本地来源解析真实子目录，HTTP 来源在已配置直链上构建虚拟目录树；
    /// 规范化后的逻辑路径必须唯一，重复路径须明确报 `invalidReference`，
    /// 不能由 `first(where:)` 静默选择。
    func listResources(at path: ResourcePath) async throws -> [ResourceItem]

    /// 为资源生成统一引用；未知资源抛出 `ResourceSourceError.invalidReference`。
    func reference(for item: ResourceItem) async throws -> ResourceReference

    /// 探测资源元数据（本地文件属性或 HTTP HEAD）。
    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata

    /// 读取资源数据；`range` 为 nil 表示完整读取。
    /// 不支持区间读取的来源必须显式降级或抛出 `capabilityUnavailable`。
    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data
}

extension ResourceSourceAdapter {
    /// 根目录兼容入口；严格且只向唯一必需的带路径入口转发。
    func listResources() async throws -> [ResourceItem] {
        try await listResources(at: .root)
    }
}

/// 统一的来源错误。所有 adapter 抛出的底层错误都必须映射到这里，
/// 保证 UI、测试和日志看到的是同一套可解释、可行动的错误语义。
enum ResourceSourceError: LocalizedError, Hashable, Sendable {
    /// 认证失效或需要重新认证（HTTP 401、URLSession 认证质询）。
    case authenticationRequired
    /// 本地 security-scoped bookmark 已失效或需要用户重新选择目录。
    case authorizationRequired
    /// 无权限访问（本地文件权限、HTTP 403）。
    case permissionDenied
    /// 资源或来源不存在（本地 ENOENT、HTTP 404）。
    case notFound
    /// 连接或读取超时。
    case timedOut
    /// 用户或系统取消了操作。
    case cancelled
    /// 其余非 2xx 的 HTTP 状态码。
    case httpStatus(Int)
    /// 网络不可达：断网、DNS 失败、拒绝连接等。
    case networkUnavailable
    /// 引用无效：URL 编码错误、路径穿越、缺少必要参数。
    case invalidReference
    /// 来源不支持请求的能力。
    case capabilityUnavailable
    /// 服务器未支持区间读取，且全量响应超出安全预算；为避免整文件进内存而中止读取。
    case responseTooLarge
    /// 服务器响应违反约定（Content-Range 非法、响应体长度不符、区间请求收到异常 2xx），无法保证数据完整。
    case invalidResponse
    /// 来源失效或其他暂时无法归类的失败。
    case unavailable

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "来源需要重新认证"
        case .authorizationRequired: "本地来源需要重新授权，请重新选择文件夹"
        case .permissionDenied: "没有权限访问该资源"
        case .notFound: "资源不存在或已被删除"
        case .timedOut: "连接超时，请检查网络后重试"
        case .cancelled: "操作已取消"
        case .httpStatus(let code): "服务器返回异常状态码 \(code)"
        case .networkUnavailable: "无法连接到来源，请检查网络或地址"
        case .invalidReference: "资源引用无效"
        case .capabilityUnavailable: "此来源不支持当前操作"
        case .responseTooLarge: "服务器未支持分段读取，响应内容超出安全上限。请改用完整下载，或联系服务端开启 Range 支持"
        case .invalidResponse: "远端响应无效或不完整，无法确认数据完整。请重试，或检查服务端配置"
        case .unavailable: "来源暂时不可用"
        }
    }

    /// 值得让用户立即重试的错误。
    var isRetryable: Bool {
        switch self {
        case .timedOut, .networkUnavailable, .unavailable, .invalidResponse:
            return true
        case .httpStatus(let code):
            return code >= 500
        default:
            return false
        }
    }

    /// 将底层系统错误映射为统一的来源错误。
    static func mapping(_ error: any Error) -> ResourceSourceError {
        if let sourceError = error as? ResourceSourceError {
            return sourceError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            case .userAuthenticationRequired:
                return .authenticationRequired
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive:
                return .networkUnavailable
            case .badURL, .unsupportedURL:
                return .invalidReference
            default:
                return .unavailable
            }
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            switch cocoa.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .notFound
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied
            default:
                break
            }
        }
        return .unavailable
    }

    /// HTTP 状态码到来源错误的映射；可行动语义单独成类，其余保留状态码。
    static func http(statusCode: Int) -> ResourceSourceError {
        switch statusCode {
        case 401: .authenticationRequired
        case 403: .permissionDenied
        case 404: .notFound
        default: .httpStatus(statusCode)
        }
    }
}

/// 假数据占位 adapter：在真实 Alist / WebDAV adapter 接入前维持骨架行为，
/// 引用、元数据和读取能力明确声明为不可用。
struct SampleSourceAdapter: ResourceSourceAdapter {
    let source: ResourceSource

    func connect() async throws {
        try await Task.sleep(for: .milliseconds(120))
        guard source.status != .needsAttention else {
            throw ResourceSourceError.authenticationRequired
        }
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        try await connect()
        let all = SampleData.resources.filter { $0.sourceID == source.id }
        guard !path.isRoot else { return all }
        // 按规范化路径过滤：直接子文件保留，深层资源合成必要的虚拟文件夹。
        var folderNames: [String: String] = [:]
        var fileItems: [String: ResourceItem] = [:]
        for item in all {
            guard let itemPath = ResourcePath(rawValue: item.path), itemPath.isUnder(path) else { continue }
            let remaining = itemPath.components.dropFirst(path.components.count)
            if remaining.count == 1 {
                fileItems[item.path] = item
            } else if remaining.count > 1,
                      let folderName = remaining.first,
                      let folderPath = path.child(folderName) {
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
        let sortedFolders = folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let sortedFiles = fileItems.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return sortedFolders + sortedFiles
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        throw ResourceSourceError.capabilityUnavailable
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        throw ResourceSourceError.capabilityUnavailable
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        throw ResourceSourceError.capabilityUnavailable
    }
}
