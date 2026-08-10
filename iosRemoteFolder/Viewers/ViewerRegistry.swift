import Foundation
import UniformTypeIdentifiers

enum ViewerKind: String, Sendable {
    case pdfReader
    case markdownReader
    case textReader
    case imageViewer
    case videoPlayer
    case musicPlayer
    case systemPreview
}

enum ViewerPreparation: Hashable, Sendable {
    case none
    case text(maximumBytes: Int64)
    case pdf(maximumBytes: Int64)
    case image(maximumBytes: Int64)
    case audio(maximumBytes: Int64)
    case video(maximumBytes: Int64)
}

struct ViewerResolution: Hashable, Sendable {
    let kind: ViewerKind
    let preparation: ViewerPreparation
    let fallbackDescription: String?
}

struct ViewerRegistry {
    static func viewer(for resource: ResourceItem) -> ViewerKind {
        resolve(resource: resource, metadata: resource.metadata).kind
    }

    /// 解析顺序与 D-034 一致：目录事实 -> typed metadata -> 扩展名 -> ResourceKind。
    /// 解析只描述 Viewer 需要的准备方式，不执行来源请求或物化。
    static func resolve(
        resource: ResourceItem,
        metadata: ResourceMetadata
    ) -> ViewerResolution {
        guard resource.kind != .folder, !metadata.isDirectory else {
            return ViewerResolution(
                kind: .systemPreview,
                preparation: .none,
                fallbackDescription: "文件夹不能作为内容打开"
            )
        }

        let identifierKind = kind(forTypeIdentifier: metadata.typeIdentifier)
        let mimeKind = kind(forMIMEType: metadata.mimeType)
        if let identifierKind, let mimeKind, !areCompatible(identifierKind, mimeKind) {
            return unsupported("文件类型元数据互相冲突")
        }

        let metadataKind = preferredKind(identifierKind, mimeKind)
        let extensionKind = kind(forExtension: resource.path)
        if let metadataKind, let extensionKind, !areCompatible(metadataKind, extensionKind) {
            return unsupported("文件类型与扩展名不一致")
        }

        guard let resolvedKind = preferredKind(metadataKind, extensionKind) ?? kind(for: resource.kind) else {
            return unsupported("无法从资源元数据确认内容类型")
        }
        switch resolvedKind {
        case .pdf:
            return ViewerResolution(
                kind: .pdfReader,
                preparation: .pdf(maximumBytes: 50 * 1024 * 1024),
                fallbackDescription: nil
            )
        case .text:
            return ViewerResolution(
                kind: .textReader,
                preparation: .text(maximumBytes: 10 * 1024 * 1024),
                fallbackDescription: nil
            )
        case .markdown:
            return ViewerResolution(
                kind: .markdownReader,
                preparation: .text(maximumBytes: 10 * 1024 * 1024),
                fallbackDescription: nil
            )
        case .image:
            return ViewerResolution(
                kind: .imageViewer,
                preparation: .image(maximumBytes: 50 * 1024 * 1024),
                fallbackDescription: nil
            )
        case .audio:
            return ViewerResolution(
                kind: .musicPlayer,
                preparation: .audio(maximumBytes: 50 * 1024 * 1024),
                fallbackDescription: nil
            )
        case .video:
            return ViewerResolution(
                kind: .videoPlayer,
                preparation: .video(maximumBytes: 50 * 1024 * 1024),
                fallbackDescription: nil
            )
        case .unknown, .folder:
            return unsupported("无法从资源元数据确认内容类型")
        }
    }

    private static func unsupported(_ description: String) -> ViewerResolution {
        ViewerResolution(
            kind: .systemPreview,
            preparation: .none,
            fallbackDescription: description
        )
    }

    private static func kind(forTypeIdentifier identifier: String?) -> ResourceKind? {
        guard let identifier,
              let type = UTType(identifier) else { return nil }
        if identifier.localizedCaseInsensitiveContains("markdown") {
            return .markdown
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) { return .text }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    private static func preferredKind(
        _ first: ResourceKind?,
        _ second: ResourceKind?
    ) -> ResourceKind? {
        switch (first, second) {
        case (.some(.markdown), _), (_, .some(.markdown)):
            return .markdown
        case (.some(let first), .some(let second)) where first == second:
            return first
        case (.some(let first), _):
            return first
        case (_, .some(let second)):
            return second
        default:
            return nil
        }
    }

    private static func areCompatible(_ first: ResourceKind, _ second: ResourceKind) -> Bool {
        first == second || (first.isTextLike && second.isTextLike)
    }

    private static func kind(forMIMEType mimeType: String?) -> ResourceKind? {
        guard let mimeType = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !mimeType.isEmpty else { return nil }
        if mimeType == "application/pdf" { return .pdf }
        if mimeType == "text/markdown" || mimeType == "text/x-markdown" {
            return .markdown
        }
        if mimeType.hasPrefix("text/") { return .text }
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        return nil
    }

    private static func kind(forExtension path: String) -> ResourceKind? {
        let extensionName = path
            .split(separator: "/")
            .last
            .flatMap { $0.split(separator: ".", omittingEmptySubsequences: true).last }
            .map(String.init)
            .map { $0.lowercased() }
        switch extensionName {
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        case "txt", "text", "log": return .text
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp": return .image
        case "mp4", "mov", "m4v", "mkv": return .video
        case "mp3", "m4a", "aac", "flac", "wav": return .audio
        default: return nil
        }
    }

    private static func kind(for resourceKind: ResourceKind) -> ResourceKind? {
        switch resourceKind {
        case .folder: return .folder
        case .pdf: return .pdf
        case .markdown: return .markdown
        case .text: return .text
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .unknown: return nil
        }
    }
}

private extension ResourceKind {
    var isTextLike: Bool {
        self == .text || self == .markdown
    }
}
