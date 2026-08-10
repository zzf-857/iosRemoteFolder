import Foundation
import Security
import SwiftData

/// 持久化的远端来源描述只包含可公开配置和不含秘密的凭证引用。
/// 用户名、密码等实际凭证由 `RemoteCredentialStore` 单独写入 Keychain。
struct RemoteSourceConfiguration: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var displayName: String
    var endpoint: String
    let kind: ResourceSource.SourceKind
    let credentialReference: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        endpoint: URL,
        kind: ResourceSource.SourceKind,
        credentialReference: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint.absoluteString
        self.kind = kind
        self.credentialReference = credentialReference
    }

    var resourceSource: ResourceSource {
        ResourceSource(
            id: id,
            name: displayName,
            kind: kind,
            endpoint: endpoint,
            status: .disconnected,
            itemCountDescription: ""
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case endpoint
        case kind
        case credentialReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        let kindRawValue = try container.decode(String.self, forKey: .kind)
        guard let kind = ResourceSource.SourceKind(rawValue: kindRawValue),
              kind == .webdav || kind == .alist else {
            throw RemoteSourceConfigurationError.invalidStoredData
        }
        self.kind = kind
        credentialReference = try container.decodeIfPresent(String.self, forKey: .credentialReference)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(credentialReference, forKey: .credentialReference)
    }
}

enum RemoteSourceConfigurationError: LocalizedError, Hashable, Sendable {
    case duplicateSourceID(UUID)
    case sourceNotFound(UUID)
    case invalidDisplayName
    case invalidEndpoint
    case invalidCredentialReference
    case invalidStoredData
    case credentialUnavailable

    var errorDescription: String? {
        switch self {
        case .duplicateSourceID(let sourceID):
            "来源 ID 重复：\(sourceID.uuidString)"
        case .sourceNotFound(let sourceID):
            "找不到来源：\(sourceID.uuidString)"
        case .invalidDisplayName:
            "来源名称不能为空"
        case .invalidEndpoint:
            "远端地址无效；请输入不含账号密码、查询参数或片段的 HTTP(S) 地址"
        case .invalidCredentialReference:
            "来源凭证引用无效"
        case .invalidStoredData:
            "远端来源配置无法读取"
        case .credentialUnavailable:
            "远端来源凭证不可用，请重新添加来源"
        }
    }
}

/// SwiftData 中保存的窄描述存储。
/// 这里故意只写 source descriptor 和 credential reference，不写 URL 中的秘密、
/// Authorization、Cookie 或密码；旧 UserDefaults payload 只用于一次性迁移。
@MainActor
final class RemoteSourceConfigurationStore {
    private struct Payload: Codable {
        let version: Int
        let configurations: [RemoteSourceConfiguration]
    }

    private static let currentVersion = 1
    private static let storageKey = "remoteSourceConfigurations.v1"

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let migrationDefaults: UserDefaults
    private(set) var configurations: [RemoteSourceConfiguration] = []

