import Foundation

enum ResourceKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case folder
    case pdf
    case markdown
    case text
    case image
    case video
    case audio
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "文件夹"
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .text: "TXT"
        case .image: "图片"
        case .video: "视频"
        case .audio: "音乐"
        case .unknown: "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .folder: "folder.fill"
        case .pdf: "doc.richtext.fill"
        case .markdown: "text.badge.checkmark"
        case .text: "doc.plaintext.fill"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "music.note"
        case .unknown: "doc.fill"
        }
    }
}

struct ResourceCapability: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let list = Self(rawValue: 1 << 0)
    static let read = Self(rawValue: 1 << 1)
    static let rangeRead = Self(rawValue: 1 << 2)
    static let directURL = Self(rawValue: 1 << 3)
    static let thumbnail = Self(rawValue: 1 << 4)
    static let download = Self(rawValue: 1 << 5)
    static let search = Self(rawValue: 1 << 6)
}

struct ResourceItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let kind: ResourceKind
    let sourceID: UUID
    let path: String
    let sizeDescription: String
    let modifiedDescription: String
    let capabilities: ResourceCapability
    let accent: ResourceAccent

    init(
        id: UUID = UUID(),
        name: String,
        kind: ResourceKind,
        sourceID: UUID,
        path: String,
        sizeDescription: String,
        modifiedDescription: String,
        capabilities: ResourceCapability,
        accent: ResourceAccent
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sourceID = sourceID
        self.path = path
        self.sizeDescription = sizeDescription
        self.modifiedDescription = modifiedDescription
        self.capabilities = capabilities
        self.accent = accent
    }
}

struct ResourceSource: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let kind: SourceKind
    let endpoint: String
    let status: SourceStatus
    let itemCountDescription: String

    enum SourceKind: String, Hashable, Sendable {
        case alist
        case webdav
        case local
        case lan

        var title: String {
            switch self {
            case .alist: "Alist"
            case .webdav: "WebDAV"
            case .local: "本地文件"
            case .lan: "局域网"
            }
        }

        var systemImage: String {
            switch self {
            case .alist: "server.rack"
            case .webdav: "cloud"
            case .local: "internaldrive"
            case .lan: "wifi"
            }
        }
    }

    enum SourceStatus: String, Hashable, Sendable {
        case connected
        case indexing
        case needsAttention
        case localOnly

        var title: String {
            switch self {
            case .connected: "已连接"
            case .indexing: "索引中"
            case .needsAttention: "需要处理"
            case .localOnly: "仅本地"
            }
        }
    }
}

enum ResourceAccent: String, Hashable, Sendable {
    case teal
    case blue
    case orange
    case pink
    case purple

    var colorName: String { rawValue }
}

