import Foundation
import SwiftData
import Testing

@testable import iosRemoteFolder

@Suite("已浏览资源索引")
struct ResourceIndexStoreTests {
    @Test("跨来源和目录搜索保留 typed metadata 并支持筛选")
    func searchesAcrossSourcesAndDirectories() async throws {
        let store = ResourceIndexStore(
            modelContainer: SourceConfigurationPersistence.makeInMemoryContainer()
        )
        let firstSourceID = UUID()
        let secondSourceID = UUID()
        let documentsPath = try #require(ResourcePath(rawValue: "/资料"))
        let folder = try makeItem(
            sourceID: firstSourceID,
            path: "/资料",
            kind: .folder,
            metadata: ResourceMetadata(isDirectory: true),
            capabilities: [.list]
        )
        let manualMetadata = ResourceMetadata(
            byteSize: 4_096,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            mimeType: "application/pdf",
            typeIdentifier: "com.adobe.pdf",
            acceptsRanges: true,
            revision: .etag("\"manual-v2\"")
        )
        let manual = try makeItem(
            sourceID: firstSourceID,
            path: "/资料/Manual.pdf",
            kind: .pdf,
            metadata: manualMetadata,
            capabilities: [.read, .rangeRead, .download],
            accent: .orange
        )
        let notes = try makeItem(
            sourceID: firstSourceID,
            path: "/资料/发布说明.md",
            kind: .markdown,
            metadata: ResourceMetadata(
                byteSize: 512,
                mimeType: "text/markdown",
                revision: .serverVersion("release-3")
            ),
            capabilities: [.read]
        )
        let otherManual = try makeItem(
            sourceID: secondSourceID,
            path: "/archive/manual-copy.txt",
            kind: .text,
            metadata: ResourceMetadata(
                byteSize: 128,
                modifiedAt: Date(timeIntervalSince1970: 1_710_000_000),
                revision: .modifiedAndSize(
                    modifiedAt: Date(timeIntervalSince1970: 1_710_000_000),
                    byteSize: 128
                )
            ),
            capabilities: [.read],
            accent: .blue
        )

        try await store.replaceDirectory(
            sourceID: firstSourceID,
            parentPath: .root,
            items: [folder]
        )
        try await store.replaceDirectory(
            sourceID: firstSourceID,
            parentPath: documentsPath,
            items: [manual, notes]
        )
        try await store.replaceDirectory(
            sourceID: secondSourceID,
            parentPath: try #require(ResourcePath(rawValue: "/archive")),
            items: [otherManual]
        )

        let crossSourceMatches = try await store.search("manual")
        #expect(Set(crossSourceMatches.map(\.id)) == Set([manual.id, otherManual.id]))

        let firstSourceMatches = try await store.search("manual", sourceID: firstSourceID)
        #expect(firstSourceMatches == [manual])

        let pdfMatches = try await store.search("资料", kind: .pdf)
        #expect(pdfMatches == [manual])
        #expect(pdfMatches.first?.metadata == manualMetadata)
        #expect(pdfMatches.first?.capabilities == [.read, .rangeRead, .download])
        #expect(pdfMatches.first?.accent == .orange)

        let boundedMatches = try await store.search("manual", limit: 1)
        #expect(boundedMatches.count == 1)
        let emptyMatches = try await store.search("   \n")
        #expect(emptyMatches.isEmpty)
    }

