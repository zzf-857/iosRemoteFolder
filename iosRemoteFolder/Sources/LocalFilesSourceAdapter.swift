import Foundation
import UniformTypeIdentifiers

/// 本地文件来源 adapter：把设备上一个可访问的目录映射为资源来源。
///
/// 该 adapter 只负责文件系统能力，不触碰网络。它会把 `ResourceItem.path`
/// 安全地解析为磁盘上的真实 URL，并拒绝任何路径穿越。引用、元数据与读取
/// 共用同一磁盘事实校验，只接受真实存在、可读的普通文件。所有底层文件错误
/// 都映射为 `ResourceSourceError`。
struct LocalFilesSourceAdapter: ResourceSourceAdapter {
    let source: ResourceSource
    /// 来源根目录；所有列举与读取都被约束在这个目录内。
    let rootURL: URL
    /// 符号链接解析后的真实根路径，作为读取边界校验的事实基准。
    private let resolvedRootURL: URL

    init(source: ResourceSource, rootURL: URL) {
        self.source = source
        let standardized = rootURL.standardizedFileURL
        self.rootURL = standardized
        self.resolvedRootURL = standardized.resolvingSymlinksInPath()
    }

    func connect() async throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
        guard exists else {
            throw ResourceSourceError.notFound
        }
        guard isDirectory.boolValue else {
            throw ResourceSourceError.invalidReference
        }
        guard FileManager.default.isReadableFile(atPath: rootURL.path) else {
            throw ResourceSourceError.permissionDenied
        }
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        let baseURL = try resolvedURL(forPath: path, isDirectory: true)
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            throw ResourceSourceError.permissionDenied
        } catch {
            throw ResourceSourceError.mapping(error)
        }

        return urls
            .map { makeItem(from: $0, parentPath: path) }
            .sorted { lhs, rhs in
                if lhs.kind == .folder && rhs.kind != .folder { return true }
                if lhs.kind != .folder && rhs.kind == .folder { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        let file = try validatedFile(for: item)
        return .localFile(.init(fileURL: file.url, supportsRandomAccess: true))
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        let file = try validatedFile(for: item)
        let type = typeInfo(for: file.url)
        let byteSize = file.values.fileSize.map { Int64($0) }
        let modifiedAt = file.values.contentModificationDate
        return ResourceMetadata(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            mimeType: type.mimeType,
            typeIdentifier: type.identifier,
            isDirectory: false,
            acceptsRanges: true,
            revision: ResourceRevision.strongest(
                etag: nil,
                serverVersion: nil,
                modifiedAt: modifiedAt,
                byteSize: byteSize
            )
        )
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        let file = try validatedFile(for: item)
        guard let range else {
            // 完整读取保持既有行为与错误映射。
            do {
                return try Data(contentsOf: file.url)
            } catch {
                throw ResourceSourceError.mapping(error)
            }
        }
        return try readRange(range, of: file.url)
    }

    /// 区间读取：只 seek/read 请求的字节窗口，不把整个文件载入内存。
    private func readRange(_ range: ResourceByteRange, of url: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ResourceSourceError.mapping(error)
        }
        defer { try? handle.close() }
        do {
            let fileSize = Int64(try handle.seekToEnd())
            // 空文件或区间完全越界：明确返回空数据，而不是报错。
            guard let clamped = range.clamped(toTotalLength: fileSize) else {
                return Data()
            }
            try handle.seek(toOffset: UInt64(clamped.lowerBound))
            var remaining = clamped.length
            var data = Data()
            while remaining > 0 {
                let chunkSize = Int(min(remaining, 65_536))
                // read(upToCount:) 返回 nil 表示已到达 EOF。
                guard let chunk = try handle.read(upToCount: chunkSize) else { break }
                if chunk.isEmpty { break }
                data.append(chunk)
                remaining -= Int64(chunk.count)
            }
            return data
        } catch {
            throw ResourceSourceError.mapping(error)
        }
    }

    // MARK: - Private

    /// 把资源路径安全解析为磁盘 URL；任何穿越根目录的路径都会被拒绝。
    ///
    /// 双重边界校验：先用规范化路径拦截 `..` 穿越，再解析符号链接，
    /// 用真实路径对照解析后的根目录，拦截指向 root 外部的符号链接。
    private func resolvedURL(forPath path: ResourcePath, isDirectory: Bool) throws -> URL {
        let relative = path.relativeString
        let candidate: URL
        if relative.isEmpty {
            candidate = rootURL
        } else {
            // 用 fileURLWithPath 解析嵌套相对段；appendingPathComponent 会把含
            // 斜杠的相对串当作单个组件名，故此处直接拼接为完整路径字符串。
            candidate = URL(fileURLWithPath: rootURL.path + "/" + relative, isDirectory: isDirectory)
        }
        let standardized = candidate.standardizedFileURL
        guard standardized.path == rootURL.path || standardized.path.hasPrefix(rootURL.path + "/") else {
            throw ResourceSourceError.invalidReference
        }
        let resolvedCandidate = standardized.resolvingSymlinksInPath()
        let resolvedRoot = resolvedRootURL
        guard resolvedCandidate.path == resolvedRoot.path
            || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw ResourceSourceError.invalidReference
        }
        return resolvedCandidate
    }

    /// 三个文件入口共用的验证结果；属性来自 symlink/root 边界解析后的真实 URL。
    private struct ValidatedFile {
        let url: URL
        let values: URLResourceValues
    }

    /// 校验来源/身份/逻辑路径与 root/symlink 边界，再以磁盘事实确认候选存在、
    /// 非目录、是普通文件且可读。缺失、无权限等底层错误保持统一映射。
    private func validatedFile(for item: ResourceItem) throws -> ValidatedFile {
        let path = try validatedResourcePath(for: item)
        let url = try resolvedURL(forPath: path, isDirectory: false)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isReadableKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        } catch {
            throw ResourceSourceError.mapping(error)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ResourceSourceError.notFound
        }
        guard !isDirectory.boolValue, values.isDirectory != true else {
            throw ResourceSourceError.invalidReference
        }
        guard values.isRegularFile == true else {
            throw ResourceSourceError.invalidReference
        }
        guard values.isReadable == true else {
            throw ResourceSourceError.permissionDenied
        }
        return ValidatedFile(url: url, values: values)
    }

    /// 校验 item 属于本来源、身份与规范化路径一致且声明为文件。
    /// 磁盘文件类型与可读性由 `validatedFile(for:)` 独立确认，不能信任展示 kind。
    private func validatedResourcePath(for item: ResourceItem) throws -> ResourcePath {
        guard item.sourceID == source.id else { throw ResourceSourceError.invalidReference }
        guard item.id.sourceID == source.id, item.id.logicalPath == item.path else {
            throw ResourceSourceError.invalidReference
        }
        // A folder item cannot enter a file operation, but this declaration is
        // only an early semantic guard; the resolved disk facts below still
        // independently prove that every candidate is a regular readable file.
        guard item.kind != .folder, !item.metadata.isDirectory else {
            throw ResourceSourceError.invalidReference
        }
        guard let path = ResourcePath(rawValue: item.path), !path.isRoot else {
            throw ResourceSourceError.invalidReference
        }
        return path
    }

    private func makeItem(from url: URL, parentPath: ResourcePath) -> ResourceItem {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isReadableKey,
            .contentModificationDateKey,
            .fileSizeKey
        ])
        let isDirectory = values?.isDirectory ?? false
        let isRegularFile = values?.isRegularFile == true
        let kind = isDirectory ? .folder : isRegularFile ? kind(for: url) : .unknown
        let name = url.lastPathComponent
        let childPath = parentPath.child(name) ?? parentPath
        let metadata = makeMetadata(from: url, values: values, isDirectory: isDirectory)
        var capabilities: ResourceCapability = metadata.isDirectory
            ? [.list]
            : [.read, .download]
        if metadata.acceptsRanges {
            capabilities.insert(.rangeRead)
        }
        return ResourceItem(
            sourceID: source.id,
            logicalPath: childPath,
            name: name,
            kind: kind,
            metadata: metadata,
            capabilities: capabilities,
            accent: .recommended(for: kind)
        )
    }

    private func kind(for url: URL) -> ResourceKind {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        case "txt", "text": return .text
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp": return .image
        case "mp4", "mov", "m4v", "mkv": return .video
        case "mp3", "m4a", "aac", "flac", "wav": return .audio
        default: return .unknown
        }
    }

    private func makeMetadata(
        from url: URL,
        values: URLResourceValues?,
        isDirectory: Bool
    ) -> ResourceMetadata {
        guard !isDirectory else {
            return ResourceMetadata(
                modifiedAt: values?.contentModificationDate,
                isDirectory: true,
                acceptsRanges: false,
                revision: .unknown
            )
        }

        guard values?.isRegularFile == true else {
            return ResourceMetadata(
                modifiedAt: values?.contentModificationDate,
                isDirectory: false,
                acceptsRanges: false,
                revision: .unknown
            )
        }

        let byteSize = values?.fileSize.map { Int64($0) }
        let modifiedAt = values?.contentModificationDate
        let type = typeInfo(for: url)
        let isReadable = values?.isReadable == true
        let isRegularFile = values?.isRegularFile == true
        return ResourceMetadata(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            mimeType: type.mimeType,
            typeIdentifier: type.identifier,
            isDirectory: false,
            acceptsRanges: isRegularFile && isReadable,
            revision: ResourceRevision.strongest(
                etag: nil,
                serverVersion: nil,
                modifiedAt: modifiedAt,
                byteSize: byteSize
            )
        )
    }

    private func typeInfo(for url: URL) -> (mimeType: String?, identifier: String?) {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else {
            return (nil, nil)
        }
        return (type.preferredMIMEType, type.identifier)
    }
}
