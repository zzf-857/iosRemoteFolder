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
    private var states: [UUID: ResourceCacheState] = [:]

    func state(for resourceID: UUID) -> ResourceCacheState {
        states[resourceID] ?? .online
    }

    func setState(_ state: ResourceCacheState, for resourceID: UUID) {
        states[resourceID] = state
    }
}

