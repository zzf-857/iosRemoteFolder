import Foundation

/// 内容会话的唯一创建入口。
///
/// 该服务在会话创建前校验来源、稳定身份、canonical 逻辑路径、目录事实和
/// `.read` 能力；上层不需要也不能取得 adapter、引用或请求细节。
final class ResourceAccessService: Sendable {
    private let registry: SourceRegistry
    private let cacheCoordinator: CacheCoordinator?

    init(
        registry: SourceRegistry,
        cacheCoordinator: CacheCoordinator? = nil
    ) {
        self.registry = registry
        self.cacheCoordinator = cacheCoordinator
    }

    func makeSession(for item: ResourceItem) async throws -> ResourceContentSession {
        guard Self.isCanonicalResource(item) else {
            throw ResourceSourceError.invalidReference
        }
        guard await registry.hasAdapter(for: item.sourceID) else {
            throw ResourceSourceError.capabilityUnavailable
        }
        guard item.kind != .folder,
              !item.metadata.isDirectory,
              item.capabilities.contains(.read) else {
            throw ResourceSourceError.capabilityUnavailable
        }

        let session = ResourceContentSession(registry: registry, item: item)
        do {
            let latestMetadata = try await session.fetchMetadata()
            guard !latestMetadata.isDirectory else {
                throw ResourceSourceError.capabilityUnavailable
            }
            return session
        } catch {
            // A failed creation probe must not leave an unowned operation or
            // a usable session behind; close is idempotent for all failures.
            await session.close()
            throw error
        }
    }

    /// Creates a session backed only by a previously persisted complete-content
    /// cache entry. This path deliberately skips the source adapter so a cached
    /// resource remains openable while its source is unavailable.
    func makeOfflineSession(for item: ResourceItem) async throws -> ResourceContentSession {
        guard Self.isCanonicalResource(item) else {
            throw ResourceSourceError.invalidReference
        }
        guard item.kind != .folder,
              !item.metadata.isDirectory,
              item.metadata.revision.isKnown,
              let cacheCoordinator,
              let key = ResourceCacheKey(
                  identity: item.id,
                  revision: item.metadata.revision,
                  variant: .content
              ),
              await cacheCoordinator.state(for: key) == .offlineAvailable else {
            throw ResourceSourceError.capabilityUnavailable
        }

        let session = ResourceContentSession(
            cacheCoordinator: cacheCoordinator,
            item: item,
            metadata: item.metadata
        )
        do {
            _ = try await session.fetchMetadata()
            return session
        } catch {
            await session.close()
            throw error
        }
    }

    private static func isCanonicalResource(_ item: ResourceItem) -> Bool {
        guard item.sourceID == item.id.sourceID,
              let path = ResourcePath(rawValue: item.path),
              path.normalized == item.path,
              item.id.logicalPath == path.normalized else {
            return false
        }
        return ResourceIdentity(sourceID: item.sourceID, logicalPath: path) == item.id
    }
}
