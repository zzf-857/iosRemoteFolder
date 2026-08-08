import Foundation
import Darwin
import Testing

@testable import iosRemoteFolder

@Suite("本地文件来源适配器")
final class LocalFilesSourceAdapterTests {
    private let rootURL: URL
    private let adapter: LocalFilesSourceAdapter
    private let sourceID = UUID()

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LocalFilesAdapterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rootURL = root
        let source = ResourceSource(
            id: sourceID,
            name: "测试本地来源",
            kind: .local,
            endpoint: root.path,
            status: .disconnected,
            itemCountDescription: ""
        )
        adapter = LocalFilesSourceAdapter(source: source, rootURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: - 连接

    @Test("根目录可读时连接成功")
    func connectSucceeds() async throws {
        try await adapter.connect()
    }

    @Test("根目录不存在时映射为 notFound")
    func connectFailsWhenRootMissing() async {
        let missing = rootURL.appending(path: "missing-root")
        let source = ResourceSource(
            id: UUID(), name: "缺失根目录", kind: .local,
            endpoint: missing.path, status: .disconnected, itemCountDescription: ""
        )
        let broken = LocalFilesSourceAdapter(source: source, rootURL: missing)
        await #expect(throws: ResourceSourceError.notFound) {
            try await broken.connect()
        }
    }

