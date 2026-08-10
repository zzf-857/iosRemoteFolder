import Foundation

/// 统一的资源引用。
///
/// 查看器和缓存层消费 `ResourceReference`，而不是直接感知协议。它可以表达
/// 本地文件、远端直链，以及带鉴权请求头的 HTTP/HTTPS 请求描述。
///
/// 安全边界：凭证（密码、Token、Cookie、私钥）绝不能写入 `ResourceItem`、
/// 日志或测试 fixture。对 HTTP 引用，凭证只出现在 `headers` 里，并且在任何
/// 诊断输出中都必须脱敏。
enum ResourceReference: Hashable, Sendable {
    /// 本地文件引用，指向沙盒、应用容器或安全作用域内的文件。
    case localFile(LocalFile)

    /// 远端 HTTP/HTTPS 引用，包含请求方法、鉴权请求头和随机读取能力。
    case remoteHTTP(RemoteHTTP)

    /// 本地文件引用描述。
    struct LocalFile: Hashable, Sendable {
        /// 已解析、已通过安全校验的文件 URL。
        var fileURL: URL
        /// 该文件是否支持字节区间读取。本地文件通常支持。
        var supportsRandomAccess: Bool

        init(fileURL: URL, supportsRandomAccess: Bool = true) {
            self.fileURL = fileURL
            self.supportsRandomAccess = supportsRandomAccess
        }
    }

    /// 远端 HTTP/HTTPS 引用描述。
    ///
    /// Scheme 契约：只允许 `http` 与 `https`。`file`、`data` 等其他 scheme
    /// 必须在 adapter 边界拒绝，并映射为 `ResourceSourceError.invalidReference`；
    /// 引用本身不承载非法 scheme 的合法性。
    struct RemoteHTTP: Hashable, Sendable {
        /// 资源的最终直链 URL。
        var url: URL
        /// 请求方法，默认 GET。
        var method: String
        /// 鉴权或追踪所需的请求头。值属于敏感信息，禁止进入日志。
        var headers: [String: String]
        /// 服务端是否确认支持字节区间读取。
        var supportsRange: Bool

        init(
            url: URL,
            method: String = "GET",
            headers: [String: String] = [:],
            supportsRange: Bool = false
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.supportsRange = supportsRange
        }
    }

    /// 该引用声明支持的读取能力。
    var capabilities: ResourceCapability {
        switch self {
        case .localFile(let value):
            var caps: ResourceCapability = [.read]
            if value.supportsRandomAccess {
                caps.insert(.rangeRead)
            }
            return caps
        case .remoteHTTP(let value):
            var caps: ResourceCapability = [.read, .directURL]
            if value.supportsRange {
                caps.insert(.rangeRead)
            }
            return caps
        }
    }
}

/// 资源读取的一段字节区间（含端点），用于随机读取与缓存分片。
struct ResourceByteRange: Hashable, Sendable {
    var lowerBound: Int64
    var upperBound: Int64

    init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// 只有有限、非空且不反向的区间才有有效长度。
    ///
    /// 构造器保留值类型调用兼容性，不再用 `precondition` 让外部输入直接
    /// 终止进程；所有读取/缓存边界必须先消费这个可失败结果。
    var validatedLength: Int64? {
        guard lowerBound >= 0, upperBound >= lowerBound else { return nil }
        let (difference, differenceOverflow) = upperBound.subtractingReportingOverflow(lowerBound)
        let (length, lengthOverflow) = difference.addingReportingOverflow(1)
        guard !differenceOverflow, !lengthOverflow, length > 0 else { return nil }
        return length
    }

    /// 区间是否可用于读取或持久化寻址。
    var isValid: Bool { validatedLength != nil }

    /// 期望读取的字节数；非法区间返回 0，调用方必须先检查 `validatedLength`。
    var length: Int64 { validatedLength ?? 0 }

    /// 转换为 HTTP `Range` 请求头的值。
    var httpHeaderValue: String {
        "bytes=\(lowerBound)-\(upperBound)"
    }

    /// 将区间收敛到给定总长度内，返回实际可用的区间。
    /// 若区间完全越界，返回 nil。
    func clamped(toTotalLength total: Int64) -> ResourceByteRange? {
        guard validatedLength != nil, total > 0, lowerBound < total else { return nil }
        let upper = min(upperBound, total - 1)
        return ResourceByteRange(lowerBound: lowerBound, upperBound: upper)
    }
}
