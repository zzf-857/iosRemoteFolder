import Foundation
import UniformTypeIdentifiers

/// 本地文件来源 adapter：把设备上一个可访问的目录映射为资源来源。
///
/// adapter 内部区分沙盒 demo 根和 security-scoped bookmark 根。每次操作都在
/// 同一 root lease 内解析路径、协调文件访问并完成磁盘事实校验；bookmark、
/// lease 和绝对 URL 不会越过 Sources 边界。引用、元数据与读取共用同一验证入口。
struct LocalFilesSourceAdapter: ResourceSourceAdapter {
    let source: ResourceSource

    private enum RootLocation: Sendable {
        case sandbox(URL)
        case bookmark(LocalSourceLocation)
    }

    private struct RootContext: Sendable {
        let rootURL: URL
        let resolvedRootURL: URL
    }

    private let rootLocation: RootLocation

    /// 保留沙盒 demo/test 入口；该根目录不需要 security-scoped lease。
    init(source: ResourceSource, rootURL: URL) {
        self.source = source
        self.rootLocation = .sandbox(rootURL.standardizedFileURL)
    }

    /// 由后续 Files picker/来源配置传入 bookmark 位置。初始化时会解析一次，
    /// 因而 stale/失效 bookmark 会显式失败，不会回退到旧的绝对路径。
    init(source: ResourceSource, location: LocalSourceLocation) throws {
        try Self.validate(location: location)
        self.source = source
        self.rootLocation = .bookmark(location)
    }

    func connect() async throws {
        try Task.checkCancellation()
        try withRootAccess { context in
            try coordinatedRead(at: context.rootURL) { url in
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
                try Task.checkCancellation()
            }
        }
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        try Task.checkCancellation()
        return try withRootAccess { context in
            let baseURL = try resolvedURL(forPath: path, isDirectory: true, in: context)
            return try coordinatedRead(at: baseURL) { coordinatedURL in
                try Task.checkCancellation()
                let urls: [URL]
                do {
                    urls = try FileManager.default.contentsOfDirectory(
                        at: coordinatedURL,
                        includingPropertiesForKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey,
                            .isReadableKey,
                            .contentModificationDateKey,
                            .fileSizeKey,
                        ],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    throw ResourceSourceError.mapping(error)
                }

                let items = urls
                    .map { makeItem(from: $0, parentPath: path) }
                    .sorted { lhs, rhs in
                        if lhs.kind == .folder && rhs.kind != .folder { return true }
                        if lhs.kind != .folder && rhs.kind == .folder { return false }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                try Task.checkCancellation()
                return items
            }
        }
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        try Task.checkCancellation()
        return try withRootAccess { context in
            try withValidatedFile(for: item, in: context) { file in
                try Task.checkCancellation()
                return .localFile(.init(fileURL: file.url, supportsRandomAccess: true))
            }
        }
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        try Task.checkCancellation()
        return try withRootAccess { context in
            try withValidatedFile(for: item, in: context) { file in
                let type = typeInfo(for: file.url)
                let byteSize = file.values.fileSize.map { Int64($0) }
                let modifiedAt = file.values.contentModificationDate
                try Task.checkCancellation()
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
        }
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        try Task.checkCancellation()
        return try withRootAccess { context in
            try withValidatedFile(for: item, in: context) { file in
                try Task.checkCancellation()
                guard let range else {
                    do {
                        let data = try Data(contentsOf: file.url)
                        try Task.checkCancellation()
                        return data
                    } catch is CancellationError {
                        throw ResourceSourceError.cancelled
                    } catch {
                        throw ResourceSourceError.mapping(error)
                    }
                }
                return try readRange(range, of: file.url)
            }
        }
    }

    // MARK: - Security-scoped and coordinated access

    /// Bookmark URL 的解析、授权租约和 root/symlink 边界在同一 closure 内完成。
    /// `defer` 保证成功、错误、取消和早退路径都恰好平衡 stop 调用。
    private func withRootAccess<T>(_ operation: (RootContext) throws -> T) throws -> T {
        switch rootLocation {
        case .sandbox(let rootURL):
            let standardized = rootURL.standardizedFileURL
            return try operation(
                RootContext(
                    rootURL: standardized,
                    resolvedRootURL: standardized.resolvingSymlinksInPath()
                )
            )

        case .bookmark(let location):
            do {
                return try location.withResolvedURL { url in
                    guard url.startAccessingSecurityScopedResource() else {
                        throw ResourceSourceError.permissionDenied
                    }
                    defer { url.stopAccessingSecurityScopedResource() }

                    let standardized = url.standardizedFileURL
                    return try operation(
                        RootContext(
                            rootURL: standardized,
                            resolvedRootURL: standardized.resolvingSymlinksInPath()
                        )
                    )
                }
            } catch let error as LocalSourceLocation.ResolutionError {
                switch error {
                case .staleBookmark:
                    throw ResourceSourceError.authorizationRequired
                case .invalidBookmark:
                    throw ResourceSourceError.invalidReference
                }
            }
        }
    }

    /// 所有本地读取都经由 NSFileCoordinator 的同步回调完成，避免在协调边界
    /// 外使用可能被替换的 URL。操作错误优先于协调器的 NSError。
    private func coordinatedRead<T>(
        at url: URL,
        operation: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var outcome: Result<T, any Error>?
        var coordinationError: NSError?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                outcome = .success(try operation(coordinatedURL))
            } catch {
                outcome = .failure(error)
            }
        }

        if let outcome {
            return try outcome.get()
        }
        if let coordinationError {
            throw ResourceSourceError.mapping(coordinationError)
        }
        throw ResourceSourceError.unavailable
    }