    @Test("根目录指向普通文件时映射为 invalidReference")
    func connectFailsWhenRootIsFile() async throws {
        let fileURL = rootURL.appending(path: "not-a-directory.txt")
        try Data("x".utf8).write(to: fileURL)
        let source = ResourceSource(
            id: UUID(), name: "文件根", kind: .local,
            endpoint: fileURL.path, status: .disconnected, itemCountDescription: ""
        )
        let broken = LocalFilesSourceAdapter(source: source, rootURL: fileURL)
        await #expect(throws: ResourceSourceError.invalidReference) {
            try await broken.connect()
        }
    }

    @Test("根目录不可读时映射为 permissionDenied")
    func connectFailsWithoutPermission() async throws {
        let denied = rootURL.appending(path: "denied-root")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path) }

        let source = ResourceSource(
            id: UUID(), name: "无权限根", kind: .local,
            endpoint: denied.path, status: .disconnected, itemCountDescription: ""
        )
        let broken = LocalFilesSourceAdapter(source: source, rootURL: denied)
        await #expect(throws: ResourceSourceError.permissionDenied) {
            try await broken.connect()
        }
    }

    // MARK: - 列举

    @Test("列举返回目录内容、类型与能力")
    func listingReflectsDirectory() async throws {
        try Data("# 笔记".utf8).write(to: rootURL.appending(path: "a-notes.md"))
        try Data("说明".utf8).write(to: rootURL.appending(path: "c-readme.txt"))
        try FileManager.default.createDirectory(
            at: rootURL.appending(path: "b-folder"),
            withIntermediateDirectories: true
        )

        let items = try await adapter.listResources()
        #expect(items.map(\.name) == ["b-folder", "a-notes.md", "c-readme.txt"])
        #expect(items.map(\.kind) == [.folder, .markdown, .text])
        #expect(items.allSatisfy { $0.sourceID == sourceID })
        #expect(items.allSatisfy { !$0.path.hasPrefix("//") })

        let folder = try #require(items.first { $0.kind == .folder })
        #expect(folder.capabilities.contains(.list))
        #expect(!folder.capabilities.contains(.read))
        #expect(folder.metadata.isDirectory)
        #expect(folder.metadata.revision.isUnknown)

        let file = try #require(items.first { $0.name == "a-notes.md" })
        #expect(file.capabilities.contains(.read))
        #expect(file.capabilities.contains(.rangeRead))
        #expect(file.capabilities.contains(.download))
        #expect(file.metadata.byteSize == Int64(Data("# 笔记".utf8).count))
        #expect(file.metadata.modifiedAt != nil)
        #expect(file.metadata.acceptsRanges)
        #expect(file.metadata.revision.isKnown)
    }

    @Test("子目录列举返回完整路径和稳定身份")
    func nestedListingUsesStableIdentity() async throws {
        let folderURL = rootURL.appending(path: "资料")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("正文".utf8).write(to: folderURL.appending(path: "说明.txt"))

        let rootItems = try await adapter.listResources()
        let folder = try #require(rootItems.first { $0.path == "/资料" })
        let folderPath = try #require(ResourcePath(rawValue: folder.path))
        let firstListing = try await adapter.listResources(at: folderPath)
        let secondListing = try await adapter.listResources(at: folderPath)
        let file = try #require(firstListing.first)

        #expect(folder.kind == .folder)
        #expect(file.path == "/资料/说明.txt")
        #expect(file.id == secondListing.first?.id)
        #expect(
            file.id == ResourceIdentity(
                sourceID: sourceID,
                logicalPath: ResourcePath(rawValue: "/资料/说明.txt")!
            )
        )
    }

    @Test("空目录列举返回空列表")
    func listingEmptyDirectory() async throws {
        let items = try await adapter.listResources()
        #expect(items.isEmpty)
    }

    @Test("根目录不可读时列举映射为 permissionDenied")
    func listingFailsWithoutPermission() async throws {
        let denied = rootURL.appending(path: "denied-listing")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: denied.appending(path: "inner.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path) }

        let source = ResourceSource(
            id: UUID(), name: "无权限列举", kind: .local,
            endpoint: denied.path, status: .disconnected, itemCountDescription: ""
        )
        let broken = LocalFilesSourceAdapter(source: source, rootURL: denied)
        await #expect(throws: ResourceSourceError.permissionDenied) {
            _ = try await broken.listResources()
        }
    }

    // MARK: - 引用与读取

    @Test("引用指向真实文件并可完整读取")
    func referenceAndRead() async throws {
        let content = "你好，本地资源"
        try Data(content.utf8).write(to: rootURL.appending(path: "hello.txt"))
        let item = makeItem(path: "/hello.txt")

        let reference = try await adapter.reference(for: item)
        guard case .localFile(let value) = reference else {
            Issue.record("应为本地文件引用")
            return
        }
        #expect(value.fileURL.lastPathComponent == "hello.txt")

        let data = try await adapter.readData(for: item, range: nil)
        #expect(String(decoding: data, as: UTF8.self) == content)
    }

    @Test("磁盘目录伪装成文件时三个入口都拒绝")
    func disguisedDirectoryRejectedByAllFileEntrypoints() async throws {
        try FileManager.default.createDirectory(
            at: rootURL.appending(path: "伪装.txt"),
            withIntermediateDirectories: true
        )
        let item = makeItem(path: "/伪装.txt", kind: .text)

        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.reference(for: item)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.fetchMetadata(for: item)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.readData(for: item, range: nil)
        }
    }

    @Test("跨来源文件被三个入口拒绝")
    func foreignSourceRejectedByAllFileEntrypoints() async throws {
        try Data("content".utf8).write(to: rootURL.appending(path: "foreign.txt"))
        let item = makeItem(path: "/foreign.txt", sourceID: UUID())

        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.reference(for: item)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.fetchMetadata(for: item)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.readData(for: item, range: nil)
        }
    }

    @Test("按区间读取返回分片")
    func rangedRead() async throws {
        try Data("0123456789".utf8).write(to: rootURL.appending(path: "digits.txt"))
        let item = makeItem(path: "/digits.txt")
        let data = try await adapter.readData(
            for: item,
            range: ResourceByteRange(lowerBound: 2, upperBound: 5)
        )
        #expect(String(decoding: data, as: UTF8.self) == "2345")
    }

    @Test("超出文件尾部的区间自动收敛")
    func rangedReadClamps() async throws {
        try Data("0123".utf8).write(to: rootURL.appending(path: "short.txt"))
        let item = makeItem(path: "/short.txt")
        let data = try await adapter.readData(
            for: item,
            range: ResourceByteRange(lowerBound: 2, upperBound: 99)
        )
        #expect(String(decoding: data, as: UTF8.self) == "23")
    }

    @Test("文件不存在时三个入口都映射为 notFound")
    func missingFile() async {
        let item = makeItem(path: "/missing.txt")
        await #expect(throws: ResourceSourceError.notFound) {
            _ = try await adapter.reference(for: item)
        }
        await #expect(throws: ResourceSourceError.notFound) {
            _ = try await adapter.fetchMetadata(for: item)
        }
        await #expect(throws: ResourceSourceError.notFound) {
            _ = try await adapter.readData(for: item, range: nil)
        }
    }

    @Test("路径穿越在 ResourcePath 构造边界被拒绝")
    func pathTraversalRejected() {
        #expect(ResourcePath(rawValue: "/../escape.txt") == nil)
        #expect(ResourcePath(rawValue: "/safe/../../escape.txt") == nil)
    }

    @Test("指向根目录外的符号链接被三个入口拒绝")
    func externalSymlinkRejectedByAllFileEntrypoints() async throws {
        let externalRoot = FileManager.default.temporaryDirectory
            .appending(path: "LocalFilesExternal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let externalFile = externalRoot.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: "outside.txt"),
            withDestinationURL: externalFile
        )
        let item = makeItem(path: "/outside.txt")

        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.reference(for: item)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.fetchMetadata(for: item)
        }
        await #expect(throws: ResourceSourceError.invalidReference) {
            _ = try await adapter.readData(for: item, range: nil)
        }
    }

    @Test("无权限文件的三个入口映射为 permissionDenied")
    func unreadableFile() async throws {
        let locked = rootURL.appending(path: "locked.txt")
        try Data("secret".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let listedItem = try #require(try await adapter.listResources().first { $0.name == "locked.txt" })
        #expect(listedItem.kind == .unknown)
        #expect(!listedItem.metadata.acceptsRanges)
        #expect(!listedItem.capabilities.contains(.read))
        #expect(!listedItem.capabilities.contains(.download))
        #expect(!listedItem.capabilities.contains(.rangeRead))

        let item = makeItem(path: "/locked.txt")
        await #expect(throws: ResourceSourceError.permissionDenied) {
            _ = try await adapter.reference(for: item)
        }
        await #expect(throws: ResourceSourceError.permissionDenied) {
            _ = try await adapter.fetchMetadata(for: item)
        }
        await #expect(throws: ResourceSourceError.permissionDenied) {
            _ = try await adapter.readData(for: item, range: nil)
        }
    }

    @Test("非普通文件不声明读取、下载或区间能力")
    func nonRegularFileDoesNotAdvertiseReadCapabilities() async throws {
        let fifo = rootURL.appending(path: "stream.txt")
        let result = fifo.path.withCString { path in
            Darwin.mkfifo(path, mode_t(0o600))
        }
        #expect(result == 0)
        guard result == 0 else { return }

        let item = try #require(try await adapter.listResources().first { $0.name == "stream.txt" })
        #expect(item.kind == .unknown)
        #expect(!item.metadata.isDirectory)
        #expect(!item.metadata.acceptsRanges)
        #expect(item.metadata.revision.isUnknown)
        #expect(!item.capabilities.contains(.read))
        #expect(!item.capabilities.contains(.download))
        #expect(!item.capabilities.contains(.rangeRead))
    }

    @Test("元数据包含大小、修改时间并支持区间读取")
    func metadata() async throws {
        try Data("12345".utf8).write(to: rootURL.appending(path: "meta.txt"))
        let item = makeItem(path: "/meta.txt")
        let metadata = try await adapter.fetchMetadata(for: item)
        #expect(metadata.byteSize == 5)
        #expect(metadata.modifiedAt != nil)
        #expect(metadata.mimeType != nil)
        #expect(metadata.typeIdentifier != nil)
        #expect(!metadata.isDirectory)
        #expect(metadata.acceptsRanges)
        guard case .modifiedAndSize(let modifiedAt, let byteSize) = metadata.revision else {
            Issue.record("本地普通文件应以修改时间与大小形成 revision")
            return
        }
        #expect(modifiedAt == metadata.modifiedAt)
        #expect(byteSize == 5)
    }

    // MARK: - Helpers

    private func makeItem(
        path: String,
        kind: ResourceKind = .text,
        sourceID itemSourceID: UUID? = nil
    ) -> ResourceItem {
        ResourceItem(
            sourceID: itemSourceID ?? sourceID,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(isDirectory: kind == .folder),
            capabilities: [.read],
            accent: .teal
        )
    }
}
