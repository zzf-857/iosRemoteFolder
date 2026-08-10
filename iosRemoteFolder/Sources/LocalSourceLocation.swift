import Foundation

/// 本地来源根目录的可持久化位置值。
///
/// 该值只保存 security-scoped bookmark data，不保存或返回绝对路径。解析只
/// 在 adapter 的短生命周期访问边界内进行；stale bookmark 不会静默使用旧路径。
struct LocalSourceLocation: Hashable, Sendable, Codable {
    enum ResolutionError: Error, Hashable, Sendable {
        case invalidBookmark
        case staleBookmark
    }

    private let bookmarkData: Data

    /// 从 Files/目录选择器返回的目录 URL 创建位置 bookmark。
    /// iOS 通过选择器 URL 自带的隐式 security scope 恢复授权；`.withSecurityScope`
    /// 是 macOS 专用选项，不能用于 iOS 17 target。
    init(directoryURL: URL) throws {
        let url = directoryURL.standardizedFileURL
        guard url.isFileURL else {
            throw ResourceSourceError.invalidReference
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw ResourceSourceError.permissionDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ResourceSourceError.notFound
        }
        guard isDirectory.boolValue else {
            throw ResourceSourceError.invalidReference
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ResourceSourceError.permissionDenied
        }

        do {
            self.bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw ResourceSourceError.mapping(error)
        }
    }

    /// 从持久化数据恢复位置。实际解析在 `withResolvedURL` 中进行，以便每次
    /// 访问都重新确认 stale 状态，不会回退到构造时缓存的绝对路径。
    init(bookmarkData: Data) throws {
        guard !bookmarkData.isEmpty else {
            throw ResourceSourceError.invalidReference
        }
        self.bookmarkData = bookmarkData
    }

    private enum CodingKeys: String, CodingKey {
        case bookmarkData
    }

    /// 解码时保留损坏的 bookmark，以便来源仍能显示为可行动的失效状态。
    /// 只有真正访问位置时才解析并映射为 `invalidReference`，不会丢弃来源配置。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bookmarkData, forKey: .bookmarkData)
    }

    /// 在解析后的短暂 URL 闭包内执行操作；不向调用方返回 bookmark 或路径。
    func withResolvedURL<T>(_ body: (URL) throws -> T) throws -> T {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutImplicitStartAccessing,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw ResolutionError.invalidBookmark
        }

        guard !isStale else {
            throw ResolutionError.staleBookmark
        }
        guard resolvedURL.isFileURL else {
            throw ResolutionError.invalidBookmark
        }
        return try body(resolvedURL.standardizedFileURL)
    }

    /// 判断两个位置是否指向同一个目录，但不向调用方暴露解析后的 URL。
    ///
    /// Bookmark bytes 不是稳定的目录身份：同一目录在不同选择或系统版本下
    /// 可能生成不同数据。解析成功时使用规范化、解析符号链接后的 URL；任何
    /// 一方无法解析时保守回退到原始 bytes equality，避免把两个未知位置误合并。
    func isSameResolvedLocation(as other: LocalSourceLocation) -> Bool {
        guard let lhs = comparisonURL, let rhs = other.comparisonURL else {
            return self == other
        }
        return lhs == rhs
    }

    private var comparisonURL: URL? {
        do {
            return try withResolvedURL { url in
                guard url.startAccessingSecurityScopedResource() else {
                    return nil
                }
                defer { url.stopAccessingSecurityScopedResource() }
                return url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            }
        } catch {
            return nil
        }
    }
}
