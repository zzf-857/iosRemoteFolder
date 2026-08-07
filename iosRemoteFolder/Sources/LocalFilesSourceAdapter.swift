import Foundation

/// 本地文件来源 adapter：把设备上一个可访问的目录映射为资源来源。
///
/// 该 adapter 只负责文件系统能力，不触碰网络。它会把 `ResourceItem.path`
/// 安全地解析为磁盘上的真实 URL，并拒绝任何路径穿越。所有底层文件错误
/// 都映射为 `ResourceSourceError`。
struct LocalFilesSourceAdapter: ResourceSourceAdapter {
    let source: ResourceSource
    /// 来源根目录；所有列举与读取都被约束在这个目录内。
    let rootURL: URL

    init(source: ResourceSource, rootURL: URL) {
        self.source = source
        self.rootURL = rootURL.standardizedFileURL
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

    func listResources() async throws -> [ResourceItem] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            throw ResourceSourceError.permissionDenied
        } catch {
            throw ResourceSourceError.mapping(error)
        }

        return urls
            .map { itemURL in makeItem(from: itemURL) }
            .sorted { lhs, rhs in
                if lhs.kind == .folder && rhs.kind != .folder { return true }
                if lhs.kind != .folder && rhs.kind == .folder { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        let url = try resolvedURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ResourceSourceError.notFound
        }
        return .localFile(.init(fileURL: url, supportsRandomAccess: true))
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        let url = try resolvedURL(for: item)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ResourceSourceError.mapping(error)
        }
        let byteSize = (attributes[.size] as? NSNumber)?.int64Value
        let modifiedAt = attributes[.modificationDate] as? Date
        return ResourceMetadata(
            byteSize: byteSize,
            contentType: contentType(for: url),
            modifiedAt: modifiedAt,
            acceptsRanges: true
        )
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        let url = try resolvedURL(for: item)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ResourceSourceError.mapping(error)
        }
        guard let range else { return data }
        guard let clamped = range.clamped(toTotalLength: Int64(data.count)) else {
            return Data()
        }
        return data.subdata(in: Int(clamped.lowerBound)..<Int(clamped.upperBound + 1))
    }

    // MARK: - Private

    /// 把资源路径安全解析为磁盘 URL；任何穿越根目录的路径都会被拒绝。
    private func resolvedURL(for item: ResourceItem) throws -> URL {
        var relative = item.path
        while relative.hasPrefix("/") {
            relative.removeFirst()
        }
        guard !relative.isEmpty else {
            throw ResourceSourceError.invalidReference
        }
        let candidate = rootURL
            .appendingPathComponent(relative)
            .standardizedFileURL
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootURL.path + "/") else {
            throw ResourceSourceError.invalidReference
        }
        return candidate
    }

    private func makeItem(from url: URL) -> ResourceItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        let isDirectory = values?.isDirectory ?? false
        let kind = isDirectory ? .folder : kind(for: url)
        let capabilities: ResourceCapability = isDirectory
            ? [.list]
            : [.read, .rangeRead, .download]
        return ResourceItem(
            name: url.lastPathComponent,
            kind: kind,
            sourceID: source.id,
            path: url.lastPathComponent,
            sizeDescription: sizeDescription(values?.fileSize, isDirectory: isDirectory),
            modifiedDescription: modifiedDescription(values?.contentModificationDate),
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

    private func contentType(for url: URL) -> String? {
        switch kind(for: url) {
        case .pdf: return "application/pdf"
        case .markdown: return "text/markdown"
        case .text: return "text/plain"
        case .image: return "image/*"
        case .video: return "video/*"
        case .audio: return "audio/*"
        default: return nil
        }
    }

    private func sizeDescription(_ fileSize: Int?, isDirectory: Bool) -> String {
        if isDirectory { return "文件夹" }
        guard let fileSize else { return "未知大小" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }

    private func modifiedDescription(_ date: Date?) -> String {
        guard let date else { return "未知时间" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
