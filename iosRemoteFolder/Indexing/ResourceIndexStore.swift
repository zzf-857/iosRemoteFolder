import Foundation
import SwiftData

enum ResourceIndexError: LocalizedError, Hashable, Sendable {
    case invalidSnapshot
    case invalidStoredData
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            "目录索引包含无效资源"
        case .invalidStoredData:
            "本地资源索引已损坏"
        case .persistenceFailed:
            "无法更新本地资源索引"
        }
    }
}

/// Persistent, metadata-only index for directories the user has browsed.
///
/// A snapshot contains direct children only. The store never walks a source,
/// resolves a bookmark, performs network work, or persists an endpoint or
/// credential. Refreshing one directory therefore has a bounded write scope.
actor ResourceIndexStore {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = false
    }

    /// Atomically replaces the direct children recorded for one directory.
    func replaceDirectory(
        sourceID: UUID,
        parentPath: ResourcePath,
        items: [ResourceItem]
    ) throws {
        var indexedItems: [String: ResourceItem] = [:]
        indexedItems.reserveCapacity(items.count)
        for item in items {
            guard Self.isValid(item, sourceID: sourceID, parentPath: parentPath),
                  indexedItems.updateValue(item, forKey: item.id.identityKey) == nil else {
                throw ResourceIndexError.invalidSnapshot
            }
        }

        let records = try fetchRecords()
        let directoryRecords = records.filter {
            $0.sourceID == sourceID && $0.parentPath == parentPath.normalized
        }
        var existingByIdentity = Dictionary(
            uniqueKeysWithValues: directoryRecords.map { ($0.identityKey, $0) }
        )

        for record in directoryRecords where indexedItems[record.identityKey] == nil {
            modelContext.delete(record)
        }

        let indexedAt = Date()
        for (identityKey, item) in indexedItems {
            if let record = existingByIdentity.removeValue(forKey: identityKey) {
                record.update(from: item, parentPath: parentPath, indexedAt: indexedAt)
            } else {
                modelContext.insert(
                    ResourceIndexRecord(
                        item: item,
                        parentPath: parentPath,
                        indexedAt: indexedAt
                    )
                )
            }
        }

        try saveOrRollback()
    }

    /// Searches resource names and canonical logical paths. An empty query is
    /// deliberately not an all-items query, keeping the UI and fetch bounded.
    func search(
        _ query: String,
        kind: ResourceKind? = nil,
        sourceID: UUID? = nil,
        limit: Int = 200
    ) throws -> [ResourceItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let boundedLimit = min(max(limit, 1), 500)

        return try fetchRecords()
            .lazy
            .filter { sourceID == nil || $0.sourceID == sourceID }
            .compactMap { $0.resourceItem }
            .filter { item in
                (kind == nil || item.kind == kind)
                    && (item.name.localizedStandardContains(term)
                        || item.path.localizedStandardContains(term))
            }
            .sorted { lhs, rhs in
                let lhsRank = Self.searchRank(lhs, term: term)
                let rhsRank = Self.searchRank(rhs, term: term)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            .prefix(boundedLimit)
            .map { $0 }
    }

    func indexedResourceCount(sourceID: UUID? = nil) throws -> Int {
        try fetchRecords().reduce(into: 0) { count, record in
            guard (sourceID == nil || record.sourceID == sourceID),
                  record.resourceItem != nil else {
                return
            }
            count += 1
        }
    }

    func remove(sourceID: UUID) throws {
        let records = try fetchRecords().filter { $0.sourceID == sourceID }
        guard !records.isEmpty else { return }
        records.forEach(modelContext.delete)
        try saveOrRollback()
    }

    func retain(sourceIDs: Set<UUID>) throws {
        let records = try fetchRecords().filter { !sourceIDs.contains($0.sourceID) }
        guard !records.isEmpty else { return }
        records.forEach(modelContext.delete)
        try saveOrRollback()
    }

    private func fetchRecords() throws -> [ResourceIndexRecord] {
        do {
            return try modelContext.fetch(FetchDescriptor<ResourceIndexRecord>())
        } catch {
            throw ResourceIndexError.persistenceFailed
        }
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw ResourceIndexError.persistenceFailed
        }
    }

    private static func isValid(
        _ item: ResourceItem,
        sourceID: UUID,
        parentPath: ResourcePath
    ) -> Bool {
        guard item.sourceID == sourceID,
              item.id.sourceID == sourceID,
              item.id.logicalPath == item.path,
              let itemPath = ResourcePath(rawValue: item.path),
              itemPath.normalized == item.path,
              itemPath.parent == parentPath,
              !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.metadata.byteSize.map({ $0 >= 0 }) ?? true,
              item.metadata.modifiedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              (item.kind == .folder) == item.metadata.isDirectory,
              Self.isValid(item.metadata.revision) else {
            return false
        }
        return true
    }

    private static func isValid(_ revision: ResourceRevision) -> Bool {
        switch revision {
        case .unknown:
            return true
        case .etag(let value), .serverVersion(let value):
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .modifiedAndSize(let modifiedAt, let byteSize):
            return modifiedAt.timeIntervalSinceReferenceDate.isFinite && byteSize >= 0
        }
    }

    private static func searchRank(_ item: ResourceItem, term: String) -> Int {
        if item.name.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return 0
        }
        if item.name.range(
            of: term,
            options: [.anchored, .caseInsensitive, .diacriticInsensitive]
        ) != nil {
            return 1
        }
        return item.name.localizedStandardContains(term) ? 2 : 3
    }
}