    // MARK: - Path and file facts

    private struct ValidatedFile {
        let url: URL
        let values: URLResourceValues
    }

    /// 三个文件入口共用校验、协调和操作 closure；操作不会使用协调回调外的 URL。
    private func withValidatedFile<T>(
        for item: ResourceItem,
        in context: RootContext,
        operation: (ValidatedFile) throws -> T
    ) throws -> T {
        let path = try validatedResourcePath(for: item)
        let candidate = try resolvedURL(forPath: path, isDirectory: false, in: context)
        return try coordinatedRead(at: candidate) { coordinatedURL in
            let file = try validatedFile(at: coordinatedURL)
            return try operation(file)
        }
    }

    /// 把资源路径安全解析为磁盘 URL；先拦截逻辑路径穿越，再拒绝符号链接
    /// 指向 root 外部的候选路径。
    private func resolvedURL(
        forPath path: ResourcePath,
        isDirectory: Bool,
        in context: RootContext
    ) throws -> URL {
        let relative = path.relativeString
        let candidate: URL
        if relative.isEmpty {
            candidate = context.rootURL
        } else {
            candidate = URL(
                fileURLWithPath: context.rootURL.path + "/" + relative,
                isDirectory: isDirectory
            )
        }

        let standardized = candidate.standardizedFileURL
        guard standardized.path == context.rootURL.path
            || standardized.path.hasPrefix(context.rootURL.path + "/") else {
            throw ResourceSourceError.invalidReference
        }

        let resolvedCandidate = standardized.resolvingSymlinksInPath()
        guard resolvedCandidate.path == context.resolvedRootURL.path
            || resolvedCandidate.path.hasPrefix(context.resolvedRootURL.path + "/") else {
            throw ResourceSourceError.invalidReference
        }
        return resolvedCandidate
    }

    /// 校验来源/身份/逻辑路径与 root 边界，再以协调回调中的磁盘事实确认候选
    /// 存在、非目录、普通文件且可读。缺失、目录/非普通文件和不可读保持既有映射。
    private func validatedFile(at url: URL) throws -> ValidatedFile {
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

    /// 校验 item 属于本来源、身份与规范化路径一致且声明为文件；磁盘事实由
    /// `validatedFile(at:)` 独立确认，不能信任展示 kind 或 metadata。
    private func validatedResourcePath(for item: ResourceItem) throws -> ResourcePath {
        guard item.sourceID == source.id else { throw ResourceSourceError.invalidReference }
        guard item.id.sourceID == source.id, item.id.logicalPath == item.path else {
            throw ResourceSourceError.invalidReference
        }
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
            .fileSizeKey,
        ])
        let isDirectory = values?.isDirectory ?? false
        let isRegularFile = values?.isRegularFile == true
        let isReadable = values?.isReadable == true
        let isReadableRegularFile = isRegularFile && isReadable
        let kind = isDirectory ? .folder : isReadableRegularFile ? kind(for: url) : .unknown
        let name = url.lastPathComponent
        let childPath = parentPath.child(name) ?? parentPath
        let metadata = makeMetadata(
            from: url,
            values: values,
            isDirectory: isDirectory,
            isRegularFile: isRegularFile,
            isReadable: isReadable
        )
        var capabilities: ResourceCapability = []
        if isDirectory {
            capabilities = [.list]
        } else if isReadableRegularFile {
            capabilities = [.read, .download]
            if metadata.acceptsRanges {
                capabilities.insert(.rangeRead)
            }
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
        isDirectory: Bool,
        isRegularFile: Bool,
        isReadable: Bool
    ) -> ResourceMetadata {
        guard !isDirectory else {
            return ResourceMetadata(
                modifiedAt: values?.contentModificationDate,
                isDirectory: true,
                acceptsRanges: false,
                revision: .unknown
            )
        }

        guard isRegularFile else {
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

    private static func validate(location: LocalSourceLocation) throws {
        do {
            try location.withResolvedURL { _ in () }
        } catch let error as LocalSourceLocation.ResolutionError {
            switch error {
            case .staleBookmark:
                throw ResourceSourceError.authorizationRequired
            case .invalidBookmark:
                throw ResourceSourceError.invalidReference
            }
        }
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
            try Task.checkCancellation()
            let fileSize = Int64(try handle.seekToEnd())
            guard let clamped = range.clamped(toTotalLength: fileSize) else {
                return Data()
            }
            try handle.seek(toOffset: UInt64(clamped.lowerBound))
            var remaining = clamped.length
            var data = Data()
            while remaining > 0 {
                try Task.checkCancellation()
                let chunkSize = Int(min(remaining, 65_536))
                guard let chunk = try handle.read(upToCount: chunkSize) else { break }
                if chunk.isEmpty { break }
                data.append(chunk)
                remaining -= Int64(chunk.count)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError {
            throw ResourceSourceError.cancelled
        } catch {
            throw ResourceSourceError.mapping(error)
        }
    }
}
