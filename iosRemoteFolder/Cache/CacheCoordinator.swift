import Foundation

enum ResourceCacheState: String, Sendable {
    case online
    case previewCached
    case partiallyCached
    case offlineAvailable
    case needsRefresh
    case failed
}

actor CacheCoordinator {
    /// 缓存键统一使用稳定身份 `ResourceIdentity`，与资源列举、导航和缓存寻址
    /// 共用同一套不可伪造的身份，不再依赖可能漂移的随机 UUID。
    private var states: [ResourceIdentity: ResourceCacheState] = [:]

    func state(for identity: ResourceIdentity) -> ResourceCacheState {
        states[identity] ?? .online
    }

    func setState(_ state: ResourceCacheState, for identity: ResourceIdentity) {
        states[identity] = state
    }
}

