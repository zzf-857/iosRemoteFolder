import Foundation

enum ViewerKind: String, Sendable {
    case pdfReader
    case markdownReader
    case textReader
    case imageViewer
    case videoPlayer
    case musicPlayer
    case systemPreview
}

struct ViewerRegistry {
    static func viewer(for resource: ResourceItem) -> ViewerKind {
        switch resource.kind {
        case .pdf: .pdfReader
        case .markdown: .markdownReader
        case .text: .textReader
        case .image: .imageViewer
        case .video: .videoPlayer
        case .audio: .musicPlayer
        case .folder, .unknown: .systemPreview
        }
    }
}

