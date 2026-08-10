import Foundation
import SwiftData

/// SwiftData 中保存的本地来源记录。bookmark 是唯一的位置事实，解析后的 URL
/// 不会进入模型或持久化层。
@Model
final class LocalSourceConfigurationRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var endpointDescription: String
    var bookmarkData: Data

    init(
        id: UUID,
        displayName: String,
        endpointDescription: String,
        bookmarkData: Data
    ) {
        self.id = id
        self.displayName = displayName
        self.endpointDescription = endpointDescription
        self.bookmarkData = bookmarkData
    }
}

/// SwiftData 中保存的远端来源描述。凭证本身不在这里，只保存可验证的
/// credential reference；用户名、密码、Token 和 Cookie 仍由 Keychain 管理。
@Model
final class RemoteSourceConfigurationRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var endpoint: String
    var kindRawValue: String
    var credentialReference: String?

    init(
        id: UUID,
        displayName: String,
        endpoint: String,
        kindRawValue: String,
        credentialReference: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.kindRawValue = kindRawValue
        self.credentialReference = credentialReference
    }
}

/// App composition root 共享的 SwiftData 容器工厂。Store 不创建第二份生产容器；
/// 测试/预览可以显式请求内存容器。
enum SourceConfigurationPersistence {
    static func makePersistentContainer() throws -> ModelContainer {
        try makeContainer(isStoredInMemoryOnly: false)
    }

    /// 仅供测试和迁移复核显式重开同一个文件型 store；路径不进入 UI 或 adapter。
    static func makePersistentContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func makeInMemoryContainer() -> ModelContainer {
        do {
            return try makeContainer(isStoredInMemoryOnly: true)
        } catch {
            fatalError("无法创建来源配置内存容器：\(error.localizedDescription)")
        }
    }

    private static func makeContainer(isStoredInMemoryOnly: Bool) throws -> ModelContainer {
        let schema = makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func makeSchema() -> Schema {
        Schema([
            LocalSourceConfigurationRecord.self,
            RemoteSourceConfigurationRecord.self
        ])
    }
}