@Model
final class ResourceIndexRecord {
    @Attribute(.unique) var identityKey: String
    var sourceID: UUID
    var parentPath: String
    var logicalPath: String
    var name: String
    var kindRawValue: String
    var byteSize: Int64?
    var modifiedAt: Date?
    var mimeType: String?
    var typeIdentifier: String?
    var isDirectory: Bool
    var acceptsRanges: Bool
    var revisionKind: String
    var revisionValue: String?
    var revisionModifiedAt: Date?
    var revisionByteSize: Int64?
    var capabilityRawValue: Int
    var accentRawValue: String
    var indexedAt: Date

    init(item: ResourceItem, parentPath: ResourcePath, indexedAt: Date) {
        identityKey = item.id.identityKey
        sourceID = item.sourceID
        self.parentPath = parentPath.normalized
        logicalPath = item.path
        name = item.name
        kindRawValue = item.kind.rawValue
        byteSize = item.metadata.byteSize
        modifiedAt = item.metadata.modifiedAt
        mimeType = item.metadata.mimeType
        typeIdentifier = item.metadata.typeIdentifier
        isDirectory = item.metadata.isDirectory
        acceptsRanges = item.metadata.acceptsRanges
        let revision = Self.storedRevision(item.metadata.revision)
        revisionKind = revision.kind
        revisionValue = revision.value
        revisionModifiedAt = revision.modifiedAt
        revisionByteSize = revision.byteSize
        capabilityRawValue = item.capabilities.rawValue
        accentRawValue = item.accent.rawValue
        self.indexedAt = indexedAt
    }

    func update(from item: ResourceItem, parentPath: ResourcePath, indexedAt: Date) {
        identityKey = item.id.identityKey
        sourceID = item.sourceID
        self.parentPath = parentPath.normalized
        logicalPath = item.path
        name = item.name
        kindRawValue = item.kind.rawValue
        byteSize = item.metadata.byteSize
        modifiedAt = item.metadata.modifiedAt
        mimeType = item.metadata.mimeType
        typeIdentifier = item.metadata.typeIdentifier
        isDirectory = item.metadata.isDirectory
        acceptsRanges = item.metadata.acceptsRanges
        let revision = Self.storedRevision(item.metadata.revision)
        revisionKind = revision.kind
        revisionValue = revision.value
        revisionModifiedAt = revision.modifiedAt
        revisionByteSize = revision.byteSize
        capabilityRawValue = item.capabilities.rawValue
        accentRawValue = item.accent.rawValue
        self.indexedAt = indexedAt
    }

    var resourceItem: ResourceItem? {
        guard let path = ResourcePath(rawValue: logicalPath),
              path.normalized == logicalPath,
              path.parent?.normalized == parentPath,
              let identity = ResourceIdentity(identityKey: identityKey),
              identity.sourceID == sourceID,
              identity.logicalPath == logicalPath,
              let kind = ResourceKind(rawValue: kindRawValue),
              let accent = ResourceAccent(rawValue: accentRawValue),
              capabilityRawValue >= 0,
              byteSize.map({ $0 >= 0 }) ?? true,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let revision = restoredRevision else {
            return nil
        }

        return ResourceItem(
            sourceID: sourceID,
            logicalPath: path,
            name: name,
            kind: kind,
            metadata: ResourceMetadata(
                byteSize: byteSize,
                modifiedAt: modifiedAt,
                mimeType: mimeType,
                typeIdentifier: typeIdentifier,
                isDirectory: isDirectory,
                acceptsRanges: acceptsRanges,
                revision: revision
            ),
            capabilities: ResourceCapability(rawValue: capabilityRawValue),
            accent: accent
        )
    }

    private var restoredRevision: ResourceRevision? {
        switch revisionKind {
        case "unknown":
            guard revisionValue == nil,
                  revisionModifiedAt == nil,
                  revisionByteSize == nil else {
                return nil
            }
            return .unknown
        case "etag":
            guard let revisionValue,
                  !revisionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  revisionModifiedAt == nil,
                  revisionByteSize == nil else {
                return nil
            }
            return .etag(revisionValue)
        case "serverVersion":
            guard let revisionValue,
                  !revisionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  revisionModifiedAt == nil,
                  revisionByteSize == nil else {
                return nil
            }
            return .serverVersion(revisionValue)
        case "modifiedAndSize":
            guard revisionValue == nil,
                  let revisionModifiedAt,
                  let revisionByteSize,
                  revisionByteSize >= 0 else {
                return nil
            }
            return .modifiedAndSize(
                modifiedAt: revisionModifiedAt,
                byteSize: revisionByteSize
            )
        default:
            return nil
        }
    }

    private static func storedRevision(
        _ revision: ResourceRevision
    ) -> (kind: String, value: String?, modifiedAt: Date?, byteSize: Int64?) {
        switch revision {
        case .unknown:
            ("unknown", nil, nil, nil)
        case .etag(let value):
            ("etag", value, nil, nil)
        case .serverVersion(let value):
            ("serverVersion", value, nil, nil)
        case .modifiedAndSize(let modifiedAt, let byteSize):
            ("modifiedAndSize", nil, modifiedAt, byteSize)
        }
    }
}