    @Test("刷新只替换目标目录且无效快照不破坏旧索引")
    func refreshesOneDirectoryAtomically() async throws {
        let store = ResourceIndexStore(
            modelContainer: SourceConfigurationPersistence.makeInMemoryContainer()
        )
        let sourceID = UUID()
        let otherDirectory = try #require(ResourcePath(rawValue: "/other"))
        let stale = try makeItem(sourceID: sourceID, path: "/stale.txt")
        let original = try makeItem(sourceID: sourceID, path: "/keep.txt")
        let unrelated = try makeItem(sourceID: sourceID, path: "/other/preserved.txt")

        try await store.replaceDirectory(
            sourceID: sourceID,
            parentPath: .root,
            items: [stale, original]
        )
        try await store.replaceDirectory(
            sourceID: sourceID,
            parentPath: otherDirectory,
            items: [unrelated]
        )

        let updated = try makeItem(
            sourceID: sourceID,
            path: "/keep.txt",
            metadata: ResourceMetadata(byteSize: 99, revision: .etag("\"new\""))
        )
        let added = try makeItem(sourceID: sourceID, path: "/added.txt")
        try await store.replaceDirectory(
            sourceID: sourceID,
            parentPath: .root,
            items: [updated, added]
        )

        let staleMatches = try await store.search("stale")
        #expect(staleMatches.isEmpty)
        let updatedMatches = try await store.search("keep.txt")
        #expect(updatedMatches == [updated])
        let unrelatedMatches = try await store.search("preserved")
        #expect(unrelatedMatches == [unrelated])

        let invalidChild = try makeItem(
            sourceID: sourceID,
            path: "/nested/not-a-root-child.txt"
        )
        do {
            try await store.replaceDirectory(
                sourceID: sourceID,
                parentPath: .root,
                items: [invalidChild]
            )
            Issue.record("非直接子项快照应被拒绝")
        } catch let error as ResourceIndexError {
            #expect(error == .invalidSnapshot)
        }

        let countAfterInvalidSnapshot = try await store.indexedResourceCount(sourceID: sourceID)
        #expect(countAfterInvalidSnapshot == 3)
        let itemsAfterInvalidSnapshot = try await store.search("keep.txt")
        let unrelatedAfterInvalidSnapshot = try await store.search("preserved")
        #expect(itemsAfterInvalidSnapshot == [updated])
        #expect(unrelatedAfterInvalidSnapshot == [unrelated])

        let invalidRevision = try makeItem(
            sourceID: sourceID,
            path: "/invalid-revision.txt",
            metadata: ResourceMetadata(revision: .etag("  "))
        )
        do {
            try await store.replaceDirectory(
                sourceID: sourceID,
                parentPath: .root,
                items: [invalidRevision]
            )
            Issue.record("空白 revision 的快照应被拒绝")
        } catch let error as ResourceIndexError {
            #expect(error == .invalidSnapshot)
        }
    }

