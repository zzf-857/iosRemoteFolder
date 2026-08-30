import Foundation
import QuickLook
import Testing
import UniformTypeIdentifiers
@testable import iosRemoteFolder

@Suite("系统文件回退物化")
struct ResourceFileMaterializerTests {
    @Test("超预算在写入前拒绝，零字节边界可物化")
    func enforcesLimitBeforeAnyWriteAndSupportsZeroBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = LockedWriteCount()
        let materializer = ResourceFileMaterializer(
            rootDirectory: root,
            dataWriter: { data, destination in
                writes.increment()
                try data.write(to: destination, options: .atomic)
            }
        )

        await #expect(throws: ResourceSourceError.responseTooLarge) {
            try await materializer.materialize(
                data: Data([0, 1, 2, 3]),
                knownByteCount: 4,
                suggestedFilename: "oversized.pages",
                maximumBytes: 3
            )
        }
        #expect(writes.value == 0)
        #expect(try directoryContents(at: root).isEmpty)

        let emptyLease = try await materializer.materialize(
            data: Data(),
            knownByteCount: 0,
            suggestedFilename: "empty.txt",
            maximumBytes: 0
        )
        #expect(writes.value == 1)
        #expect(emptyLease.byteCount == 0)
        #expect(
            try Data(contentsOf: emptyLease.fileURL).isEmpty
        )
        emptyLease.close()
    }

    @Test("文件名清洗阻止路径逃逸并保留类型扩展名")
    func sanitizesFilenameAndPreservesExtension() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = ResourceFileMaterializer(rootDirectory: root)
        let data = Data("document".utf8)
        let lease = try await materializer.materialize(
            data: data,
            knownByteCount: Int64(data.count),
            suggestedFilename: "..\\..\\季度:\u{202E}\n报告.PAGES",
            maximumBytes: 1_024
        )
        defer { lease.close() }

        #expect(lease.displayName.hasSuffix(".PAGES"))
        #expect(!lease.displayName.contains("/"))
        #expect(!lease.displayName.contains("\\"))
        #expect(!lease.displayName.contains(":"))
        #expect(!lease.displayName.contains("\n"))
        #expect(!lease.displayName.contains("\u{202E}"))
        #expect(lease.displayName.utf8.count <= 128)
        #expect(lease.byteCount == Int64(data.count))
        #expect(lease.fileURL.lastPathComponent == lease.displayName)
        #expect(
            lease.fileURL.deletingLastPathComponent().deletingLastPathComponent()
                .standardizedFileURL == root.standardizedFileURL
        )
        #expect(try Data(contentsOf: lease.fileURL) == data)
        #expect(ResourceFileMaterializer.safeFilename(for: "../..") == "resource")
        #expect(ResourceFileMaterializer.safeFilename(for: "report.p$d$f") == "report")
    }

    @Test("可信 canonical UTI 为无扩展名文件补全系统可识别后缀")
    func canonicalTypeAddsPreferredExtension() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentType = try #require(UTType(filenameExtension: "docx"))
        let resolvedType = ResolvedContentType(
            kind: .unknown,
            evidence: [ResolvedContentType.Evidence(
                source: .mimeType,
                rawValue: documentType.preferredMIMEType ?? "application/vnd.openxmlformats",
                kind: .unknown,
                strength: .typed,
                canonicalTypeIdentifier: documentType.identifier
            )],
            confidence: .high,
            diagnostics: []
        )
        let data = Data("office".utf8)
        let lease = try await ResourceFileMaterializer(rootDirectory: root).materialize(
            data: data,
            knownByteCount: Int64(data.count),
            suggestedFilename: "季度报告",
            suggestedTypeIdentifier: documentType.identifier,
            maximumBytes: Int64(data.count)
        )
        defer { lease.close() }

        #expect(resolvedType.preferredSystemTypeIdentifier == documentType.identifier)
        #expect(lease.displayName == "季度报告.docx")
        #expect(lease.fileURL.pathExtension == "docx")
        #expect(lease.typeIdentifier == documentType.identifier)
        #expect(
            ResourceFileMaterializer.safeFilename(
                for: "已有.PAGES",
                suggestedTypeIdentifier: documentType.identifier
            ) == "已有.PAGES"
        )
    }

    @Test("并发同名物化使用不同 UUID 目录")
    func concurrentMaterializationsAreIsolated() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = ResourceFileMaterializer(rootDirectory: root)

        let leases = try await withThrowingTaskGroup(
            of: MaterializedResourceFileLease.self,
            returning: [MaterializedResourceFileLease].self
        ) { group in
            for index in 0..<12 {
                group.addTask {
                    let data = Data("payload-\(index)".utf8)
                    return try await materializer.materialize(
                        data: data,
                        knownByteCount: Int64(data.count),
                        suggestedFilename: "shared.docx",
                        maximumBytes: 1_024
                    )
                }
            }

            var values: [MaterializedResourceFileLease] = []
            for try await lease in group {
                values.append(lease)
            }
            return values
        }
        defer { leases.forEach { $0.close() } }

        let directories = Set(
            leases.map { $0.fileURL.deletingLastPathComponent().lastPathComponent }
        )
        #expect(directories.count == leases.count)
        #expect(leases.allSatisfy { $0.fileURL.lastPathComponent == "shared.docx" })
        #expect(try directoryContents(at: root).count == leases.count)
    }

    @Test("close 幂等且只清理所属目录")
    func closeIsIdempotentAndLeaseScoped() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = ResourceFileMaterializer(rootDirectory: root)
        let data = Data("x".utf8)
        let first = try await materializer.materialize(
            data: data,
            knownByteCount: 1,
            suggestedFilename: "first.zip",
            maximumBytes: 1
        )
        let second = try await materializer.materialize(
            data: data,
            knownByteCount: 1,
            suggestedFilename: "second.zip",
            maximumBytes: 1
        )
        defer { second.close() }
        let firstDirectory = first.fileURL.deletingLastPathComponent()
        let secondDirectory = second.fileURL.deletingLastPathComponent()

        first.close()
        first.close()

        #expect(first.isClosed)
        #expect(!FileManager.default.fileExists(atPath: firstDirectory.path))
        #expect(FileManager.default.fileExists(atPath: secondDirectory.path))
        #expect(try Data(contentsOf: second.fileURL) == data)
    }

    @Test("close 请求等待全部 usage token 并拒绝新消费者")
    func closeWaitsForUsageTokensAndRejectsNewConsumers() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try await ResourceFileMaterializer(rootDirectory: root).materialize(
            data: Data("shared".utf8),
            knownByteCount: 6,
            suggestedFilename: "shared.docx",
            maximumBytes: 6
        )
        let firstUsage = try #require(lease.acquireUsage())
        let secondUsage = try #require(lease.acquireUsage())

        lease.close()

        #expect(lease.isCloseRequested)
        #expect(!lease.isClosed)
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))
        #expect(lease.acquireUsage() == nil)

        firstUsage.release()
        firstUsage.release()
        lease.close()
        #expect(!lease.isClosed)
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))

        secondUsage.release()
        #expect(lease.isClosed)
        #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
    }

    @Test("usage token 析构会完成延迟清理")
    func usageTokenDeinitCompletesDeferredCleanup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try await ResourceFileMaterializer(rootDirectory: root).materialize(
            data: Data("deinit-token".utf8),
            knownByteCount: 12,
            suggestedFilename: "token.pages",
            maximumBytes: 12
        )
        var usageToken = lease.acquireUsage()
        #expect(usageToken != nil)

        lease.close()
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))

        usageToken = nil
        #expect(usageToken == nil)
        #expect(lease.isClosed)
        #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
    }

    @Test("系统消费者在各自结束前共同保持临时文件")
    @MainActor
    func systemConsumerCoordinatorsHoldUsageUntilFinished() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try await ResourceFileMaterializer(rootDirectory: root).materialize(
            data: Data("consumer".utf8),
            knownByteCount: 8,
            suggestedFilename: "consumer.xlsx",
            maximumBytes: 8
        )
        let quickLook = QuickLookPreviewDataSource(lease: lease, title: "预览")
        let activity = ActivityView.Coordinator(lease: lease)
        let openIn = OpenInView.Coordinator(lease: lease, title: "打开", onDismiss: {})

        lease.close()
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))

        quickLook.finish()
        activity.finish()
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))

        openIn.dismiss(animated: false, notify: false)
        openIn.dismiss(animated: false, notify: false)
        #expect(lease.isClosed)
        #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
    }

    @Test("关闭 lease 的系统消费者显式不可用且不会沿用旧 URL")
    @MainActor
    func closedLeaseConsumersBecomeUnavailableWithoutCrashing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = ResourceFileMaterializer(rootDirectory: root)
        let oldLease = try await materializer.materialize(
            data: Data("old".utf8),
            knownByteCount: 3,
            suggestedFilename: "old.pages",
            maximumBytes: 3
        )
        let closedLease = try await materializer.materialize(
            data: Data("closed".utf8),
            knownByteCount: 6,
            suggestedFilename: "closed.pages",
            maximumBytes: 6
        )
        closedLease.close()

        let quickLook = QuickLookPreviewDataSource(lease: oldLease, title: "旧文件")
        oldLease.close()
        #expect(!quickLook.update(lease: closedLease, title: "已关闭文件"))
        #expect(!quickLook.isAvailable)
        #expect(quickLook.numberOfPreviewItems(in: QLPreviewController()) == 0)
        #expect(!oldLease.isClosed)
        quickLook.finish()
        #expect(oldLease.isClosed)

        let closedQuickLook = QuickLookPreviewDataSource(
            lease: closedLease,
            title: "已关闭文件"
        )
        #expect(!closedQuickLook.isAvailable)
        #expect(closedQuickLook.numberOfPreviewItems(in: QLPreviewController()) == 0)

        let activity = ActivityView.Coordinator(lease: closedLease)
        #expect(!activity.isAvailable)
        #expect(activity.fileURL == nil)

        let openIn = OpenInView.Coordinator(
            lease: closedLease,
            title: "已关闭文件",
            onDismiss: {}
        )
        #expect(!openIn.isAvailable)
        #expect(openIn.fileURL == nil)
        #expect(openIn.typeIdentifier == nil)
    }

    @Test("析构、写入失败与预取消都不遗留文件")
    func cleanupFallbacksRemoveOrphans() async throws {
        let deinitRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: deinitRoot) }
        var lease: MaterializedResourceFileLease? = try await ResourceFileMaterializer(
            rootDirectory: deinitRoot
        ).materialize(
            data: Data("deinit".utf8),
            knownByteCount: 6,
            suggestedFilename: "lease.key",
            maximumBytes: 6
        )
        weak var weakLease: MaterializedResourceFileLease?
        weakLease = lease
        let leasedDirectory = try #require(lease?.fileURL.deletingLastPathComponent())
        lease = nil
        #expect(weakLease == nil)
        #expect(!FileManager.default.fileExists(atPath: leasedDirectory.path))

        let failedRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: failedRoot) }
        let failingMaterializer = ResourceFileMaterializer(
            rootDirectory: failedRoot,
            dataWriter: { data, destination in
                try data.prefix(1).write(to: destination)
                throw IntentionalWriteFailure()
            }
        )
        do {
            _ = try await failingMaterializer.materialize(
                data: Data("failure".utf8),
                knownByteCount: 7,
                suggestedFilename: "failed.rtf",
                maximumBytes: 7
            )
            Issue.record("写入失败必须抛错")
        } catch {
            #expect(ResourceSourceError.mapping(error) == .unavailable)
        }
        #expect(try directoryContents(at: failedRoot).isEmpty)

        let cancelledRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: cancelledRoot) }
        let cancelledMaterializer = ResourceFileMaterializer(rootDirectory: cancelledRoot)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelledMaterializer.materialize(
                data: Data("cancelled".utf8),
                knownByteCount: 9,
                suggestedFilename: "cancelled.xlsx",
                maximumBytes: 9
            )
        }
        await #expect(throws: ResourceSourceError.cancelled) {
            try await task.value
        }
        #expect(try directoryContents(at: cancelledRoot).isEmpty)
    }

    @Test("Quick Look datasource 返回真实 URL 与标题")
    @MainActor
    func quickLookDataSourceReturnsFileItem() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = ResourceFileMaterializer(rootDirectory: root)
        let firstLease = try await materializer.materialize(
            data: Data("first".utf8),
            knownByteCount: 5,
            suggestedFilename: "first.docx",
            maximumBytes: 6
        )
        let secondLease = try await materializer.materialize(
            data: Data("second".utf8),
            knownByteCount: 6,
            suggestedFilename: "second.pages",
            maximumBytes: 6
        )
        let dataSource = QuickLookPreviewDataSource(
            lease: firstLease,
            title: "第一份文档"
        )
        let controller = QLPreviewController()

        #expect(dataSource.numberOfPreviewItems(in: controller) == 1)
        var item = dataSource.previewController(controller, previewItemAt: 0)
        #expect(item.previewItemURL == firstLease.fileURL)
        #expect(item.previewItemTitle == "第一份文档")

        firstLease.close()
        #expect(FileManager.default.fileExists(atPath: firstLease.fileURL.path))

        dataSource.update(lease: secondLease, title: "第二份文档")
        item = dataSource.previewController(controller, previewItemAt: 0)
        #expect(item.previewItemURL == secondLease.fileURL)
        #expect(item.previewItemTitle == "第二份文档")
        #expect(!firstLease.isClosed)
        #expect(FileManager.default.fileExists(atPath: firstLease.fileURL.path))

        secondLease.close()
        #expect(FileManager.default.fileExists(atPath: secondLease.fileURL.path))
        dataSource.finish()
        #expect(firstLease.isClosed)
        #expect(secondLease.isClosed)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "iosRemoteFolder-materializer-tests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func directoryContents(at root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
    }
}

private struct IntentionalWriteFailure: Error {}

private final class LockedWriteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
