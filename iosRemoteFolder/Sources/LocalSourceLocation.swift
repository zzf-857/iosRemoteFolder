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
                options: [],
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

    /// 在解析后的短暂 URL 闭包内执行操作；不向调用方返回 bookmark 或路径。
    func withResolvedURL<T>(_ body: (URL) throws -> T) throws -> T {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
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
}
