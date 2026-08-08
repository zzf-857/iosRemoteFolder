import Foundation

/// 规范化的来源内逻辑目录路径；所有列举、引用与稳定身份都只使用逻辑路径，
/// 不携带文件系统绝对 URL 或请求 URL。
///
/// 规范化规则（确定性、可复现）：
/// - 逻辑根统一为 `/`；空路径或只有分隔符的路径规范化为 `/`。
/// - 以 `/` 分隔的段逐一处理：`""`（重复斜杠/首尾斜杠）忽略，`"."` 忽略，
///   `".."` 一律拒绝（返回 nil），不能直接或经字符串拼接绕过本地 root 边界。
/// - Unicode 文件名原样保留，大小写保留；不做 URL 百分号编码。
struct ResourcePath: Hashable, Sendable {
    /// 规范化后的逻辑路径，始终以 `/` 开头；根目录为 `/`，子目录/文件形如 `/a/b`。
    let normalized: String

    static let root = ResourcePath(normalized: "/")

    private init(normalized: String) {
        self.normalized = normalized
    }

    /// 解析并规范化任意原始路径字符串。
    /// - 返回 nil：路径包含 `..` 段或无法归一化为合法逻辑路径（视为越界，
    ///   映射为 `ResourceSourceError.invalidReference`）。
    init?(rawValue: String) {
        var components: [String] = []
        for segment in rawValue.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(segment)
            if part == "." { continue }
            if part == ".." { return nil }
            components.append(part)
        }
        if components.isEmpty {
            self.normalized = "/"
        } else {
            self.normalized = "/" + components.joined(separator: "/")
        }
    }

    /// 是否为逻辑根目录。
    var isRoot: Bool { normalized == "/" }

    /// 去掉前导 `/` 的相对路径字符串，用于拼接磁盘 URL 或请求路径。
    var relativeString: String {
        guard normalized != "/" else { return "" }
        return String(normalized.dropFirst())
    }

    /// 路径的各段（不含根的前导空段）。
    var components: [String] {
        guard normalized != "/" else { return [] }
        return normalized.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// 父目录；根目录没有父目录，返回 nil。
    var parent: ResourcePath? {
        guard !isRoot else { return nil }
        let parts = components
        let truncated = parts.dropLast()
        if truncated.isEmpty { return .root }
        return ResourcePath(normalized: "/" + truncated.joined(separator: "/"))
    }

    /// 在当前路径下追加一个子段；子段包含 `/` 会按规范化处理，
    /// 包含 `..` 或为空则拒绝（返回 nil）。
    func child(_ name: String) -> ResourcePath? {
        ResourcePath(rawValue: normalized + "/" + name)
    }

    /// 判断当前路径是否为 `ancestor` 的严格子路径（包含且更深）。
    func isUnder(_ ancestor: ResourcePath) -> Bool {
        let a = ancestor.components
        let b = components
        guard b.count > a.count else { return false }
        return b.prefix(a.count).elementsEqual(a)
    }
}