    @Test("文件型容器重开后恢复目录索引")
    func fileBackedStoreRestoresIndexAfterReopen() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-resource-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try FileManager.default.removeItem(at: temporaryDirectory)
            } catch {
                Issue.record("无法清理临时索引 store：\(error.localizedDescription)")
            }
        }

        let storeURL = temporaryDirectory.appendingPathComponent("SourceConfigurations.store")
        let sourceID = UUID()
        let item = try makeItem(
            sourceID: sourceID,
            path: "/library/跨重启.pdf",
            kind: .pdf,
            metadata: ResourceMetadata(
                byteSize: 2_048,
                modifiedAt: Date(timeIntervalSince1970: 1_720_000_000),
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf",
                acceptsRanges: true,
                revision: .etag("\"persistent\"")
            ),
            capabilities: [.read, .rangeRead, .download],
            accent: .orange
        )

        try await withPersistentIndex(at: storeURL) { store in
            try await store.replaceDirectory(
                sourceID: sourceID,
                parentPath: try #require(ResourcePath(rawValue: "/library")),
                items: [item]
            )
        }
        try await withPersistentIndex(at: storeURL) { store in
            let restored = try await store.search("跨重启")
            #expect(restored == [item])
            let restoredCount = try await store.indexedResourceCount(sourceID: sourceID)
            #expect(restoredCount == 1)
        }
    }

    @Test("来源删除与 retain 清理互不相关的索引")
    func removesAndRetainsSources() async throws {
        let store = ResourceIndexStore(
            modelContainer: SourceConfigurationPersistence.makeInMemoryContainer()
        )
        let firstSourceID = UUID()
        let secondSourceID = UUID()
        let thirdSourceID = UUID()

        for (sourceID, name) in [
            (firstSourceID, "first.txt"),
            (secondSourceID, "second.txt"),
            (thirdSourceID, "third.txt"),
        ] {
            try await store.replaceDirectory(
                sourceID: sourceID,
                parentPath: .root,
                items: [try makeItem(sourceID: sourceID, path: "/\(name)")]
            )
        }

        try await store.remove(sourceID: firstSourceID)
        let removedCount = try await store.indexedResourceCount(sourceID: firstSourceID)
        let countAfterRemove = try await store.indexedResourceCount()
        #expect(removedCount == 0)
        #expect(countAfterRemove == 2)

        try await store.retain(sourceIDs: [secondSourceID])
        let countAfterRetain = try await store.indexedResourceCount()
        let retainedMatches = try await store.search("second")
        let removedMatches = try await store.search("third")
        #expect(countAfterRetain == 1)
        #expect(retainedMatches.first?.sourceID == secondSourceID)
        #expect(removedMatches.isEmpty)
    }

    @Test("旧两表 SwiftData store 可升级并新增索引记录")
    func existingConfigurationStoreMigratesToIndexSchema() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-index-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try FileManager.default.removeItem(at: temporaryDirectory)
            } catch {
                Issue.record("无法清理临时迁移 store：\(error.localizedDescription)")
            }
        }

        let storeURL = temporaryDirectory.appendingPathComponent("SourceConfigurations.store")
        let localID = UUID()
        let remoteID = UUID()
        try writeLegacyConfigurationStore(
            at: storeURL,
            localID: localID,
            remoteID: remoteID
        )

        let container = try SourceConfigurationPersistence.makePersistentContainer(at: storeURL)
        let context = ModelContext(container)
        let localRecords = try context.fetch(FetchDescriptor<LocalSourceConfigurationRecord>())
        let remoteRecords = try context.fetch(FetchDescriptor<RemoteSourceConfigurationRecord>())
        #expect(localRecords.map(\.id) == [localID])
        #expect(remoteRecords.map(\.id) == [remoteID])

        let indexStore = ResourceIndexStore(modelContainer: container)
        let item = try makeItem(sourceID: remoteID, path: "/migrated.txt")
        try await indexStore.replaceDirectory(
            sourceID: remoteID,
            parentPath: .root,
            items: [item]
        )
        let migratedMatches = try await indexStore.search("migrated")
        #expect(migratedMatches == [item])
    }

    private func makeItem(
        sourceID: UUID,
        path: String,
        kind: ResourceKind = .text,
        metadata: ResourceMetadata = ResourceMetadata(),
        capabilities: ResourceCapability = [.read],
        accent: ResourceAccent = .teal
    ) throws -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: try #require(ResourcePath(rawValue: path)),
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: metadata,
            capabilities: capabilities,
            accent: accent
        )
    }

    private func withPersistentIndex<T>(
        at storeURL: URL,
        _ body: (ResourceIndexStore) async throws -> T
    ) async throws -> T {
        let container = try SourceConfigurationPersistence.makePersistentContainer(at: storeURL)
        let store = ResourceIndexStore(modelContainer: container)
        return try await body(store)
    }

    private func writeLegacyConfigurationStore(
        at storeURL: URL,
        localID: UUID,
        remoteID: UUID
    ) throws {
        let schema = Schema([
            LocalSourceConfigurationRecord.self,
            RemoteSourceConfigurationRecord.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(
            LocalSourceConfigurationRecord(
                id: localID,
                displayName: "旧本地来源",
                endpointDescription: "Files 文件夹",
                bookmarkData: Data([0x01, 0x02])
            )
        )
        context.insert(
            RemoteSourceConfigurationRecord(
                id: remoteID,
                displayName: "旧远端来源",
                endpoint: "https://example.com/dav/",
                kindRawValue: ResourceSource.SourceKind.webdav.rawValue,
                credentialReference: nil
            )
        )
        try context.save()
    }
}
