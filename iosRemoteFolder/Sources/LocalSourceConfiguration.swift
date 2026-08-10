import Foundation

/// 只包含本地来源的稳定身份、展示信息和 security-scoped bookmark。
///
/// `ResourceSource` 是运行时投影，不参与持久化；配置中没有绝对 URL、路径、
/// URLSession、请求头或任何凭证。D-032 会把该临时 UserDefaults 后端迁移到
/// SwiftData，但不会改变这个窄配置模型。
struct LocalSourceConfiguration: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var displayName: String
    var endpointDescription: String
    let location: LocalSourceLocation

    init(
        id: UUID = UUID(),
        displayName: String,
        endpointDescription: String = "Files 文件夹",
        location: LocalSourceLocation
    ) {
        self.id = id
        self.displayName = displayName
        self.endpointDescription = endpointDescription
        self.location = location
    }

    /// 运行时来源投影；状态仍由 `SourcesStore` 单向维护。
    var resourceSource: ResourceSource {
        ResourceSource(
            id: id,
            name: displayName,
            kind: .local,
            endpoint: endpointDescription,
            status: .disconnected,
            itemCountDescription: ""
        )
    }
}

enum LocalSourceConfigurationError: LocalizedError, Hashable, Sendable {
    case duplicateSourceID(UUID)
    case duplicateLocation
    case sourceNotFound(UUID)
    case invalidDisplayName
    case invalidEndpointDescription
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case .duplicateSourceID(let sourceID):
            "来源 ID 重复：\(sourceID.uuidString)"
        case .duplicateLocation:
            "该文件夹已经添加为来源"
        case .sourceNotFound(let sourceID):
            "找不到来源：\(sourceID.uuidString)"
        case .invalidDisplayName:
            "来源名称不能为空"
        case .invalidEndpointDescription:
            "来源描述无效"
        case .invalidStoredData:
            "来源配置无法读取"
        }
    }
}

/// D-032 前的窄配置后端。所有读写都发生在 MainActor，避免把 UserDefaults
/// 或其可变状态泄漏到 adapter、registry 或异步文件访问边界。
@MainActor
final class LocalSourceConfigurationStore {
    private struct Payload: Codable {
        let version: Int
        let configurations: [LocalSourceConfiguration]
    }

    private static let currentVersion = 1
    private static let storageKey = "localSourceConfigurations.v1"

    private let defaults: UserDefaults
    private(set) var configurations: [LocalSourceConfiguration]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.configurations = []
    }

    /// 从 UserDefaults 恢复配置；空值表示首次启动。
    @discardableResult
    func load() throws -> [LocalSourceConfiguration] {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            configurations = []
            return []
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw LocalSourceConfigurationError.invalidStoredData
        }
        guard payload.version == Self.currentVersion else {
            throw LocalSourceConfigurationError.invalidStoredData
        }
        try validate(payload.configurations)
        configurations = payload.configurations
        return configurations
    }

    func configuration(for sourceID: UUID) -> LocalSourceConfiguration? {
        configurations.first { $0.id == sourceID }
    }

    func contains(location: LocalSourceLocation) -> Bool {
        configurations.contains { $0.location.isSameResolvedLocation(as: location) }
    }

    /// 仅在新来源插入时使用；不会静默覆盖同 ID 配置。
    func insert(_ configuration: LocalSourceConfiguration) throws {
        try validate(configuration)
        guard !configurations.contains(where: { $0.id == configuration.id }) else {
            throw LocalSourceConfigurationError.duplicateSourceID(configuration.id)
        }
        guard !contains(location: configuration.location) else {
            throw LocalSourceConfigurationError.duplicateLocation
        }
        var nextConfigurations = configurations
        nextConfigurations.append(configuration)
        try persist(nextConfigurations)
        configurations = nextConfigurations
    }

    /// 重新授权使用同一 source ID 替换配置；未知 ID 明确失败。
    func replace(_ configuration: LocalSourceConfiguration) throws {
        try validate(configuration)
        guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else {
            throw LocalSourceConfigurationError.sourceNotFound(configuration.id)
        }
        guard !configurations.enumerated().contains(where: { offset, existing in
            offset != index && existing.location.isSameResolvedLocation(as: configuration.location)
        }) else {
            throw LocalSourceConfigurationError.duplicateLocation
        }
        var nextConfigurations = configurations
        nextConfigurations[index] = configuration
        try persist(nextConfigurations)
        configurations = nextConfigurations
    }

    /// 删除只清理配置；不会触碰 bookmark 对应的原目录。
    @discardableResult
    func remove(sourceID: UUID) throws -> LocalSourceConfiguration {
        guard let index = configurations.firstIndex(where: { $0.id == sourceID }) else {
            throw LocalSourceConfigurationError.sourceNotFound(sourceID)
        }
        let removed = configurations[index]
        var nextConfigurations = configurations
        nextConfigurations.remove(at: index)
        try persist(nextConfigurations)
        configurations = nextConfigurations
        return removed
    }

    /// 供恢复/迁移使用的整批写入入口，严格拒绝重复 ID 或 bookmark。
    func save(_ configurations: [LocalSourceConfiguration]) throws {
        try validate(configurations)
        try persist(configurations)
        self.configurations = configurations
    }

    private func validate(_ configuration: LocalSourceConfiguration) throws {
        guard !configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalSourceConfigurationError.invalidDisplayName
        }
        let endpoint = configuration.endpointDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty,
              !endpoint.contains("://"),
              !endpoint.hasPrefix("/") else {
            throw LocalSourceConfigurationError.invalidEndpointDescription
        }
    }

    private func validate(_ configurations: [LocalSourceConfiguration]) throws {
        var sourceIDs = Set<UUID>()
        var locations: [LocalSourceLocation] = []
        for configuration in configurations {
            try validate(configuration)
            guard sourceIDs.insert(configuration.id).inserted else {
                throw LocalSourceConfigurationError.duplicateSourceID(configuration.id)
            }
            guard !locations.contains(where: {
                $0.isSameResolvedLocation(as: configuration.location)
            }) else {
                throw LocalSourceConfigurationError.duplicateLocation
            }
            locations.append(configuration.location)
        }
    }

    private func persist(_ configurations: [LocalSourceConfiguration]) throws {
        let payload = Payload(version: Self.currentVersion, configurations: configurations)
        do {
            let data = try JSONEncoder().encode(payload)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            throw LocalSourceConfigurationError.invalidStoredData
        }
    }
}