    init(modelContainer: ModelContainer, defaults: UserDefaults = .standard) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.migrationDefaults = defaults
    }

    /// 兼容测试/预览注入：使用独立内存容器，UserDefaults 只作为一次性旧数据迁移源。
    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            modelContainer: SourceConfigurationPersistence.makeInMemoryContainer(),
            defaults: defaults
        )
    }

    @discardableResult
    func load() throws -> [RemoteSourceConfiguration] {
        let records: [RemoteSourceConfigurationRecord]
        do {
            records = try modelContext.fetch(FetchDescriptor<RemoteSourceConfigurationRecord>())
        } catch {
            throw RemoteSourceConfigurationError.invalidStoredData
        }

        if records.isEmpty, let data = migrationDefaults.data(forKey: Self.storageKey) {
            let payload = try decodeLegacyPayload(data)
            try validate(payload.configurations)
            try persistRecords(payload.configurations)
            migrationDefaults.removeObject(forKey: Self.storageKey)
            configurations = payload.configurations
            return configurations
        }

        do {
            let loaded = try records.map(configuration(from:))
            try validate(loaded)
            configurations = loaded
            migrationDefaults.removeObject(forKey: Self.storageKey)
            return loaded
        } catch let error as RemoteSourceConfigurationError {
            throw error
        } catch {
            throw RemoteSourceConfigurationError.invalidStoredData
        }
    }

    func configuration(for sourceID: UUID) -> RemoteSourceConfiguration? {
        configurations.first { $0.id == sourceID }
    }

    func insert(_ configuration: RemoteSourceConfiguration) throws {
        try validate(configuration)
        guard !configurations.contains(where: { $0.id == configuration.id }) else {
            throw RemoteSourceConfigurationError.duplicateSourceID(configuration.id)
        }
        var next = configurations
        next.append(configuration)
        try persist(next)
        configurations = next
    }

    @discardableResult
    func remove(sourceID: UUID) throws -> RemoteSourceConfiguration {
        guard let index = configurations.firstIndex(where: { $0.id == sourceID }) else {
            throw RemoteSourceConfigurationError.sourceNotFound(sourceID)
        }
        let removed = configurations[index]
        var next = configurations
        next.remove(at: index)
        try persist(next)
        configurations = next
        return removed
    }

    func save(_ configurations: [RemoteSourceConfiguration]) throws {
        try validate(configurations)
        try persist(configurations)
        self.configurations = configurations
    }

    private func validate(_ configuration: RemoteSourceConfiguration) throws {
        guard !configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteSourceConfigurationError.invalidDisplayName
        }
        guard configuration.kind == .webdav || configuration.kind == .alist,
              let endpoint = URL(string: configuration.endpoint),
              let normalized = try? WebDAVSourceAdapter.normalizedEndpoint(endpoint),
              normalized.absoluteString == configuration.endpoint else {
            throw RemoteSourceConfigurationError.invalidEndpoint
        }
        if let reference = configuration.credentialReference {
            guard UUID(uuidString: reference) != nil,
                  reference == reference.lowercased() else {
                throw RemoteSourceConfigurationError.invalidCredentialReference
            }
        }
    }

    private func validate(_ configurations: [RemoteSourceConfiguration]) throws {
        var sourceIDs = Set<UUID>()
        for configuration in configurations {
            try validate(configuration)
            guard sourceIDs.insert(configuration.id).inserted else {
                throw RemoteSourceConfigurationError.duplicateSourceID(configuration.id)
            }
        }
    }

    private func persist(_ configurations: [RemoteSourceConfiguration]) throws {
        do {
            try persistRecords(configurations)
        } catch {
            throw RemoteSourceConfigurationError.invalidStoredData
        }
    }

    private func decodeLegacyPayload(_ data: Data) throws -> Payload {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == Self.currentVersion else {
                throw RemoteSourceConfigurationError.invalidStoredData
            }
            return payload
        } catch {
            throw RemoteSourceConfigurationError.invalidStoredData
        }
    }

    private func configuration(from record: RemoteSourceConfigurationRecord) throws -> RemoteSourceConfiguration {
        guard let kind = ResourceSource.SourceKind(rawValue: record.kindRawValue),
              kind == .webdav || kind == .alist,
              let endpoint = URL(string: record.endpoint) else {
            throw RemoteSourceConfigurationError.invalidStoredData
        }
        return RemoteSourceConfiguration(
            id: record.id,
            displayName: record.displayName,
            endpoint: endpoint,
            kind: kind,
            credentialReference: record.credentialReference
        )
    }

    private func persistRecords(_ configurations: [RemoteSourceConfiguration]) throws {
        do {
            let existing = try modelContext.fetch(FetchDescriptor<RemoteSourceConfigurationRecord>())
            existing.forEach(modelContext.delete)
            for configuration in configurations {
                modelContext.insert(
                    RemoteSourceConfigurationRecord(
                        id: configuration.id,
                        displayName: configuration.displayName,
                        endpoint: configuration.endpoint,
                        kindRawValue: configuration.kind.rawValue,
                        credentialReference: configuration.credentialReference
                    )
                )
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw RemoteSourceConfigurationError.invalidStoredData
        }
    }
}

struct RemoteCredentials: Hashable, Sendable {
    let username: String
    let password: String
}

enum RemoteCredentialStoreError: LocalizedError, Hashable, Sendable {
    case invalidReference
    case encodingFailed
    case keychain(OSStatus)
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case .invalidReference:
            "来源凭证引用无效"
        case .encodingFailed, .invalidStoredData:
            "来源凭证无法读取"
        case .keychain:
            "系统凭证存储暂时不可用"
        }
    }
}

/// WebDAV/Alist 的用户名和密码只存在 Keychain。引用本身可以安全地和来源
/// descriptor 一起持久化；日志和 `ResourceItem` 永远不会接触实际秘密。
@MainActor
final class RemoteCredentialStore {
    private struct Payload: Codable {
        let username: String
        let password: String
    }

    private let service = "iosRemoteFolder.remote-source"

    func save(_ credentials: RemoteCredentials, reference: String) throws {
        guard Self.isValidReference(reference) else {
            throw RemoteCredentialStoreError.invalidReference
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(
                Payload(username: credentials.username, password: credentials.password)
            )
        } catch {
            throw RemoteCredentialStoreError.encodingFailed
        }

        var query = baseQuery(reference: reference)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw RemoteCredentialStoreError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw RemoteCredentialStoreError.keychain(updateStatus)
        }
    }

    func load(reference: String) throws -> RemoteCredentials? {
        guard Self.isValidReference(reference) else {
            throw RemoteCredentialStoreError.invalidReference
        }
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw RemoteCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw RemoteCredentialStoreError.invalidStoredData
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return RemoteCredentials(username: payload.username, password: payload.password)
        } catch {
            throw RemoteCredentialStoreError.invalidStoredData
        }
    }

    func remove(reference: String) throws {
        guard Self.isValidReference(reference) else {
            throw RemoteCredentialStoreError.invalidReference
        }
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteCredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
    }

    private static func isValidReference(_ reference: String) -> Bool {
        UUID(uuidString: reference) != nil && reference == reference.lowercased()
    }
}
