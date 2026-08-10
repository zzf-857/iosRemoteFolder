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

/// A bounded resume position owned by the viewer layer.
///
/// D-042 currently persists only media time. Keeping the position typed avoids
/// treating an arbitrary floating-point value as a valid playback location and
/// leaves room for a separately specified page/scroll contract later.
enum ResourceResumePosition: Hashable, Sendable {
    case seconds(TimeInterval)

    var secondsValue: TimeInterval? {
        guard case .seconds(let value) = self,
              value.isFinite,
              value >= 0 else {
            return nil
        }
        return value
    }
}

/// 资源的稳定位置身份：由来源 ID 与规范化逻辑路径确定性派生。
///
/// `logicalPath` 保留为规范化字符串以兼容现有领域调用点，但显式构造器只
/// 接受 `ResourcePath`，因此模块内不存在以任意原始字符串构造真实身份的入口。
/// 持久化时使用版本化的 `identityKey`，不包含展示名称、URL 或请求头。
struct ResourceIdentity: Hashable, Sendable {
    static let keyVersion = "v1"

    let sourceID: UUID
    let logicalPath: String

    init(sourceID: UUID, logicalPath: ResourcePath) {
        self.sourceID = sourceID
        self.logicalPath = logicalPath.normalized
    }

    /// 可逆、版本化的持久化键：`v1|<lowercase UUID>|<normalized path>`。
    var identityKey: String {
        "\(Self.keyVersion)|\(sourceID.uuidString.lowercased())|\(logicalPath)"
    }

    /// 从 canonical `identityKey` 解析身份。
    ///
    /// 只切前两个 `|`；余下全部属于路径，因此文件名中的 `|` 不会丢失。
    /// UUID 与路径都必须已经是 canonical 表示，任何可被归一化但本身不规范的
    /// 输入都被拒绝，避免解析时静默产生另一身份。
    init?(identityKey: String) {
        let fields = identityKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              String(fields[0]) == Self.keyVersion,
              !fields[1].isEmpty,
              !fields[2].isEmpty else {
            return nil
        }

        let uuidText = String(fields[1])
        guard let sourceID = UUID(uuidString: uuidText),
              sourceID.uuidString.lowercased() == uuidText else {
            return nil
        }
        let pathText = String(fields[2])
        guard let path = ResourcePath(rawValue: pathText),
              path.normalized == pathText else {
            return nil
        }
        self.init(sourceID: sourceID, logicalPath: path)
    }

    /// Explicit spelling for callers that prefer a parser-style API.
    static func parse(identityKey: String) -> ResourceIdentity? {
        ResourceIdentity(identityKey: identityKey)
    }
}

/// Evidence describing the bytes currently occupying a resource location.
///
/// The associated values are intentionally opaque. In particular, ETags are
/// retained exactly as received, including weak ETags and quote characters.
enum ResourceRevision: Hashable, Sendable {
    case etag(String)
    case serverVersion(String)
    case modifiedAndSize(modifiedAt: Date, byteSize: Int64)
    case unknown

    /// Selects the strongest available evidence in the only supported order:
    /// ETag, server version, modification time + non-negative byte size, unknown.
    static func strongest(
        etag: String?,
        serverVersion: String?,
        modifiedAt: Date?,
        byteSize: Int64?
    ) -> ResourceRevision {
        if let etag, !Self.isBlank(etag) {
            return .etag(etag)
        }
        if let serverVersion, !Self.isBlank(serverVersion) {
            return .serverVersion(serverVersion)
        }
        if let modifiedAt, let byteSize, byteSize >= 0 {
            return .modifiedAndSize(modifiedAt: modifiedAt, byteSize: byteSize)
        }
        return .unknown
    }

    var isKnown: Bool {
        switch self {
        case .etag(let value), .serverVersion(let value):
            return !Self.isBlank(value)
        case .modifiedAndSize(_, let byteSize):
            return byteSize >= 0
        case .unknown:
            return false
        }
    }

    var isUnknown: Bool { !isKnown }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Typed facts reported by a source adapter. Presentation text is deliberately
/// absent; the UI formats these values with the active system locale.
struct ResourceMetadata: Hashable, Sendable {
    var byteSize: Int64?
    var modifiedAt: Date?
    var mimeType: String?
    var typeIdentifier: String?
    var isDirectory: Bool
    var acceptsRanges: Bool
    var revision: ResourceRevision

    init(
        byteSize: Int64? = nil,
        modifiedAt: Date? = nil,
        mimeType: String? = nil,
        typeIdentifier: String? = nil,
        isDirectory: Bool = false,
        acceptsRanges: Bool = false,
        revision: ResourceRevision = .unknown
    ) {
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.mimeType = mimeType
        self.typeIdentifier = typeIdentifier
        self.isDirectory = isDirectory
        self.acceptsRanges = acceptsRanges
        self.revision = revision
    }
}

struct ResourceItem: Identifiable, Hashable, Sendable {
    let id: ResourceIdentity
    let name: String
    let kind: ResourceKind
    let sourceID: UUID
    let path: String
    let metadata: ResourceMetadata
    let capabilities: ResourceCapability
    let accent: ResourceAccent

    /// 单一构造入口：身份（`id`）与规范化路径（`path`）都由 `sourceID + logicalPath`
    /// 确定性派生，调用方无法分别传入互相矛盾的 `id`、`sourceID` 与 `path`，
    /// 也无法用共享占位污染真实数据。
    init(
        sourceID: UUID,
        logicalPath: ResourcePath,
        name: String,
        kind: ResourceKind,
        metadata: ResourceMetadata,
        capabilities: ResourceCapability,
        accent: ResourceAccent
    ) {
        self.sourceID = sourceID
        let normalized = logicalPath.normalized
        self.path = normalized
        self.id = ResourceIdentity(sourceID: sourceID, logicalPath: logicalPath)
        self.name = name
        self.kind = kind
        self.metadata = metadata
        self.capabilities = capabilities
        self.accent = accent
    }
}

struct ResourceSource: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let kind: SourceKind
    let endpoint: String
    var status: SourceStatus
    var itemCountDescription: String

    enum SourceKind: String, Hashable, Sendable {
        case alist
        case webdav
        case local
        case lan
        case http

        var title: String {
            switch self {
            case .alist: "Alist"
            case .webdav: "WebDAV"
            case .local: "本地文件"
            case .lan: "局域网"
            case .http: "HTTP 直链"
            }
        }

        var systemImage: String {
            switch self {
            case .alist: "server.rack"
            case .webdav: "cloud"
            case .local: "internaldrive"
            case .lan: "wifi"
            case .http: "link"
            }
        }
    }

    enum SourceStatus: String, Hashable, Sendable {
        case connected
        case connecting
        case disconnected
        case indexing
        case needsAttention
        case localOnly

        var title: String {
            switch self {
            case .connected: "已连接"
            case .connecting: "连接中"
            case .disconnected: "未连接"
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

    /// 按资源类型推导默认强调色，与 SampleData 的视觉语言保持一致。
    static func recommended(for kind: ResourceKind) -> ResourceAccent {
        switch kind {
        case .folder: .teal
        case .pdf: .orange
        case .markdown: .teal
        case .text: .blue
        case .image: .blue
        case .video: .purple
        case .audio: .pink
        case .unknown: .blue
        }
    }
}
