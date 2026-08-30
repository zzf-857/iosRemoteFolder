import CryptoKit
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

    /// Stable input for the on-disk filename. The filename itself is a digest,
    /// so logical paths, URLs and revision values never become filesystem paths.
    var persistenceToken: String {
        "\(identity.identityKey)\u{1F}\(revision.persistenceToken)\u{1F}\(variant.persistenceToken)"
    }
}

/// Holds cache state keyed by location, content revision and representation.
///
/// The coordinator intentionally has no identity-only API. Callers must first
/// establish a known revision and select a concrete variant, so a replacement
/// file cannot inherit state from an older revision at the same path.
actor CacheCoordinator {
    private struct ManifestEntry: Codable, Sendable {
        let identityKey: String
    }

    private var states: [ResourceCacheKey: ResourceCacheState] = [:]
    private let fileManager: FileManager
    private let rootURL: URL
    private let manifestURL: URL
    private var manifest: [String: ManifestEntry]

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = rootURL ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.rootURL = baseURL.appendingPathComponent(
            "iosRemoteFolder/content",
            isDirectory: true
        )
        self.manifestURL = self.rootURL.appendingPathComponent(
            "manifest.json",
            isDirectory: false
        )
        self.manifest = Self.loadManifest(
            at: self.manifestURL
        )
    }

    func state(for key: ResourceCacheKey) -> ResourceCacheState {
        if let state = states[key] {
            return state
        }
        let digest = digest(for: key)
        return manifest[digest]?.identityKey == key.identity.identityKey
            && fileManager.fileExists(atPath: fileURL(for: key).path)
            ? .offlineAvailable
            : .online
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

    /// Reads a bounded content entry. A missing, unreadable or oversized entry
    /// is treated as a cache miss and removed so the caller can safely go back
    /// to the source of truth.
    func data(
        for key: ResourceCacheKey,
        maximumBytes: Int64
    ) throws -> Data? {
        guard maximumBytes > 0 else {
            throw ResourceSourceError.invalidReference
        }

        let url = fileURL(for: key)
        let digest = digest(for: key)
        guard manifest[digest]?.identityKey == key.identity.identityKey,
              fileManager.fileExists(atPath: url.path) else {
            removeFile(at: url)
            states[key] = .online
            return nil
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= 0,
              fileSize.int64Value <= maximumBytes else {
            removeFile(at: url)
            states[key] = .online
            return nil
        }

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard Int64(data.count) <= maximumBytes else {
                removeFile(at: url)
                states[key] = .online
                return nil
            }
            states[key] = .offlineAvailable
            return data
        } catch {
            removeFile(at: url)
            states[key] = .online
            return nil
        }
    }

    /// Reads only the leading bytes of a complete cached entry. Unlike `data`,
    /// a file larger than the prefix budget remains a valid cache entry.
    func prefixData(
        for key: ResourceCacheKey,
        expectedByteCount: Int64,
        maximumBytes: Int64
    ) throws -> Data? {
        guard expectedByteCount >= 0,
              maximumBytes > 0,
              let readLimit = Int(exactly: maximumBytes) else {
            throw ResourceSourceError.invalidReference
        }

        let url = fileURL(for: key)
        let digest = digest(for: key)
        guard manifest[digest]?.identityKey == key.identity.identityKey,
              fileManager.fileExists(atPath: url.path) else {
            removeFile(at: url)
            states[key] = .online
            return nil
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value == expectedByteCount else {
            removeFile(at: url)
            manifest.removeValue(forKey: digest)
            try? persistManifest()
            states[key] = .online
            return nil
        }

        guard expectedByteCount > 0 else {
            states[key] = .offlineAvailable
            return Data()
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let expectedPrefixCount = Int(min(expectedByteCount, maximumBytes))
            var data = Data()
            data.reserveCapacity(expectedPrefixCount)
            while data.count < expectedPrefixCount {
                let remaining = min(readLimit, expectedPrefixCount - data.count)
                let chunk = try handle.read(upToCount: remaining) ?? Data()
                guard !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count == expectedPrefixCount else {
                throw ResourceSourceError.invalidResponse
            }
            states[key] = .offlineAvailable
            return data
        } catch {
            removeFile(at: url)
            manifest.removeValue(forKey: digest)
            try? persistManifest()
            states[key] = .online
            return nil
        }
    }

    /// Atomically stores a bounded content entry. Unknown revisions cannot
    /// reach this method because `ResourceCacheKey` is failable to construct.
    @discardableResult
    func store(
        _ data: Data,
        for key: ResourceCacheKey,
        maximumBytes: Int64
    ) throws -> Bool {
        guard maximumBytes > 0 else {
            throw ResourceSourceError.invalidReference
        }
        guard Int64(data.count) <= maximumBytes else {
            throw ResourceSourceError.responseTooLarge
        }

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let digest = digest(for: key)
        let url = fileURL(for: key)
        try data.write(to: url, options: [.atomic])
        manifest[digest] = ManifestEntry(identityKey: key.identity.identityKey)
        do {
            try persistManifest()
        } catch {
            manifest.removeValue(forKey: digest)
            removeFile(at: url)
            throw error
        }
        states[key] = .offlineAvailable
        return true
    }

    /// Removes one persisted entry and its in-memory state.
    func removeData(for key: ResourceCacheKey) {
        let digest = digest(for: key)
        removeFile(at: fileURL(for: key))
        manifest.removeValue(forKey: digest)
        try? persistManifest()
        states.removeValue(forKey: key)
    }

    /// Removes entries whose source is no longer registered. The manifest is
    /// deliberately identity-only so this cleanup never needs URL or headers.
    func retain(sourceIDs: Set<UUID>) {
        let removedDigests = manifest.compactMap { digest, entry -> String? in
            guard let identity = ResourceIdentity(identityKey: entry.identityKey) else {
                return digest
            }
            return sourceIDs.contains(identity.sourceID) ? nil : digest
        }
        guard !removedDigests.isEmpty else {
            states = states.filter { sourceIDs.contains($0.key.identity.sourceID) }
            return
        }
        for digest in removedDigests {
            removeFile(at: rootURL.appendingPathComponent(digest + ".bin"))
            manifest.removeValue(forKey: digest)
        }
        try? persistManifest()
        states = states.filter { sourceIDs.contains($0.key.identity.sourceID) }
    }

    /// Invalidates all cached representations for one source while preserving
    /// cache entries owned by other sources.
    func remove(sourceID: UUID) {
        let removedDigests = manifest.compactMap { digest, entry -> String? in
            guard let identity = ResourceIdentity(identityKey: entry.identityKey) else {
                return digest
            }
            return identity.sourceID == sourceID ? digest : nil
        }
        for digest in removedDigests {
            removeFile(at: rootURL.appendingPathComponent(digest + ".bin"))
            manifest.removeValue(forKey: digest)
        }
        if !removedDigests.isEmpty {
            try? persistManifest()
        }
        states = states.filter { $0.key.identity.sourceID != sourceID }
    }

    /// Returns the bytes currently occupied by managed cache files.
    func storedByteCount() -> Int64 {
        manifest.keys.reduce(into: Int64(0)) { total, digest in
            let url = rootURL.appendingPathComponent(digest + ".bin")
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value >= 0 else {
                return
            }
            let (value, overflow) = total.addingReportingOverflow(size.int64Value)
            total = overflow ? Int64.max : value
        }
    }

    /// Clears persisted content and state for the coordinator's namespace.
    func removeAll() {
        try? fileManager.removeItem(at: rootURL)
        manifest.removeAll()
        states.removeAll()
    }

    private func fileURL(for key: ResourceCacheKey) -> URL {
        rootURL.appendingPathComponent(digest(for: key) + ".bin", isDirectory: false)
    }

    private func digest(for key: ResourceCacheKey) -> String {
        let digest = SHA256.hash(data: Data(key.persistenceToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func persistManifest() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }

    private static func loadManifest(at url: URL) -> [String: ManifestEntry] {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(
                  [String: ManifestEntry].self,
                  from: data
              ) else {
            return [:]
        }
        return manifest
    }

    private func removeFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}

private extension ResourceRevision {
    var persistenceToken: String {
        switch self {
        case .etag(let value):
            "etag:\(value)"
        case .serverVersion(let value):
            "server:\(value)"
        case .modifiedAndSize(let modifiedAt, let byteSize):
            "modified:\(modifiedAt.timeIntervalSince1970):\(byteSize)"
        case .unknown:
            "unknown"
        }
    }
}

private extension ResourceCacheVariant {
    var persistenceToken: String {
        switch self {
        case .content:
            "content"
        case .preview:
            "preview"
        case .thumbnail:
            "thumbnail"
        case .byteRange(let range):
            "range:\(range.lowerBound):\(range.upperBound)"
        }
    }
}
