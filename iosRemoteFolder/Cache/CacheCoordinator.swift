import Foundation

enum ResourceCacheState: String, Sendable {
    case online
    case previewCached
    case partiallyCached
    case offlineAvailable
    case needsRefresh
    case failed
}

/// The representation of content that a cache entry stores.
///
/// A byte range stays structured all the way through key construction. This
/// prevents two different range values from accidentally sharing a string
/// representation and keeps range validation in `ResourceByteRange`.
enum ResourceCacheVariant: Hashable, Sendable {
    case content
    case preview
    case thumbnail
    case byteRange(ResourceByteRange)

    /// Descriptive aliases keep call sites readable without introducing a
    /// second representation for the same cache variants.
    static var original: Self { .content }

    static func range(_ value: ResourceByteRange) -> Self {
        .byteRange(value)
    }
}

/// A persistent cache identity for one content revision and one variant.
///
/// `ResourceRevision.unknown` is deliberately rejected. An unknown revision
/// cannot prove that bytes from a previous session still describe the current
/// resource, so it must never become a cross-session cache key.
struct ResourceCacheKey: Hashable, Sendable {
    let identity: ResourceIdentity
    let revision: ResourceRevision
    let variant: ResourceCacheVariant

    var resourceIdentity: ResourceIdentity { identity }
    var resourceRevision: ResourceRevision { revision }

    init?(
        identity: ResourceIdentity,
        revision: ResourceRevision,
        variant: ResourceCacheVariant
    ) {
        guard revision.isKnown else { return nil }
        if case .byteRange(let range) = variant, !range.isValid {
            return nil
        }
        self.identity = identity
        self.revision = revision
        self.variant = variant
    }

    /// Named construction makes the persistence boundary explicit at call
    /// sites while retaining the failable initializer for ordinary use.
    static func persistent(
        identity: ResourceIdentity,
        revision: ResourceRevision,
        variant: ResourceCacheVariant
    ) -> ResourceCacheKey? {
        ResourceCacheKey(identity: identity, revision: revision, variant: variant)
    }
}

/// Holds cache state keyed by location, content revision and representation.
///
/// The coordinator intentionally has no identity-only API. Callers must first
/// establish a known revision and select a concrete variant, so a replacement
/// file cannot inherit state from an older revision at the same path.
actor CacheCoordinator {
    private var states: [ResourceCacheKey: ResourceCacheState] = [:]

    func state(for key: ResourceCacheKey) -> ResourceCacheState {
        states[key] ?? .online
    }

    func setState(_ state: ResourceCacheState, for key: ResourceCacheKey) {
        states[key] = state
    }

    /// Looks up a persistent state without allowing an unknown revision to
    /// enter the cache. `nil` means no persistent key can be formed.
    func state(
        for identity: ResourceIdentity,
        revision: ResourceRevision,
        variant: ResourceCacheVariant
    ) -> ResourceCacheState? {
        guard let key = ResourceCacheKey(identity: identity, revision: revision, variant: variant) else {
            return nil
        }
        return state(for: key)
    }

    /// Stores a state when a persistent key can be formed. Returns `false`
    /// for unknown revisions and leaves the cache untouched.
    @discardableResult
    func setState(
        _ state: ResourceCacheState,
        for identity: ResourceIdentity,
        revision: ResourceRevision,
        variant: ResourceCacheVariant
    ) -> Bool {
        guard let key = ResourceCacheKey(identity: identity, revision: revision, variant: variant) else {
            return false
        }
        states[key] = state
        return true
    }
}
