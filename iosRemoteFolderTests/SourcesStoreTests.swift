import Foundation
import AVFoundation
import MediaPlayer
import Network
import PDFKit
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import iosRemoteFolder

/// 可控行为的桩 adapter：连接会等待测试释放，可注入失败、统计调用次数。
private final class StubSourceAdapter: ResourceSourceAdapter, @unchecked Sendable {
    let source: ResourceSource
    let items: [ResourceItem]

    private let lock = NSLock()
    private var released = false
    private var failure: ResourceSourceError?
    private var listFailure: ResourceSourceError?
    private var listDelay: Duration?
    private var connectCount = 0
    private var requestedListPaths: [ResourcePath] = []

    init(source: ResourceSource, items: [ResourceItem] = []) {
        self.source = source
        self.items = items
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectCount
    }

    var listPaths: [ResourcePath] {
        lock.lock()
        defer { lock.unlock() }
        return requestedListPaths
    }

    func setFailure(_ error: ResourceSourceError?) {
        lock.lock()
        defer { lock.unlock() }
        failure = error
    }

    func setListFailure(_ error: ResourceSourceError?) {
        lock.lock()
        defer { lock.unlock() }
        listFailure = error
    }

    func setListDelay(_ delay: Duration?) {
        lock.lock()
        defer { lock.unlock() }
        listDelay = delay
    }

    /// 释放所有等待中的 connect，使连接任务继续执行。
    func release() {
        lock.lock()
        defer { lock.unlock() }
        released = true
    }

    func connect() async throws {
        let currentFailure = beginConnect()
        while true {
            if isReleasedSnapshot { break }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        if let currentFailure {
            throw currentFailure
        }
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        let behavior = beginList(path)
        if let delay = behavior.delay {
            try await Task.sleep(for: delay)
        }
        if let failure = behavior.failure {
            throw failure
        }
        return items
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        throw ResourceSourceError.capabilityUnavailable
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        throw ResourceSourceError.capabilityUnavailable
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        throw ResourceSourceError.capabilityUnavailable
    }

    // MARK: - 同步锁辅助（NSLock 不能直接出现在 async 上下文）

    private func beginConnect() -> ResourceSourceError? {
        lock.lock()
        defer { lock.unlock() }
        connectCount += 1
        return failure
    }

    private func beginList(
        _ path: ResourcePath
    ) -> (failure: ResourceSourceError?, delay: Duration?) {
        lock.lock()
        defer { lock.unlock() }
        requestedListPaths.append(path)
        return (listFailure, listDelay)
    }

    private var isReleasedSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }
}

@Suite("来源连接状态仓库") @MainActor
struct SourcesStoreTests {
    @Test("无参数列举由协议扩展单向转发根目录")
    func noArgumentListingForwardsToRoot() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source)

        _ = try await stub.listResources()

        #expect(stub.listPaths == [.root])
    }

    @Test("连接成功进入就绪并回写资源数量")
    func connectSucceeds() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(
            source: source,
            items: [
                sampleItem(source.id, path: "/first.txt"),
                sampleItem(source.id, path: "/second.txt"),
            ]
        )
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connect(source.id)
        #expect(store.entries.first?.state == .connecting)

        stub.release()
        try await waitUntil { store.entries.first?.state == .ready }
        #expect(store.entries.first?.source.status == .connected)
        #expect(store.entries.first?.source.itemCountDescription == "2 个资源")
        #expect(stub.listPaths == [.root])
    }

    @Test("连接失败保留可行动错误")
    func connectFailsWithError() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source)
        stub.setFailure(.networkUnavailable)
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connect(source.id)
        stub.release()
        try await waitUntil { store.entries.first?.state == .failed(.networkUnavailable) }
        #expect(store.entries.first?.source.status == .needsAttention)
    }

    @Test("失败后重试可以成功")
    func retryAfterFailure() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source, items: [sampleItem(source.id)])
        stub.setFailure(.timedOut)
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connect(source.id)
        stub.release()
        try await waitUntil { store.entries.first?.state == .failed(.timedOut) }

        stub.setFailure(nil)
        store.retry(source.id)
        try await waitUntil { store.entries.first?.state == .ready }
        #expect(stub.calls == 2)
        #expect(store.entries.first?.source.itemCountDescription == "1 个资源")
    }

    @Test("没有适配器的来源保持未连接")
    func sourceWithoutAdapterStaysDisconnected() async throws {
        let source = makeSource(kind: .alist)
        let store = try makeStore(sources: [source], adapters: [])
        store.connectAll()
        #expect(store.entries.first?.state == .disconnected)
        #expect(store.entries.first?.hasAdapter == false)
    }

    @Test("connectAll 只连接未连接且有适配器的来源")
    func connectAllScope() async throws {
        let sourceA = makeSource()
        let sourceB = makeSource()
        let sourceC = makeSource(kind: .webdav)
        let stubA = StubSourceAdapter(source: sourceA)
        let stubB = StubSourceAdapter(source: sourceB)
        let store = try makeStore(
            sources: [sourceA, sourceB, sourceC],
            adapters: [stubA, stubB]
        )

        store.connectAll()
        #expect(entry(of: sourceA, in: store)?.state == .connecting)
        #expect(entry(of: sourceB, in: store)?.state == .connecting)
        #expect(entry(of: sourceC, in: store)?.state == .disconnected)

        stubA.release()
        stubB.release()
        try await waitUntil {
            entry(of: sourceA, in: store)?.state == .ready
                && entry(of: sourceB, in: store)?.state == .ready
        }
    }

    @Test("connectAll 不重复连接已就绪来源")
    func connectAllSkipsReady() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source)
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connectAll()
        stub.release()
        try await waitUntil { store.entries.first?.state == .ready }

        store.connectAll()
        #expect(stub.calls == 1)
        #expect(store.entries.first?.state == .ready)
    }

    @Test("浏览只按需连接选中来源并在切换时激活新来源")
    func browseActivationConnectsOnlySelectedSource() async throws {
        let firstSource = makeSource()
        let secondSource = makeSource()
        let firstStub = StubSourceAdapter(
            source: firstSource,
            items: [sampleItem(firstSource.id)]
        )
        let secondStub = StubSourceAdapter(
            source: secondSource,
            items: [sampleItem(secondSource.id)]
        )
        let store = try makeStore(
            sources: [firstSource, secondSource],
            adapters: [firstStub, secondStub]
        )

        let initialSelection = BrowseSourceActivation.activate(
            selectedSourceID: nil,
            store: store
        )

        #expect(initialSelection == firstSource.id)
        #expect(entry(of: firstSource, in: store)?.state == .connecting)
        #expect(entry(of: secondSource, in: store)?.state == .disconnected)
        #expect(secondStub.calls == 0)
        #expect(secondStub.listPaths.isEmpty)

        firstStub.release()
        try await waitUntil { entry(of: firstSource, in: store)?.state == .ready }

        let switchedSelection = BrowseSourceActivation.activate(
            selectedSourceID: secondSource.id,
            store: store
        )

        #expect(switchedSelection == secondSource.id)
        #expect(entry(of: secondSource, in: store)?.state == .connecting)
        #expect(firstStub.calls == 1)
        secondStub.release()
        try await waitUntil { entry(of: secondSource, in: store)?.state == .ready }
        #expect(secondStub.calls == 1)
        #expect(secondStub.listPaths == [.root])
    }

    @Test("浏览保留无适配器的现有选择且不发起连接")
    func browseActivationPreservesUnavailableSelection() throws {
        let unavailableSource = makeSource(kind: .alist)
        let availableSource = makeSource()
        let availableStub = StubSourceAdapter(source: availableSource)
        let store = try makeStore(
            sources: [unavailableSource, availableSource],
            adapters: [availableStub]
        )

        let resolvedSelection = BrowseSourceActivation.activate(
            selectedSourceID: unavailableSource.id,
            store: store
        )

        #expect(resolvedSelection == unavailableSource.id)
        #expect(entry(of: unavailableSource, in: store)?.state == .disconnected)
        #expect(entry(of: availableSource, in: store)?.state == .disconnected)
        #expect(availableStub.calls == 0)
        #expect(availableStub.listPaths.isEmpty)
    }

    @Test("浏览没有可用适配器时保留现有选择且不连接")
    func browseActivationDoesNotConnectWithoutAvailableAdapter() throws {
        let firstSource = makeSource(kind: .alist)
        let secondSource = makeSource(kind: .http)
        let store = try makeStore(
            sources: [firstSource, secondSource],
            adapters: []
        )

        let resolvedSelection = BrowseSourceActivation.activate(
            selectedSourceID: firstSource.id,
            store: store
        )

        #expect(resolvedSelection == firstSource.id)
        #expect(entry(of: firstSource, in: store)?.state == .disconnected)
        #expect(entry(of: secondSource, in: store)?.state == .disconnected)

        let emptySelection = BrowseSourceActivation.activate(
            selectedSourceID: nil,
            store: store
        )
        #expect(emptySelection == nil)
    }

    @Test("浏览生命周期不会隐式重试失败来源")
    func browseActivationDoesNotRetryFailedSource() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source)
        stub.setFailure(.networkUnavailable)
        let store = try makeStore(sources: [source], adapters: [stub])

        #expect(
            BrowseSourceActivation.activate(selectedSourceID: source.id, store: store)
                == source.id
        )
        stub.release()
        try await waitUntil { entry(of: source, in: store)?.state == .failed(.networkUnavailable) }

        #expect(
            BrowseSourceActivation.activate(selectedSourceID: source.id, store: store)
                == source.id
        )
        #expect(stub.calls == 1)
        #expect(stub.listPaths.isEmpty)
        #expect(entry(of: source, in: store)?.state == .failed(.networkUnavailable))
    }

    @Test("重复连接会替换上一次未完成任务")
    func duplicateConnectReplacesTask() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source, items: [sampleItem(source.id)])
        let store = try makeStore(sources: [source], adapters: [stub])

        store.connect(source.id)
        store.connect(source.id)
        stub.release()
        try await waitUntil { store.entries.first?.state == .ready }
        // 状态最终稳定在就绪，而不是被取消任务覆写。
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.entries.first?.state == .ready)
    }

    @Test("只有成功且当前代数的目录列举发布快照")
    func snapshotCallbackOnlyPublishesCurrentSuccess() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source, items: [sampleItem(source.id)])
        let store = try makeStore(sources: [source], adapters: [stub])
        var snapshotPaths: [ResourcePath] = []
        store.onDirectorySnapshot = { snapshotSourceID, path, _ in
            #expect(snapshotSourceID == source.id)
            snapshotPaths.append(path)
        }

        store.connect(source.id)
        stub.release()
        try await waitUntil { snapshotPaths == [.root] }

        let supersededPath = try #require(ResourcePath(rawValue: "/superseded"))
        let currentPath = try #require(ResourcePath(rawValue: "/current"))
        stub.setListDelay(.milliseconds(80))
        store.loadDirectory(source.id, at: supersededPath)
        try await waitUntil { stub.listPaths.contains(supersededPath) }
        store.loadDirectory(source.id, at: currentPath)
        try await waitUntil {
            store.entries.first?.browse.currentPath == currentPath
                && store.entries.first?.browse.isLoading == false
        }
        #expect(!snapshotPaths.contains(supersededPath))
        #expect(snapshotPaths.filter { $0 == currentPath }.count == 1)

        let failedPath = try #require(ResourcePath(rawValue: "/failed"))
        stub.setListDelay(nil)
        stub.setListFailure(.timedOut)
        store.loadDirectory(source.id, at: failedPath)
        try await waitUntil { store.entries.first?.browse.error == .timedOut }
        #expect(!snapshotPaths.contains(failedPath))
    }

    @Test("断线来源从搜索结果直接连接目标目录")
    func openDirectoryConnectsAtTargetPath() async throws {
        let source = makeSource()
        let stub = StubSourceAdapter(source: source, items: [sampleItem(source.id)])
        stub.setFailure(.networkUnavailable)
        let store = try makeStore(sources: [source], adapters: [stub])
        let targetPath = try #require(ResourcePath(rawValue: "/资料/项目"))
        var snapshotPaths: [ResourcePath] = []
        store.onDirectorySnapshot = { _, path, _ in snapshotPaths.append(path) }

        store.openDirectory(source.id, at: targetPath)
        #expect(store.entries.first?.state == .connecting)
        stub.release()
        try await waitUntil { store.entries.first?.state == .failed(.networkUnavailable) }
        #expect(store.entries.first?.browse.currentPath == targetPath)

        stub.setFailure(nil)
        store.retry(source.id)
        try await waitUntil { snapshotPaths == [targetPath] }

        #expect(store.entries.first?.state == .ready)
        #expect(store.entries.first?.browse.currentPath == targetPath)
        #expect(stub.listPaths == [targetPath])
    }

    @Test("前台恢复只自动重连瞬时失败的来源")
    func reconnectFailedSourcesRetriesOnlyTransientFailures() async throws {
        let transientSource = makeSource(kind: .webdav)
        let authSource = makeSource(kind: .webdav)
        let transientStub = StubSourceAdapter(
            source: transientSource,
            items: [sampleItem(transientSource.id)]
        )
        transientStub.setFailure(.networkUnavailable)
        transientStub.release()
        let authStub = StubSourceAdapter(source: authSource)
        authStub.setFailure(.authenticationRequired)
        authStub.release()
        // 关闭 registry 自动重试，隔离验证前台恢复入口自身的筛选逻辑。
        let store = try makeStore(
            sources: [transientSource, authSource],
            adapters: [transientStub, authStub],
            transientRetryDelays: []
        )

        store.connect(transientSource.id)
        store.connect(authSource.id)
        try await waitUntil {
            entry(of: transientSource, in: store)?.state == .failed(.networkUnavailable)
                && entry(of: authSource, in: store)?.state == .failed(.authenticationRequired)
        }

        transientStub.setFailure(nil)
        authStub.setFailure(nil)
        let authCallsBefore = authStub.calls
        store.reconnectFailedSources()
        try await waitUntil {
            entry(of: transientSource, in: store)?.state == .ready
        }
        // 认证失败需要用户行动，不允许被前台恢复自动重连。
        #expect(entry(of: authSource, in: store)?.state == .failed(.authenticationRequired))
        #expect(authStub.calls == authCallsBefore)
    }

    @Test("当前目录瞬时失败按各自原路径恢复")
    func recoverTransientDirectoryFailuresAtOriginalPaths() async throws {
        let firstSource = makeSource(kind: .webdav)
        let secondSource = makeSource(kind: .alist)
        let firstStub = StubSourceAdapter(
            source: firstSource,
            items: [sampleItem(firstSource.id)]
        )
        let secondStub = StubSourceAdapter(
            source: secondSource,
            items: [sampleItem(secondSource.id)]
        )
        firstStub.release()
        secondStub.release()
        let store = try makeStore(
            sources: [firstSource, secondSource],
            adapters: [firstStub, secondStub],
            transientRetryDelays: []
        )

        store.connect(firstSource.id)
        store.connect(secondSource.id)
        try await waitUntil {
            entry(of: firstSource, in: store)?.state == .ready
                && entry(of: secondSource, in: store)?.state == .ready
        }

        let firstPath = try #require(ResourcePath(rawValue: "/资料/项目"))
        let secondPath = try #require(ResourcePath(rawValue: "/媒体/电影"))
        firstStub.setListFailure(.networkUnavailable)
        secondStub.setListFailure(.httpStatus(503))
        store.loadDirectory(firstSource.id, at: firstPath)
        store.loadDirectory(secondSource.id, at: secondPath)
        try await waitUntil {
            entry(of: firstSource, in: store)?.browse.error == .networkUnavailable
                && entry(of: secondSource, in: store)?.browse.error == .httpStatus(503)
        }

        firstStub.setListFailure(nil)
        secondStub.setListFailure(nil)
        store.recoverTransientFailures()
        try await waitUntil {
            entry(of: firstSource, in: store)?.browse.error == nil
                && entry(of: secondSource, in: store)?.browse.error == nil
                && entry(of: firstSource, in: store)?.browse.isLoading == false
                && entry(of: secondSource, in: store)?.browse.isLoading == false
        }

        #expect(firstStub.listPaths == [.root, firstPath, firstPath])
        #expect(secondStub.listPaths == [.root, secondPath, secondPath])
        #expect(entry(of: firstSource, in: store)?.browse.currentPath == firstPath)
        #expect(entry(of: secondSource, in: store)?.browse.currentPath == secondPath)
    }

    @Test("确定性目录错误不会自动恢复")
    func deterministicDirectoryFailureDoesNotRecover() async throws {
        let source = makeSource(kind: .webdav)
        let stub = StubSourceAdapter(source: source)
        stub.release()
        let store = try makeStore(
            sources: [source],
            adapters: [stub],
            transientRetryDelays: []
        )
        store.connect(source.id)
        try await waitUntil { store.entries.first?.state == .ready }

        let path = try #require(ResourcePath(rawValue: "/协议错误"))
        stub.setListFailure(.invalidResponse)
        store.loadDirectory(source.id, at: path)
        try await waitUntil { store.entries.first?.browse.error == .invalidResponse }
        stub.setListFailure(nil)
        let pathsBeforeRecovery = stub.listPaths

        store.recoverTransientFailures()
        try await Task.sleep(for: .milliseconds(50))

        #expect(stub.listPaths == pathsBeforeRecovery)
        #expect(store.entries.first?.browse.error == .invalidResponse)
        #expect(store.entries.first?.browse.currentPath == path)
    }

    @Test("目录恢复加载中不会叠加重复请求")
    func directoryRecoveryDoesNotStackWhileLoading() async throws {
        let source = makeSource(kind: .webdav)
        let stub = StubSourceAdapter(source: source)
        stub.release()
        let store = try makeStore(
            sources: [source],
            adapters: [stub],
            transientRetryDelays: []
        )
        store.connect(source.id)
        try await waitUntil { store.entries.first?.state == .ready }

        let path = try #require(ResourcePath(rawValue: "/弱网目录"))
        stub.setListFailure(.timedOut)
        store.loadDirectory(source.id, at: path)
        try await waitUntil { store.entries.first?.browse.error == .timedOut }

        stub.setListFailure(nil)
        stub.setListDelay(.milliseconds(150))
        store.recoverTransientFailures()
        try await waitUntil {
            store.entries.first?.browse.isLoading == true
                && stub.listPaths.count == 3
        }
        store.recoverTransientFailures()
        store.recoverTransientFailures()
        try await Task.sleep(for: .milliseconds(30))

        #expect(stub.listPaths == [.root, path, path])
        try await waitUntil {
            store.entries.first?.browse.isLoading == false
                && store.entries.first?.browse.error == nil
        }
    }

    @Test("自动恢复白名单只包含明确瞬时错误")
    func automaticRecoveryWhitelistIsNarrow() {
        for error in [
            ResourceSourceError.timedOut,
            .networkUnavailable,
            .httpStatus(500),
            .httpStatus(503),
            .httpStatus(599),
        ] {
            #expect(error.isAutomaticallyRecoverable)
        }

        for error in [
            ResourceSourceError.authenticationRequired,
            .authorizationRequired,
            .permissionDenied,
            .notFound,
            .cancelled,
            .httpStatus(501),
            .httpStatus(505),
            .httpStatus(404),
            .invalidReference,
            .capabilityUnavailable,
            .responseTooLarge,
            .invalidResponse,
            .unsafeRedirect,
            .unavailable,
        ] {
            #expect(!error.isAutomaticallyRecoverable)
        }
    }

    @Test("网络状态仅在断开后的首次恢复触发")
    func networkRecoveryTransitionRequiresUnsatisfiedToSatisfied() {
        var state = NetworkRecoveryTransitionState()

        let initialSatisfied = state.consume(.satisfied)
        let repeatedSatisfied = state.consume(.satisfied)
        let requiresConnection = state.consume(.requiresConnection)
        let satisfiedWithoutOutage = state.consume(.satisfied)
        let firstUnsatisfied = state.consume(.unsatisfied)
        let repeatedUnsatisfied = state.consume(.unsatisfied)
        let recovered = state.consume(.satisfied)
        let satisfiedAfterRecovery = state.consume(.satisfied)
        let laterRequiresConnection = state.consume(.requiresConnection)
        let laterSatisfied = state.consume(.satisfied)

        #expect(!initialSatisfied)
        #expect(!repeatedSatisfied)
        #expect(!requiresConnection)
        #expect(!satisfiedWithoutOutage)
        #expect(!firstUnsatisfied)
        #expect(!repeatedUnsatisfied)
        #expect(recovered)
        #expect(!satisfiedAfterRecovery)
        #expect(!laterRequiresConnection)
        #expect(!laterSatisfied)
    }

    // MARK: - Helpers

    private func makeStore(
        sources: [ResourceSource],
        adapters: [any ResourceSourceAdapter],
        transientRetryDelays: [Duration] = SourceRegistry.defaultTransientRetryDelays
    ) throws -> SourcesStore {
        let registry = try SourceRegistry(
            sources: sources,
            adapters: adapters,
            transientRetryDelays: transientRetryDelays
        )
        return SourcesStore(registry: registry)
    }

    private func makeSource(kind: ResourceSource.SourceKind = .local) -> ResourceSource {
        ResourceSource(
            id: UUID(),
            name: "测试来源",
            kind: kind,
            endpoint: "test://fixture",
            status: .disconnected,
            itemCountDescription: ""
        )
    }

    private func sampleItem(_ sourceID: UUID, path: String = "/示例.txt") -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: .text,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .teal
        )
    }

    private func entry(of source: ResourceSource, in store: SourcesStore) -> SourcesStore.Entry? {
        store.entries.first { $0.id == source.id }
    }
}

@Suite("SwiftData 来源配置迁移")
@MainActor
struct SourceConfigurationMigrationTests {
    private struct LocalLegacyPayload: Codable {
        let version: Int
        let configurations: [LocalSourceConfiguration]
    }

    private struct RemoteLegacyPayload: Codable {
        let version: Int
        let configurations: [RemoteSourceConfiguration]
    }

    @Test("旧本地 payload 只迁移一次并在重建 store 后恢复")
    func migratesLocalPayloadAndRestoresFromSharedContainer() throws {
        let suiteName = "iosRemoteFolder.local-migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = SourceConfigurationPersistence.makeInMemoryContainer()
        let configuration = LocalSourceConfiguration(
            id: UUID(),
            displayName: "文档",
            endpointDescription: "Files 文件夹",
            location: try LocalSourceLocation(bookmarkData: Data([1, 2, 3]))
        )
        let payload = LocalLegacyPayload(version: 1, configurations: [configuration])
        defaults.set(
            try JSONEncoder().encode(payload),
            forKey: "localSourceConfigurations.v1"
        )

        let first = LocalSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        #expect(try first.load() == [configuration])
        #expect(defaults.data(forKey: "localSourceConfigurations.v1") == nil)

        let restored = LocalSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        #expect(try restored.load() == [configuration])
    }

    @Test("旧远端 payload 迁移后保留 endpoint 与凭证引用")
    func migratesRemotePayloadAndRestoresFromSharedContainer() throws {
        let suiteName = "iosRemoteFolder.remote-migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = SourceConfigurationPersistence.makeInMemoryContainer()
        let configuration = RemoteSourceConfiguration(
            id: UUID(),
            displayName: "家庭 Alist",
            endpoint: URL(string: "https://example.com/dav/")!,
            kind: .alist,
            credentialReference: UUID().uuidString.lowercased()
        )
        let payload = RemoteLegacyPayload(version: 1, configurations: [configuration])
        defaults.set(
            try JSONEncoder().encode(payload),
            forKey: "remoteSourceConfigurations.v1"
        )

        let first = RemoteSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        #expect(try first.load() == [configuration])
        #expect(defaults.data(forKey: "remoteSourceConfigurations.v1") == nil)

        let restored = RemoteSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        #expect(try restored.load() == [configuration])
    }

    @Test("已有 SwiftData 记录优先于遗留 payload，并清理遗留 key")
    func existingRecordsWinOverLegacyPayload() throws {
        let suiteName = "iosRemoteFolder.migration-precedence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = SourceConfigurationPersistence.makeInMemoryContainer()
        let stored = RemoteSourceConfiguration(
            id: UUID(),
            displayName: "已保存来源",
            endpoint: URL(string: "https://example.com/dav/")!,
            kind: .webdav,
            credentialReference: nil
        )
        let legacy = RemoteSourceConfiguration(
            id: UUID(),
            displayName: "旧来源",
            endpoint: URL(string: "https://legacy.example.com/dav/")!,
            kind: .webdav,
            credentialReference: nil
        )
        let store = RemoteSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        try store.save([stored])
        defaults.set(
            try JSONEncoder().encode(
                RemoteLegacyPayload(version: 1, configurations: [legacy])
            ),
            forKey: "remoteSourceConfigurations.v1"
        )

        let restored = RemoteSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        #expect(try restored.load() == [stored])
        #expect(defaults.data(forKey: "remoteSourceConfigurations.v1") == nil)
    }

    @Test("AppModel 只注入一侧 store 时复用同一 ModelContainer")
    func appModelReusesInjectedContainerForMissingStore() throws {
        let container = SourceConfigurationPersistence.makeInMemoryContainer()
        let remote = RemoteSourceConfiguration(
            id: UUID(),
            displayName: "共享容器来源",
            endpoint: URL(string: "https://example.com/dav/")!,
            kind: .webdav,
            credentialReference: nil
        )
        let remoteStore = RemoteSourceConfigurationStore(modelContainer: container)
        try remoteStore.save([remote])

        let localStore = LocalSourceConfigurationStore(modelContainer: container)
        let model = AppModel(configurationStore: localStore)

        #expect(model.sources.contains { $0.id == remote.id })
    }

    @Test("首页删除最后一条历史后不回退当前目录资源")
    func homeHistoryDoesNotFallBackToCurrentDirectory() throws {
        let model = AppModel(
            modelContainer: SourceConfigurationPersistence.makeInMemoryContainer()
        )
        let resource = ResourceItem(
            sourceID: UUID(),
            logicalPath: try #require(ResourcePath(rawValue: "/notes/current.txt")),
            name: "current.txt",
            kind: .text,
            metadata: ResourceMetadata(
                byteSize: 7,
                mimeType: "text/plain",
                isDirectory: false
            ),
            capabilities: [.read],
            accent: .teal
        )
        model.resources = [resource]

        model.recordRecent(resource: resource, metadata: resource.metadata)
        #expect(model.homeResources.map(\.id) == [resource.id])

        model.removeRecent(identity: resource.id)
        #expect(model.recentResources.isEmpty)
        #expect(model.homeResources.isEmpty)
        #expect(model.resources.map(\.id) == [resource.id])
    }

    @Test("文件型容器重建后恢复本地与远端迁移配置")
    func fileBackedContainerRestoresConfigurationsAfterReopen() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-source-store-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: temporaryDirectory)
            } catch {
                Issue.record("无法清理临时 SwiftData store：\(error.localizedDescription)")
            }
        }

        let suiteName = "iosRemoteFolder.file-backed-migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let localLegacyKey = "localSourceConfigurations.v1"
        let remoteLegacyKey = "remoteSourceConfigurations.v1"
        let local = LocalSourceConfiguration(
            id: UUID(),
            displayName: "文件型本地来源",
            endpointDescription: "Files 文件夹",
            location: try LocalSourceLocation(bookmarkData: Data([0x01, 0x02, 0x03]))
        )
        let remote = RemoteSourceConfiguration(
            id: UUID(),
            displayName: "文件型远端来源",
            endpoint: URL(string: "https://example.com/dav/")!,
            kind: .webdav,
            credentialReference: UUID().uuidString.lowercased()
        )
        defaults.set(
            try JSONEncoder().encode(LocalLegacyPayload(version: 1, configurations: [local])),
            forKey: localLegacyKey
        )
        defaults.set(
            try JSONEncoder().encode(RemoteLegacyPayload(version: 1, configurations: [remote])),
            forKey: remoteLegacyKey
        )

        let storeURL = temporaryDirectory.appendingPathComponent("SourceConfigurations.store")
        try withPersistentStores(at: storeURL, defaults: defaults) { localStore, remoteStore in
            let loadedLocal = try localStore.load()
            let loadedRemote = try remoteStore.load()
            #expect(loadedLocal == [local])
            #expect(loadedRemote == [remote])
        }
        #expect(defaults.data(forKey: localLegacyKey) == nil)
        #expect(defaults.data(forKey: remoteLegacyKey) == nil)

        try withPersistentStores(at: storeURL, defaults: defaults) { localStore, remoteStore in
            let reopenedLocal = try localStore.load()
            let reopenedRemote = try remoteStore.load()
            #expect(reopenedLocal == [local])
            #expect(reopenedRemote == [remote])
        }
        #expect(defaults.data(forKey: localLegacyKey) == nil)
        #expect(defaults.data(forKey: remoteLegacyKey) == nil)
    }

    @Test("远端来源改名保留派生状态而 endpoint 变化会清理")
    func remoteNamespaceChangeInvalidatesDerivedState() async throws {
        let suiteName = "iosRemoteFolder.remote-namespace.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = SourceConfigurationPersistence.makeInMemoryContainer()
        let localStore = LocalSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        let remoteStore = RemoteSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        let sourceID = UUID()
        let configuration = RemoteSourceConfiguration(
            id: sourceID,
            displayName: "旧名称",
            endpoint: URL(string: "http://127.0.0.1:49101/dav/")!,
            kind: .webdav,
            credentialReference: nil
        )
        try remoteStore.insert(configuration)

        let model = AppModel(
            configurationStore: localStore,
            remoteConfigurationStore: remoteStore
        )
        let metadata = ResourceMetadata(
            byteSize: 7,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            mimeType: "text/plain",
            isDirectory: false,
            revision: .etag("\"namespace-v1\"")
        )
        let resource = ResourceItem(
            sourceID: sourceID,
            logicalPath: try #require(ResourcePath(rawValue: "/notes/readme.txt")),
            name: "readme.txt",
            kind: .text,
            metadata: metadata,
            capabilities: [.read, .download],
            accent: .blue
        )
        let audio = ResourceItem(
            sourceID: sourceID,
            logicalPath: try #require(ResourcePath(rawValue: "/music/theme.m4a")),
            name: "theme.m4a",
            kind: .audio,
            metadata: metadata,
            capabilities: [.read, .download],
            accent: .pink
        )
        let cacheKey = try #require(
            ResourceCacheKey(
                identity: resource.id,
                revision: metadata.revision,
                variant: .content
            )
        )
        model.recordRecent(resource: resource, metadata: metadata)
        model.recordResumePosition(.seconds(12), for: audio, metadata: metadata)
        model.recordReadingPosition(.text(fraction: 0.4), for: resource, metadata: metadata)
        try await model.cacheCoordinator.store(
            Data("content".utf8),
            for: cacheKey,
            maximumBytes: 1_024
        )
        try await model.resourceIndexStore.replaceDirectory(
            sourceID: sourceID,
            parentPath: try #require(ResourcePath(rawValue: "/notes")),
            items: [resource]
        )

        model.editRemoteSource(
            sourceID: sourceID,
            name: "新名称",
            endpoint: configuration.endpoint,
            kind: .webdav,
            username: "",
            password: ""
        )
        try await waitUntil {
            model.sources.first(where: { $0.id == sourceID })?.name == "新名称"
        }
        #expect(model.recentResources.contains { $0.id == resource.id })
        #expect(model.resumePosition(for: audio, metadata: metadata) == .seconds(12))
        #expect(model.readingPosition(for: resource, metadata: metadata) == .text(fraction: 0.4))
        #expect(try await model.cacheCoordinator.data(for: cacheKey, maximumBytes: 1_024) != nil)
        let indexCountAfterRename = try await model.resourceIndexStore.indexedResourceCount(
            sourceID: sourceID
        )
        #expect(indexCountAfterRename == 1)

        model.editRemoteSource(
            sourceID: sourceID,
            name: "新名称",
            endpoint: "http://127.0.0.1:49102/dav/",
            kind: .webdav,
            username: "",
            password: ""
        )
        try await waitUntil {
            model.sources.first(where: { $0.id == sourceID })?.endpoint
                == "http://127.0.0.1:49102/dav/"
        }
        // 派生状态失效在描述同步之后异步执行；轮询失效链路的最后一步
        // （索引清零），它完成即代表前序清理全部完成。
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < cleanupDeadline {
            let count = try await model.resourceIndexStore.indexedResourceCount(
                sourceID: sourceID
            )
            if count == 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.recentResources.contains { $0.id == resource.id })
        #expect(model.resumePosition(for: audio, metadata: metadata) == nil)
        #expect(model.readingPosition(for: resource, metadata: metadata) == nil)
        #expect(try await model.cacheCoordinator.data(for: cacheKey, maximumBytes: 1_024) == nil)
        let indexCountAfterEndpointChange = try await model.resourceIndexStore.indexedResourceCount(
            sourceID: sourceID
        )
        #expect(indexCountAfterEndpointChange == 0)
    }

    /// The stores and their shared container leave scope before a second
    /// container opens the same file-backed store URL.
    private func withPersistentStores(
        at storeURL: URL,
        defaults: UserDefaults,
        _ body: (
            LocalSourceConfigurationStore,
            RemoteSourceConfigurationStore
        ) throws -> Void
    ) throws {
        let container = try SourceConfigurationPersistence.makePersistentContainer(at: storeURL)
        let localStore = LocalSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        let remoteStore = RemoteSourceConfigurationStore(
            modelContainer: container,
            defaults: defaults
        )
        try body(localStore, remoteStore)
    }
}

/// 在超时前轮询等待条件成立；超时记录测试失败。
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("等待条件超时")
}

/// 瞬时失败桩：所有操作共享一个尝试计数，先失败指定次数再成功。
private final class FlakyStubAdapter: ResourceSourceAdapter, @unchecked Sendable {
    let source: ResourceSource

    private let lock = NSLock()
    private let failure: ResourceSourceError
    private var remainingFailures: Int
    private var attemptCount = 0
    private let content = Data("flaky".utf8)

    init(
        source: ResourceSource,
        failuresBeforeSuccess: Int,
        failure: ResourceSourceError
    ) {
        self.source = source
        self.remainingFailures = failuresBeforeSuccess
        self.failure = failure
    }

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptCount
    }

    func connect() async throws {
        try gate()
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        try gate()
        return []
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        throw ResourceSourceError.capabilityUnavailable
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        try gate()
        return ResourceMetadata(byteSize: Int64(content.count))
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        try gate()
        guard range == nil else { throw ResourceSourceError.capabilityUnavailable }
        return content
    }

    private func gate() throws {
        lock.lock()
        attemptCount += 1
        let shouldFail = remainingFailures > 0
        if shouldFail { remainingFailures -= 1 }
        lock.unlock()
        if shouldFail { throw failure }
    }
}

@Suite("来源瞬时错误自动重试")
struct SourceTransientRetryTests {
    @Test("远端来源瞬时失败按退避重试后成功")
    func remoteTransientFailureRetriesUntilSuccess() async throws {
        let source = makeSource(kind: .webdav)
        let adapter = FlakyStubAdapter(
            source: source,
            failuresBeforeSuccess: 2,
            failure: .networkUnavailable
        )
        let registry = try SourceRegistry(
            sources: [source],
            adapters: [adapter],
            transientRetryDelays: [.milliseconds(5), .milliseconds(5)]
        )
        try await registry.connect(sourceID: source.id)
        #expect(adapter.attempts == 3)
    }

    @Test("读取路径的瞬时失败同样自动重试")
    func readDataRetriesTransientFailure() async throws {
        let source = makeSource(kind: .alist)
        let adapter = FlakyStubAdapter(
            source: source,
            failuresBeforeSuccess: 1,
            failure: .timedOut
        )
        let registry = try SourceRegistry(
            sources: [source],
            adapters: [adapter],
            transientRetryDelays: [.milliseconds(5), .milliseconds(5)]
        )
        let data = try await registry.readData(
            sourceID: source.id,
            for: makeItem(sourceID: source.id),
            range: nil
        )
        #expect(data == Data("flaky".utf8))
        #expect(adapter.attempts == 2)
    }

    @Test("确定性失败不自动重试")
    func deterministicFailureDoesNotRetry() async throws {
        let authSource = makeSource(kind: .webdav)
        let authAdapter = FlakyStubAdapter(
            source: authSource,
            failuresBeforeSuccess: 1,
            failure: .authenticationRequired
        )
        let authRegistry = try SourceRegistry(
            sources: [authSource],
            adapters: [authAdapter],
            transientRetryDelays: [.milliseconds(5), .milliseconds(5)]
        )
        await #expect(throws: ResourceSourceError.authenticationRequired) {
            try await authRegistry.connect(sourceID: authSource.id)
        }
        #expect(authAdapter.attempts == 1)

        // 协议违约意味着数据完整性问题，自动重试只会掩盖真实原因。
        let invalidSource = makeSource(kind: .webdav)
        let invalidAdapter = FlakyStubAdapter(
            source: invalidSource,
            failuresBeforeSuccess: 1,
            failure: .invalidResponse
        )
        let invalidRegistry = try SourceRegistry(
            sources: [invalidSource],
            adapters: [invalidAdapter],
            transientRetryDelays: [.milliseconds(5), .milliseconds(5)]
        )
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await invalidRegistry.readData(
                sourceID: invalidSource.id,
                for: makeItem(sourceID: invalidSource.id),
                range: nil
            )
        }
        #expect(invalidAdapter.attempts == 1)

        // unavailable 是映射兜底桶（含 TLS 证书不受信等确定性失败），不重试。
        let fallbackSource = makeSource(kind: .http)
        let fallbackAdapter = FlakyStubAdapter(
            source: fallbackSource,
            failuresBeforeSuccess: 1,
            failure: .unavailable
        )
        let fallbackRegistry = try SourceRegistry(
            sources: [fallbackSource],
            adapters: [fallbackAdapter],
            transientRetryDelays: [.milliseconds(5), .milliseconds(5)]
        )
        await #expect(throws: ResourceSourceError.unavailable) {
            try await fallbackRegistry.connect(sourceID: fallbackSource.id)
        }
        #expect(fallbackAdapter.attempts == 1)

        // 501 Not Implemented 属确定性服务端能力问题，同样不重试。
        let notImplementedSource = makeSource(kind: .webdav)
        let notImplementedAdapter = FlakyStubAdapter(
            source: notImplementedSource,
            failuresBeforeSuccess: 1,
            failure: .httpStatus(501)
        )
        let notImplementedRegistry = try SourceRegistry(
            sources: [notImplementedSource],
            adapters: [notImplementedAdapter],
            transientRetryDelays: [.milliseconds(5), .milliseconds(5)]
        )
        await #expect(throws: ResourceSourceError.httpStatus(501)) {
            try await notImplementedRegistry.connect(sourceID: notImplementedSource.id)
        }
        #expect(notImplementedAdapter.attempts == 1)
    }

    @Test("本地来源不参与自动重试")
    func localSourceFailsWithoutRetry() async throws {
        let source = makeSource(kind: .local)
        let adapter = FlakyStubAdapter(
            source: source,
            failuresBeforeSuccess: 1,
            failure: .networkUnavailable
        )
        let registry = try SourceRegistry(
            sources: [source],
            adapters: [adapter],
            transientRetryDelays: [.milliseconds(5), .milliseconds(5)]
        )
        await #expect(throws: ResourceSourceError.networkUnavailable) {
            try await registry.connect(sourceID: source.id)
        }
        #expect(adapter.attempts == 1)
    }

    @Test("退避等待期间取消映射为 cancelled 且不再尝试")
    func cancellationDuringBackoffStopsRetrying() async throws {
        let source = makeSource(kind: .webdav)
        let adapter = FlakyStubAdapter(
            source: source,
            failuresBeforeSuccess: 10,
            failure: .networkUnavailable
        )
        let registry = try SourceRegistry(
            sources: [source],
            adapters: [adapter],
            transientRetryDelays: [.seconds(5)]
        )
        let task = Task {
            try await registry.connect(sourceID: source.id)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while adapter.attempts == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.attempts == 1)
        task.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await task.value
        }
        #expect(adapter.attempts == 1)
    }

    private func makeSource(kind: ResourceSource.SourceKind) -> ResourceSource {
        ResourceSource(
            id: UUID(),
            name: "重试测试来源",
            kind: kind,
            endpoint: "https://retry.test/dav/",
            status: .disconnected,
            itemCountDescription: ""
        )
    }

    private func makeItem(sourceID: UUID) -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: "/flaky.txt")!,
            name: "flaky.txt",
            kind: .text,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .blue
        )
    }
}

/// 内容会话专用桩：可观察 metadata/read 次数，并可在读取前挂起以验证取消。
private final class ContentStubAdapter: ResourceSourceAdapter, @unchecked Sendable {
    let source: ResourceSource
    let metadata: ResourceMetadata
    let content: Data
    let delay: Duration?
    let rangeResponse: Data?

    private let lock = NSLock()
    private var metadataCallCount = 0
    private var readCallCount = 0
    private var requestedRanges: [ResourceByteRange?] = []

    init(
        source: ResourceSource,
        metadata: ResourceMetadata,
        content: Data,
        delay: Duration? = nil,
        rangeResponse: Data? = nil
    ) {
        self.source = source
        self.metadata = metadata
        self.content = content
        self.delay = delay
        self.rangeResponse = rangeResponse
    }

    var metadataCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return metadataCallCount
    }

    var readCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCallCount
    }

    var readRanges: [ResourceByteRange?] {
        lock.lock()
        defer { lock.unlock() }
        return requestedRanges
    }

    func connect() async throws {}

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        []
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        throw ResourceSourceError.capabilityUnavailable
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        incrementMetadataCalls()
        return metadata
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        recordRead(range: range)
        if let delay {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        guard let range else { return content }
        if let rangeResponse { return rangeResponse }
        guard range.lowerBound < Int64(content.count) else { return Data() }
        let upperBound = min(range.upperBound, Int64(content.count - 1))
        let lowerIndex = Int(range.lowerBound)
        let upperIndex = Int(upperBound) + 1
        return content.subdata(
            in: lowerIndex..<upperIndex
        )
    }

    private func incrementMetadataCalls() {
        lock.lock()
        metadataCallCount += 1
        lock.unlock()
    }

    private func recordRead(range: ResourceByteRange?) {
        lock.lock()
        readCallCount += 1
        requestedRanges.append(range)
        lock.unlock()
    }
}

@Suite("统一来源注册与内容会话")
struct ResourceAccessServiceTests {
    @Test("registry 拒绝重复来源、未注册 adapter 和重复 adapter")
    func registryRejectsDuplicateConfiguration() {
        let source = makeSource()
        let otherSource = makeSource()
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(),
            content: Data()
        )

        #expect(throws: SourceRegistryError.duplicateSourceID(source.id)) {
            _ = try SourceRegistry(sources: [source, source], adapters: [])
        }
        #expect(throws: SourceRegistryError.adapterSourceNotRegistered(otherSource.id)) {
            _ = try SourceRegistry(sources: [source], adapters: [
                ContentStubAdapter(
                    source: otherSource,
                    metadata: ResourceMetadata(),
                    content: Data()
                )
            ])
        }
        #expect(throws: SourceRegistryError.duplicateAdapterSourceID(source.id)) {
            _ = try SourceRegistry(sources: [source], adapters: [adapter, adapter])
        }
    }

    @Test("完整读取先取最新 metadata，并拒绝未知或超预算大小")
    func fullReadRequiresKnownBudget() async throws {
        let source = makeSource()
        let content = Data("hello".utf8)
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(byteSize: Int64(content.count)),
            content: content
        )
        let session = try await makeService(source: source, adapter: adapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))

        let result = try await session.readData(maximumBytes: 5)
        let cachedMetadata = try await session.fetchMetadata()
        #expect(result == content)
        #expect(cachedMetadata.byteSize == 5)
        #expect(adapter.metadataCalls == 1)
        #expect(adapter.readCalls == 1)

        let tooSmall = try await makeService(
            source: source,
            adapter: ContentStubAdapter(
                source: source,
                metadata: ResourceMetadata(byteSize: Int64(content.count)),
                content: content
            )
        ).makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            _ = try await tooSmall.readData(maximumBytes: 4)
        }

        let unknownAdapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(),
            content: content
        )
        let unknown = try await makeService(source: source, adapter: unknownAdapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            _ = try await unknown.readData(maximumBytes: 5)
        }
        #expect(unknownAdapter.readCalls == 0)
    }

    @Test("区间读取采用会话 metadata 快照并校验 Range 证据与预算")
    func rangeReadUsesMetadataSnapshotAndChecksBudget() async throws {
        let source = makeSource()
        let content = Data("0123456789".utf8)
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(
                byteSize: Int64(content.count),
                acceptsRanges: true
            ),
            content: content
        )
        let service = try makeService(source: source, adapter: adapter)
        let staleCapabilities = try await service.makeSession(
            for: makeItem(sourceID: source.id, capabilities: [.read])
        )
        let rangeData = try await staleCapabilities.readData(
            range: ResourceByteRange(lowerBound: 0, upperBound: 1),
            maximumBytes: 2
        )
        #expect(rangeData == Data("01".utf8))
        #expect(adapter.metadataCalls == 1)
        #expect(adapter.readCalls == 1)

        let tooLarge = try await service.makeSession(
            for: makeItem(sourceID: source.id, capabilities: [.read, .rangeRead])
        )
        await #expect(throws: ResourceSourceError.responseTooLarge) {
            _ = try await tooLarge.readData(
                range: ResourceByteRange(lowerBound: 0, upperBound: 2),
                maximumBytes: 2
            )
        }
        #expect(adapter.readCalls == 1)

        let noMetadataRangeAdapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(
                byteSize: Int64(content.count),
                acceptsRanges: false
            ),
            content: content
        )
        let noMetadataRange = try await makeService(
            source: source,
            adapter: noMetadataRangeAdapter
        ).makeSession(for: makeItem(sourceID: source.id, capabilities: [.read, .rangeRead]))
        await #expect(throws: ResourceSourceError.capabilityUnavailable) {
            _ = try await noMetadataRange.readData(
                range: ResourceByteRange(lowerBound: 0, upperBound: 1),
                maximumBytes: 2
            )
        }
        #expect(noMetadataRangeAdapter.readCalls == 0)
    }

    @Test("违约响应不交付，并且 close/cancel 是幂等终态")
    func responseValidationAndTerminalCancellation() async throws {
        let source = makeSource()
        let content = Data("0123456789".utf8)
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(
                byteSize: Int64(content.count),
                acceptsRanges: true
            ),
            content: content,
            rangeResponse: Data("overflow".utf8)
        )
        let session = try await makeService(source: source, adapter: adapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read, .rangeRead]))
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await session.readData(
                range: ResourceByteRange(lowerBound: 0, upperBound: 1),
                maximumBytes: 20
            )
        }

        let shortAdapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(
                byteSize: Int64(content.count),
                acceptsRanges: true
            ),
            content: content,
            rangeResponse: Data("0".utf8)
        )
        let shortSession = try await makeService(source: source, adapter: shortAdapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read, .rangeRead]))
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await shortSession.readData(
                range: ResourceByteRange(lowerBound: 0, upperBound: 1),
                maximumBytes: 2
            )
        }
        await shortSession.close()

        await session.cancel()
        await session.close()
        await session.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await session.fetchMetadata()
        }
    }

    @Test("完整读取交付前校验精确长度，截断正文违约")
    func fullReadRejectsTruncatedBody() async throws {
        let source = makeSource()
        let shortAdapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(byteSize: 10),
            content: Data("hello".utf8)
        )
        let session = try await makeService(source: source, adapter: shortAdapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))
        await #expect(throws: ResourceSourceError.invalidResponse) {
            _ = try await session.readData(maximumBytes: 10)
        }
    }

    @Test("调用方取消会取消对应在途操作")
    func callerCancellationCancelsOperation() async throws {
        let source = makeSource()
        let adapter = ContentStubAdapter(
            source: source,
            metadata: ResourceMetadata(byteSize: 5),
            content: Data("hello".utf8),
            delay: .seconds(10)
        )
        let session = try await makeService(source: source, adapter: adapter)
            .makeSession(for: makeItem(sourceID: source.id, capabilities: [.read]))
        let task = Task {
            try await session.readData(maximumBytes: 5)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await task.value
        }
    }

    private func makeService(
        source: ResourceSource,
        adapter: any ResourceSourceAdapter
    ) throws -> ResourceAccessService {
        let registry = try SourceRegistry(sources: [source], adapters: [adapter])
        return ResourceAccessService(registry: registry)
    }

    private func makeSource() -> ResourceSource {
        ResourceSource(
            id: UUID(),
            name: "会话测试来源",
            kind: .local,
            endpoint: "test://content",
            status: .disconnected,
            itemCountDescription: ""
        )
    }

    private func makeItem(
        sourceID: UUID,
        capabilities: ResourceCapability
    ) -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: "/content.txt")!,
            name: "content.txt",
            kind: .text,
            metadata: ResourceMetadata(),
            capabilities: capabilities,
            accent: .blue
        )
    }
}

@Suite("AVPlayer 内容会话桥接")
@MainActor
struct SessionMediaPlayerTests {
    @Test("媒体准备策略仅让已知大于 4 MiB 的在线 Range 资源流式加载")
    func resolvesMediaPreparationStrategyAtStreamingBoundary() {
        let threshold = MediaPreparationStrategy.streamingThresholdBytes
        let cases: [(
            name: String,
            mode: ResourceViewerMode,
            acceptsRanges: Bool,
            byteSize: Int64?,
            expected: MediaPreparationStrategy
        )] = [
            ("大于阈值", .online, true, threshold + 1, .rangeStream),
            ("等于阈值", .online, true, threshold, .completeContent),
            ("离线资源", .offline, true, threshold + 1, .completeContent),
            ("服务端不支持 Range", .online, false, threshold + 1, .completeContent),
            ("大小未知", .online, true, nil, .completeContent)
        ]

        for testCase in cases {
            let metadata = ResourceMetadata(
                byteSize: testCase.byteSize,
                acceptsRanges: testCase.acceptsRanges
            )

            #expect(
                MediaPreparationStrategy.resolve(mode: testCase.mode, metadata: metadata)
                    == testCase.expected,
                "\(testCase.name)的分流结果不正确"
            )
        }
    }

    @Test("音频通过有界 Range 会话完成准备并在停止后关闭会话")
    func preparesAudioThroughBoundedRanges() async throws {
        let source = try #require(
            SampleData.sources.first { $0.id == SampleData.workSourceID }
        )
        let item = try #require(
            SampleData.resources.first { $0.path == "/产品/路线图演示.wav" }
        )
        let bytes = try await SampleSourceAdapter(source: source).readData(for: item, range: nil)
        try await assertSessionPlayback(
            bytes: bytes,
            path: "/stream.wav",
            kind: .audio,
            mimeType: "audio/wav",
            typeIdentifier: "com.microsoft.waveform-audio",
            expectedMediaType: .audio
        )
    }

    @Test("大 MP3 通过有界 Range 准备且覆盖高位分片")
    func preparesLargeMP3ThroughBoundedHighRanges() async throws {
        let bytes = try makeLargeMP3()
        #expect(bytes.count > 5 * 1024 * 1024)

        try await assertSessionPlayback(
            bytes: bytes,
            path: "/stream.mp3",
            kind: .audio,
            mimeType: "audio/mpeg",
            typeIdentifier: UTType.mp3.identifier,
            expectedMediaType: .audio,
            assertHighRangeCoverage: true
        )
    }

    @Test("prepare 在途停止会取消分片并关闭会话")
    func stoppingInFlightPreparationCancelsSession() async throws {
        let source = try #require(
            SampleData.sources.first { $0.id == SampleData.workSourceID }
        )
        let sampleItem = try #require(
            SampleData.resources.first { $0.path == "/产品/路线图演示.wav" }
        )
        let bytes = try await SampleSourceAdapter(source: source).readData(for: sampleItem, range: nil)
        let metadata = ResourceMetadata(
            byteSize: Int64(bytes.count),
            mimeType: "audio/wav",
            typeIdentifier: "com.microsoft.waveform-audio",
            acceptsRanges: true
        )
        let adapter = ContentStubAdapter(
            source: source,
            metadata: metadata,
            content: bytes,
            delay: .seconds(10)
        )
        let registry = try SourceRegistry(sources: [source], adapters: [adapter])
        let item = ResourceItem(
            sourceID: source.id,
            logicalPath: ResourcePath(rawValue: "/cancel.wav")!,
            name: "cancel.wav",
            kind: .audio,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .pink
        )
        let session = try await ResourceAccessService(registry: registry).makeSession(for: item)
        let engine = try AVMediaPlayerEngine(
            session: session,
            metadata: metadata,
            resourcePath: item.path
        )
        let preparation = Task {
            try await engine.prepare(expectedMediaType: .audio)
        }

        try await waitUntil { adapter.readCalls > 0 }
        engine.stop()
        preparation.cancel()
        do {
            try await preparation.value
            Issue.record("停止后的 prepare 不应迟到成功")
        } catch {
            // Cancellation may surface from AVFoundation or the content session.
        }
        let readsAtStop = adapter.readCalls
        try await Task.sleep(for: .milliseconds(100))
        #expect(adapter.readCalls == readsAtStop)
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await session.fetchMetadata()
        }
    }

    @Test("prepare 在统一 deadline 到期时映射为可重试的 timedOut 失败态")
    func prepareFailsWithTimedOutAtExpiredDeadline() async throws {
        let source = try #require(
            SampleData.sources.first { $0.id == SampleData.workSourceID }
        )
        let sampleItem = try #require(
            SampleData.resources.first { $0.path == "/产品/路线图演示.wav" }
        )
        let bytes = try await SampleSourceAdapter(source: source).readData(for: sampleItem, range: nil)
        let metadata = ResourceMetadata(
            byteSize: Int64(bytes.count),
            mimeType: "audio/wav",
            typeIdentifier: "com.microsoft.waveform-audio"
        )
        let engine = try AVMediaPlayerEngine(
            data: bytes,
            metadata: metadata,
            resourcePath: "/deadline.wav"
        )
        await #expect(throws: ResourceSourceError.timedOut) {
            try await engine.prepare(
                expectedMediaType: .audio,
                deadline: ContinuousClock().now
            )
        }
        #expect(engine.playbackState == .failed(.timedOut))
        engine.stop()
    }

    @Test("Now Playing 激活发布锁屏信息，注销后清空")
    func nowPlayingControllerPublishesAndClearsInfo() async throws {
        let source = try #require(
            SampleData.sources.first { $0.id == SampleData.workSourceID }
        )
        let sampleItem = try #require(
            SampleData.resources.first { $0.path == "/产品/路线图演示.wav" }
        )
        let bytes = try await SampleSourceAdapter(source: source).readData(for: sampleItem, range: nil)
        let metadata = ResourceMetadata(
            byteSize: Int64(bytes.count),
            mimeType: "audio/wav",
            typeIdentifier: "com.microsoft.waveform-audio"
        )
        let engine = try AVMediaPlayerEngine(
            data: bytes,
            metadata: metadata,
            resourcePath: "/nowplaying.wav"
        )
        try await engine.prepare(expectedMediaType: .audio)

        let controller = MediaNowPlayingController()
        controller.activate(title: "锁屏标题", engine: engine, isVideo: false)
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(info?[MPMediaItemPropertyTitle] as? String == "锁屏标题")
        #expect((info?[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0) > 0)

        controller.deactivate()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        // deactivate 幂等，重复调用无副作用。
        controller.deactivate()
        engine.stop()
    }

    @Test("视频通过有界 Range 会话完成准备并支持 seek")
    func preparesVideoThroughBoundedRanges() async throws {
        let source = try #require(
            SampleData.sources.first { $0.id == SampleData.workSourceID }
        )
        let item = try #require(
            SampleData.resources.first { $0.path == "/产品/路线图演示.mp4" }
        )
        let bytes = try await SampleSourceAdapter(source: source).readData(for: item, range: nil)
        try await assertSessionPlayback(
            bytes: bytes,
            path: "/stream.mp4",
            kind: .video,
            mimeType: "video/mp4",
            typeIdentifier: UTType.mpeg4Movie.identifier,
            expectedMediaType: .video
        )
    }

    private func assertSessionPlayback(
        bytes: Data,
        path: String,
        kind: ResourceKind,
        mimeType: String,
        typeIdentifier: String,
        expectedMediaType: AVMediaType,
        assertHighRangeCoverage: Bool = false
    ) async throws {
        let source = ResourceSource(
            id: UUID(),
            name: "媒体会话测试来源",
            kind: .http,
            endpoint: "https://media.test",
            status: .disconnected,
            itemCountDescription: ""
        )
        let metadata = ResourceMetadata(
            byteSize: Int64(bytes.count),
            mimeType: mimeType,
            typeIdentifier: typeIdentifier,
            acceptsRanges: true,
            revision: .serverVersion("media-v1")
        )
        let adapter = ContentStubAdapter(
            source: source,
            metadata: metadata,
            content: bytes
        )
        let registry = try SourceRegistry(sources: [source], adapters: [adapter])
        let item = ResourceItem(
            sourceID: source.id,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .recommended(for: kind)
        )
        let session = try await ResourceAccessService(registry: registry).makeSession(for: item)
        let engine = try AVMediaPlayerEngine(
            session: session,
            metadata: metadata,
            resourcePath: path
        )

        try await engine.prepare(expectedMediaType: expectedMediaType)
        #expect(engine.duration > 0)
        #expect(adapter.metadataCalls == 1)
        try await Task.sleep(for: .milliseconds(100))
        let rangesBeforeSeek = adapter.readRanges.compactMap { $0 }
        if assertHighRangeCoverage {
            engine.seek(to: engine.duration * 0.8)
            #expect(engine.play())
            if !rangesBeforeSeek.contains(where: { $0.upperBound >= Int64(bytes.count / 2) }) {
                try await waitUntil {
                    adapter.readRanges
                        .compactMap { $0 }
                        .contains { $0.upperBound >= Int64(bytes.count / 2) }
                }
            }
            engine.pause()
        } else {
            engine.seek(to: engine.duration / 2)
        }

        let ranges = adapter.readRanges.compactMap { $0 }
        #expect(!ranges.isEmpty)
        #expect(!adapter.readRanges.contains { $0 == nil })
        #expect(ranges.allSatisfy { ($0.validatedLength ?? .max) <= 4 * 1024 * 1024 })
        if assertHighRangeCoverage {
            #expect(ranges.contains { $0.upperBound >= Int64(bytes.count / 2) })
        }

        engine.stop()
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: ResourceSourceError.cancelled) {
            _ = try await session.fetchMetadata()
        }
    }

    private func makeLargeMP3() throws -> Data {
        // A 0.25-second CBR MP3 frame block without ID3/Xing metadata. Repeating
        // complete MPEG frames creates a deterministic media stream large enough
        // to force AVFoundation to request more than one remote region.
        let encodedBlock = "//sQxAAABHQTVVSQgDCmCa83GiACAAGtOUAAAVk6PVBQCAYJAfB8HwfKAgCAYRB8H9QIOxOH+INwBJP2wGA4HA4AAAAAACiJKpkUZAjpAkgWo/eFAfATG/AilC+oGhL8JA0qAAAA4An/+xLEAoKFHB0vvdAAIJuDpXWO4EyAAADguCBABSUEYDGw+EmlhTmJQTmCgEgkAiyQKAJr3d3/r9QAEsAFO1hCWZGGGIwm6XJm44wmGQIGkZd9CQFTsTsH/7////9N36Yw0OMOHTHTgz7/+xDEBIIFBB8YDfsiQLKDpGmfZEyDMK8b41DOHDTrG0MJ4G01zAIGbqh1fmsGyaWhz9f0AFRQGAA/iRZiCG/OYNAVhmcruGZIFcYNYF5xLGMUYY5hPIOS8E/7M/+3//+qAAAAwAFgAP/7EsQDggVYHyes+4IgowOm9G5sDgCgKCYGDmPIYGAU5jxren1FGYrDiRLOkAJgEDKXTvdX//IfqLogEDbAFhDlqAGCQybQuZ5YyECCm7W3YZG5eBSGfs/3f6fuwx+fTGjaMLEDDB8xk//7EMQDgAUAHxgN+yJAq4Ondc2whsM4iTCfHSNKTrQ0hRyDCMB1M1QDCnCgd3JsAs2nQ5+n6AQAE7gJaIgBynZwgHMAAo07CjmAoOAwGCQSwUAg+K35D+p2xStVn+rfu9MwoRMNHjFj//sSxAOABPwfGA37IkB/A6i0HTAW0zWMMJQd00b++zROHTMIUHgyGQcUcRp46ALJfs8G/0/YCASxwAMBQAII2zhL843UJDskA+SyQHYJuYD//2///PoCADI0eFFwAAAYK0pBCMgBkWIA//sQxAmABJwdReHvIHCRA2e0zbBOwn9ZFAr9M5abaMwMkUTs9T/eAAAhcAKBGAOfMAPgQCONzDiAJEcDhIJYoBA/u3//Uz//ZT/01QoAA/rhLxEYjAAQzKWwznkECgDcYGdVdzbWegj/+xLEDgBDXB8yrHdiIHqDaPQdPBYIu/4AYQS93FhzeVw7u2gmZb2BFnOcOX16//6UtqUABAgaUCAAAPmFFCyiEOGTs8c04pisp5Ys/sC3/Hcz//9jHQwWZoQcVaYXgYBqpsvGpgGEYXr/+xDEGwDENB07p/NCMI8D44GvaE0HpxFRlDxizphogMCP/ULKMECzAxgwg3MbgDBeG5Mwve0y9BsTBNByGHSZIBenW0EVNBnjP6AAAYo5NYHLdt5woCGFFR+mie+nmPhqEZe8BA5adv/7EsQhgES4HxoN+yJg9w3nNrZgBVbgNcsfomTT1jCCDgAIy09iHIABDnkyabH34x7tiY/gigAALBIIxYKBAGAAAAAGCgFDLv+DlmtY7/zHlNRCQ03+FKB5GSeFxCei4r4Ose4kBfrr8f/7EMQZgAiMg1W5loAQAAA0g4AABBoT0aCoef/mhqXjExOfLmlC1UxBTUUzLjEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        let block = try #require(Data(base64Encoded: encodedBlock))
        let targetSize = 5 * 1024 * 1024
        let repetitions = targetSize / block.count + 2
        var data = Data()
        data.reserveCapacity(repetitions * block.count)
        for _ in 0..<repetitions {
            data.append(block)
        }
        return data
    }
}

@Suite("查看器解析与文本载荷")
struct ViewerResolutionTests {
    @Test("TXT 解析使用 typed 文本证据和显式预算")
    func resolvesTextContent() {
        let item = makeItem(path: "/notes/readme.txt", kind: .unknown)
        let metadata = ResourceMetadata(
            mimeType: "text/plain",
            typeIdentifier: UTType.plainText.identifier
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .textReader)
        #expect(resolution.preparation == .text(maximumBytes: 10 * 1024 * 1024))
        #expect(resolution.fallbackDescription == nil)
    }

    @Test("PDF 解析保留 PDFKit 预算")
    func resolvesPDFContent() {
        let item = makeItem(path: "/manual.pdf", kind: .unknown)
        let metadata = ResourceMetadata(
            mimeType: "application/pdf",
            typeIdentifier: UTType.pdf.identifier
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .pdfReader)
        #expect(resolution.preparation == .pdf(maximumBytes: 50 * 1024 * 1024))
    }

    @Test("图片解析使用显式预算并拒绝非图片字节")
    func resolvesImageContent() {
        let item = makeItem(path: "/photo.jpg", kind: .unknown)
        let metadata = ResourceMetadata(
            mimeType: "image/jpeg",
            typeIdentifier: UTType.jpeg.identifier
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .imageViewer)
        #expect(resolution.preparation == .image(maximumBytes: 50 * 1024 * 1024))
        let imageData = UIImage(systemName: "photo")!.pngData()!
        #expect(ViewerContentDecoder.isValidImageData(imageData))
        #expect(!ViewerContentDecoder.isValidImageData(Data("not an image".utf8)))
    }

    @Test("音乐解析使用显式预算")
    func resolvesAudioContent() {
        let item = makeItem(path: "/demo.wav", kind: .audio)
        let metadata = ResourceMetadata(
            mimeType: "audio/wav",
            typeIdentifier: "com.microsoft.waveform-audio"
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .musicPlayer)
        #expect(resolution.preparation == .audio(maximumBytes: 50 * 1024 * 1024))
    }

    @Test("视频解析使用显式预算")
    func resolvesVideoContent() {
        let item = makeItem(path: "/demo.mp4", kind: .video)
        let metadata = ResourceMetadata(
            mimeType: "video/mp4",
            typeIdentifier: UTType.mpeg4Movie.identifier
        )

        let resolution = ViewerRegistry.resolve(resource: item, metadata: metadata)

        #expect(resolution.kind == .videoPlayer)
        #expect(resolution.preparation == .video(maximumBytes: 50 * 1024 * 1024))
    }

    @Test("Markdown 与通用文本证据兼容，但真正冲突降级")
    func resolvesMarkdownAndRejectsConflict() {
        let markdown = makeItem(path: "/notes/readme.md", kind: .unknown)
        let markdownResolution = ViewerRegistry.resolve(
            resource: markdown,
            metadata: ResourceMetadata(
                mimeType: "text/markdown",
                typeIdentifier: UTType.plainText.identifier
            )
        )
        #expect(markdownResolution.kind == .markdownReader)
        #expect(markdownResolution.preparation == .text(maximumBytes: 10 * 1024 * 1024))

        let conflict = makeItem(path: "/notes/readme.pdf", kind: .pdf)
        let conflictResolution = ViewerRegistry.resolve(
            resource: conflict,
            metadata: ResourceMetadata(
                mimeType: "text/plain",
                typeIdentifier: UTType.plainText.identifier
            )
        )
        #expect(conflictResolution.kind == .systemPreview)
        #expect(conflictResolution.fallbackDescription?.contains("扩展名") == true)
    }

    @Test("同步文本解码保持现有 UTF-8 与无 BOM UTF-16 结果")
    func decodesTextPayloads() {
        #expect(ViewerContentDecoder.decodeText(Data("你好".utf8)) == "你好")
        let utf16 = "hello".data(using: .utf16LittleEndian)!
        #expect(ViewerContentDecoder.decodeText(utf16) == "hello")
    }

    @Test("全文解码支持 UTF-8、UTF-16 与 UTF-32 BOM")
    @MainActor
    func decodesBOMTextAcrossConcurrentBoundary() async throws {
        var utf8 = Data([0xEF, 0xBB, 0xBF])
        utf8.append(Data("你好 UTF-8".utf8))

        var utf16LittleEndian = Data([0xFF, 0xFE])
        utf16LittleEndian.append("你好 UTF-16 LE".data(using: .utf16LittleEndian)!)

        var utf16BigEndian = Data([0xFE, 0xFF])
        utf16BigEndian.append("你好 UTF-16 BE".data(using: .utf16BigEndian)!)

        let utf32LittleEndian = Data([
            0xFF, 0xFE, 0x00, 0x00,
            0x48, 0x00, 0x00, 0x00,
            0x69, 0x00, 0x00, 0x00
        ])
        let utf32BigEndian = Data([
            0x00, 0x00, 0xFE, 0xFF,
            0x00, 0x00, 0x00, 0x48,
            0x00, 0x00, 0x00, 0x69
        ])

        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(utf8)
                == "你好 UTF-8"
        )
        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(utf16LittleEndian)
                == "你好 UTF-16 LE"
        )
        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(utf16BigEndian)
                == "你好 UTF-16 BE"
        )
        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(utf32LittleEndian)
                == "Hi"
        )
        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(utf32BigEndian)
                == "Hi"
        )
    }

    @Test("全文解码确定识别无 BOM UTF-16 字节序")
    func decodesUTF16WithoutBOM() async throws {
        let littleEndian = "plain UTF-16 LE".data(using: .utf16LittleEndian)!
        let bigEndian = "plain UTF-16 BE".data(using: .utf16BigEndian)!

        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(littleEndian)
                == "plain UTF-16 LE"
        )
        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(bigEndian)
                == "plain UTF-16 BE"
        )
    }

    @Test("全文解码保留 ISO Latin-1 与 Windows CP1252 兼容")
    func decodesLegacyWesternText() async throws {
        let latin1 = Data([
            0x43, 0x72, 0xE8, 0x6D, 0x65, 0x20, 0x62, 0x72, 0xFB, 0x6C, 0xE9, 0x65
        ])
        let windows1252 = Data([
            0x93, 0x71, 0x75, 0x6F, 0x74, 0x65, 0x94, 0x20, 0x80
        ])

        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(latin1)
                == "Crème brûlée"
        )
        #expect(
            try await ViewerContentDecoder.decodeTextOffMainActor(windows1252)
                == "“quote” €"
        )
    }

    @Test("全文解码拒绝截断与非法编码")
    func rejectsTruncatedAndInvalidTextEncoding() async {
        let invalidPayloads = [
            Data([0xEF, 0xBB, 0xBF, 0xF0, 0x9F, 0x92]),
            Data([0xEF, 0xBB, 0xBF, 0xC3, 0x28]),
            Data([0xFF, 0xFE, 0x61]),
            Data([0x00, 0x00, 0xFE, 0xFF, 0x00])
        ]

        for payload in invalidPayloads {
            await #expect(throws: ResourceSourceError.invalidResponse) {
                try await ViewerContentDecoder.decodeTextOffMainActor(payload)
            }
        }
    }

    @Test("全文解码拒绝控制字节与二进制签名")
    func rejectsBinaryPayloads() async {
        let binaryPayloads = [
            Data([0x00, 0x01, 0x02, 0x03]),
            Data([0x7F]),
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])
        ]

        for payload in binaryPayloads {
            await #expect(throws: ResourceSourceError.invalidResponse) {
                try await ViewerContentDecoder.decodeTextOffMainActor(payload)
            }
        }
    }

    private func makeItem(path: String, kind: ResourceKind) -> ResourceItem {
        ResourceItem(
            sourceID: UUID(),
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .blue
        )
    }
}

@Suite("最近资源记录")
@MainActor
struct RecentResourceStoreTests {
    @Test("按稳定身份去重并在重启后恢复最新 metadata")
    func persistsAndDeduplicates() {
        let suiteName = "iosRemoteFolder.recent-resource-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceID = UUID()
        let path = ResourcePath(rawValue: "/notes/guide.txt")!
        let first = ResourceItem(
            sourceID: sourceID,
            logicalPath: path,
            name: "guide.txt",
            kind: .text,
            metadata: ResourceMetadata(byteSize: 10, mimeType: "text/plain"),
            capabilities: [.read],
            accent: .blue
        )
        let updated = ResourceItem(
            sourceID: sourceID,
            logicalPath: path,
            name: "guide.txt",
            kind: .text,
            metadata: ResourceMetadata(byteSize: 99, mimeType: "text/plain"),
            capabilities: [.read],
            accent: .blue
        )

        let store = RecentResourceStore(defaults: defaults)
        store.record(first)
        store.record(updated)

        #expect(store.items.count == 1)
        #expect(store.items.first?.id == first.id)
        #expect(store.items.first?.metadata.byteSize == 99)

        let restored = RecentResourceStore(defaults: defaults)
        #expect(restored.items.count == 1)
        #expect(restored.items.first?.id == first.id)
        #expect(restored.items.first?.metadata.byteSize == 99)
        let payloadText = String(
            data: defaults.data(forKey: "recentResources.v1")!,
            encoding: .utf8
        )!
        #expect(!payloadText.contains("http://"))
        #expect(!payloadText.contains("headers"))
    }

    @Test("限制数量并在来源移除后过滤记录")
    func limitsAndPrunesBySource() {
        let suiteName = "iosRemoteFolder.recent-resource-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceID = UUID()
        let store = RecentResourceStore(defaults: defaults)
        for index in 0..<21 {
            let path = ResourcePath(rawValue: "/recent-\(index).txt")!
            store.record(
                ResourceItem(
                    sourceID: sourceID,
                    logicalPath: path,
                    name: "recent-\(index).txt",
                    kind: .text,
                    metadata: ResourceMetadata(byteSize: Int64(index)),
                    capabilities: [.read],
                    accent: .blue
                )
            )
        }

        #expect(store.items.count == 20)
        #expect(store.items.first?.path == "/recent-20.txt")
        #expect(store.items.last?.path == "/recent-1.txt")

        store.remove(sourceID: sourceID)
        #expect(store.items.isEmpty)
        #expect(RecentResourceStore(defaults: defaults).items.isEmpty)
    }

    @Test("单条删除按完整身份隔离并允许再次记录")
    func removesOneIdentityAndAllowsRecordingAgain() {
        let suiteName = "iosRemoteFolder.recent-resource-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstSourceID = UUID()
        let secondSourceID = UUID()
        let sharedPath = ResourcePath(rawValue: "/notes/guide.txt")!
        let first = ResourceItem(
            sourceID: firstSourceID,
            logicalPath: sharedPath,
            name: "first-guide.txt",
            kind: .text,
            metadata: ResourceMetadata(byteSize: 10, mimeType: "text/plain"),
            capabilities: [.read],
            accent: .blue
        )
        let second = ResourceItem(
            sourceID: secondSourceID,
            logicalPath: sharedPath,
            name: "second-guide.txt",
            kind: .text,
            metadata: ResourceMetadata(byteSize: 20, mimeType: "text/plain"),
            capabilities: [.read],
            accent: .teal
        )

        let store = RecentResourceStore(defaults: defaults)
        store.record(first)
        store.record(second)
        store.remove(identity: first.id)
        store.remove(identity: first.id)

        #expect(store.items.map(\.id) == [second.id])
        #expect(RecentResourceStore(defaults: defaults).items.map(\.id) == [second.id])

        store.record(first)
        #expect(store.items.map(\.id) == [first.id, second.id])
        #expect(RecentResourceStore(defaults: defaults).items.map(\.id) == [first.id, second.id])
    }
}

@Suite("媒体播放位置")
@MainActor
struct ResourceProgressStoreTests {
    @Test("已知 revision 的位置可持久化并恢复")
    func persistsAndRestoresKnownRevision() {
        let suiteName = "iosRemoteFolder.resource-progress-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceID = UUID()
        let resource = makeResource(sourceID: sourceID, path: "/media/demo.mp3")
        let revision = ResourceRevision.modifiedAndSize(
            modifiedAt: Date(timeIntervalSince1970: 1_786_003_200),
            byteSize: 4096
        )
        let metadata = ResourceMetadata(
            byteSize: 4096,
            mimeType: "audio/mpeg",
            revision: revision
        )

        let store = ResourceProgressStore(defaults: defaults)
        store.record(.seconds(12.5), for: resource, metadata: metadata)

        #expect(store.count == 1)
        #expect(store.position(for: resource, metadata: metadata) == .seconds(12.5))
        #expect(ResourceProgressStore(defaults: defaults).position(for: resource, metadata: metadata) == .seconds(12.5))

        let payloadText = String(
            data: defaults.data(forKey: "resourceResume.v1")!,
            encoding: .utf8
        )!
        #expect(!payloadText.contains("http://"))
        #expect(!payloadText.contains("headers"))
        #expect(!payloadText.contains("Cookie"))
    }

    @Test("unknown 或变化的 revision 不恢复旧位置")
    func rejectsUnknownAndChangedRevision() {
        let suiteName = "iosRemoteFolder.resource-progress-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resource = makeResource(sourceID: UUID(), path: "/media/demo.mp4", kind: .video)
        let firstMetadata = ResourceMetadata(
            byteSize: 2048,
            revision: .etag("\"first\"")
        )
        let changedMetadata = ResourceMetadata(
            byteSize: 2048,
            revision: .etag("\"changed\"")
        )
        let unknownMetadata = ResourceMetadata(byteSize: 2048, revision: .unknown)
        let store = ResourceProgressStore(defaults: defaults)

        store.record(.seconds(4), for: resource, metadata: firstMetadata)
        #expect(store.position(for: resource, metadata: changedMetadata) == nil)
        #expect(store.count == 0)

        store.record(.seconds(4), for: resource, metadata: firstMetadata)
        #expect(store.position(for: resource, metadata: unknownMetadata) == nil)
        #expect(store.count == 0)

        store.record(.seconds(-1), for: resource, metadata: firstMetadata)
        store.record(.seconds(.nan), for: resource, metadata: firstMetadata)
        store.record(.seconds(.infinity), for: resource, metadata: firstMetadata)
        #expect(store.count == 0)
    }

    @Test("来源移除后清理位置")
    func prunesRemovedSources() {
        let suiteName = "iosRemoteFolder.resource-progress-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let retainedSource = UUID()
        let removedSource = UUID()
        let metadata = ResourceMetadata(
            byteSize: 1024,
            revision: .serverVersion("v1")
        )
        let store = ResourceProgressStore(defaults: defaults)
        store.record(
            .seconds(1),
            for: makeResource(sourceID: retainedSource, path: "/keep.mp3"),
            metadata: metadata
        )
        store.record(
            .seconds(2),
            for: makeResource(sourceID: removedSource, path: "/remove.mp4", kind: .video),
            metadata: metadata
        )

        store.remove(sourceID: removedSource)
        #expect(store.count == 1)
    }

    private func makeResource(
        sourceID: UUID,
        path: String,
        kind: ResourceKind = .audio
    ) -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(byteSize: 1),
            capabilities: [.read],
            accent: .blue
        )
    }
}

@Suite("文档阅读位置")
@MainActor
struct ResourceReadingStoreTests {
    @Test("PDF 页码与文本比例按身份和 revision 持久化恢复")
    func persistsAndRestoresDocumentPositions() {
        let suiteName = "iosRemoteFolder.resource-reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceID = UUID()
        let revision = ResourceRevision.modifiedAndSize(
            modifiedAt: Date(timeIntervalSince1970: 1_786_003_200),
            byteSize: 4096
        )
        let metadata = ResourceMetadata(byteSize: 4096, revision: revision)
        let pdf = makeResource(sourceID: sourceID, path: "/docs/guide.pdf", kind: .pdf)
        let text = makeResource(sourceID: sourceID, path: "/docs/notes.txt", kind: .text)
        let store = ResourceReadingStore(defaults: defaults)

        store.record(.pdf(pageIndex: 3), for: pdf, metadata: metadata)
        store.record(.text(fraction: 0.65), for: text, metadata: metadata)

        #expect(store.position(for: pdf, metadata: metadata) == .pdf(pageIndex: 3))
        #expect(store.position(for: text, metadata: metadata) == .text(fraction: 0.65))

        let restored = ResourceReadingStore(defaults: defaults)
        #expect(restored.position(for: pdf, metadata: metadata) == .pdf(pageIndex: 3))
        #expect(restored.position(for: text, metadata: metadata) == .text(fraction: 0.65))

        let payloadText = String(
            data: defaults.data(forKey: "resourceReading.v1")!,
            encoding: .utf8
        )!
        #expect(!payloadText.contains("http://"))
        #expect(!payloadText.contains("headers"))
        #expect(!payloadText.contains("Cookie"))
    }

    @Test("unknown 或变化的 revision 清理旧文档位置")
    func rejectsUnknownAndChangedRevision() {
        let suiteName = "iosRemoteFolder.resource-reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resource = makeResource(sourceID: UUID(), path: "/docs/notes.md", kind: .markdown)
        let first = ResourceMetadata(revision: .etag("\"first\""))
        let changed = ResourceMetadata(revision: .etag("\"changed\""))
        let unknown = ResourceMetadata(revision: .unknown)
        let store = ResourceReadingStore(defaults: defaults)

        store.record(.text(fraction: 0.4), for: resource, metadata: first)
        #expect(store.position(for: resource, metadata: changed) == nil)
        #expect(store.count == 0)

        store.record(.text(fraction: 0.4), for: resource, metadata: first)
        #expect(store.position(for: resource, metadata: unknown) == nil)
        #expect(store.count == 0)
    }

    @Test("非法位置、类型冲突和移除来源不会留下记录")
    func validatesPositionsAndPrunesSources() {
        let suiteName = "iosRemoteFolder.resource-reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let retainedSource = UUID()
        let removedSource = UUID()
        let metadata = ResourceMetadata(revision: .serverVersion("v1"))
        let pdf = makeResource(sourceID: retainedSource, path: "/docs/guide.pdf", kind: .pdf)
        let text = makeResource(sourceID: removedSource, path: "/docs/notes.txt", kind: .text)
        let store = ResourceReadingStore(defaults: defaults)

        store.record(.pdf(pageIndex: -1), for: pdf, metadata: metadata)
        store.record(.text(fraction: .nan), for: text, metadata: metadata)
        store.record(.pdf(pageIndex: 2), for: text, metadata: metadata)
        #expect(store.count == 0)

        store.record(.pdf(pageIndex: 2), for: pdf, metadata: metadata)
        store.record(.text(fraction: 0.2), for: text, metadata: metadata)
        #expect(store.count == 2)

        store.remove(sourceID: removedSource)
        #expect(store.count == 1)
        #expect(store.position(for: pdf, metadata: metadata) == .pdf(pageIndex: 2))
        #expect(store.position(for: text, metadata: metadata) == nil)
    }

    private func makeResource(
        sourceID: UUID,
        path: String,
        kind: ResourceKind
    ) -> ResourceItem {
        ResourceItem(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: path)!,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadata: ResourceMetadata(),
            capabilities: [.read],
            accent: .blue
        )
    }
}

@Suite("内容缓存")
struct CacheCoordinatorTests {
    @Test("来源不可用时缓存内容仍可经离线会话读取")
    func readsCachedContentWithoutSourceAdapter() async throws {
        let source = ResourceSource(
            id: UUID(),
            name: "离线会话来源",
            kind: .http,
            endpoint: "https://offline.example",
            status: .disconnected,
            itemCountDescription: ""
        )
        let modifiedAt = Date(timeIntervalSince1970: 1_754_700_000)
        let metadata = ResourceMetadata(
            byteSize: 5,
            modifiedAt: modifiedAt,
            mimeType: "text/plain",
            typeIdentifier: "public.plain-text",
            revision: .modifiedAndSize(modifiedAt: modifiedAt, byteSize: 5)
        )
        let item = ResourceItem(
            sourceID: source.id,
            logicalPath: ResourcePath(rawValue: "/offline.txt")!,
            name: "offline.txt",
            kind: .text,
            metadata: metadata,
            capabilities: [],
            accent: .blue
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = CacheCoordinator(rootURL: root)
        let key = ResourceCacheKey(
            identity: item.id,
            revision: metadata.revision,
            variant: .content
        )!
        try await cache.store(
            Data("hello".utf8),
            for: key,
            maximumBytes: 1024
        )

        let registry = try SourceRegistry(sources: [source], adapters: [])
        let service = ResourceAccessService(
            registry: registry,
            cacheCoordinator: cache
        )
        let session = try await service.makeOfflineSession(for: item)
        #expect(try await session.fetchMetadata() == metadata)
        #expect(try await session.readData(maximumBytes: 1024) == Data("hello".utf8))
        await session.close()
    }

    @Test("已知 revision 的内容可持久化并在新 coordinator 中恢复")
    func persistsAndRestoresContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceID = UUID()
        let key = ResourceCacheKey(
            identity: makeIdentity(sourceID: sourceID, path: "/docs/guide.pdf"),
            revision: .etag("\"v1\""),
            variant: .content
        )!
        let data = Data("cached content".utf8)
        let cache = CacheCoordinator(rootURL: root)

        #expect(try await cache.store(data, for: key, maximumBytes: 1024))
        #expect(await cache.state(for: key) == .offlineAvailable)
        #expect(try await cache.data(for: key, maximumBytes: 1024) == data)

        let manifestURL = root
            .appendingPathComponent("iosRemoteFolder/content/manifest.json")
        let manifestText = String(
            data: try Data(contentsOf: manifestURL),
            encoding: .utf8
        )!
        #expect(!manifestText.contains("http://"))
        #expect(!manifestText.contains("headers"))
        #expect(!manifestText.contains("Cookie"))

        let restored = CacheCoordinator(rootURL: root)
        #expect(try await restored.data(for: key, maximumBytes: 1024) == data)
        #expect(await restored.state(for: key) == .offlineAvailable)
    }

    @Test("revision、variant 和未知 revision 彼此隔离")
    func isolatesRevisionAndVariant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let identity = makeIdentity(sourceID: UUID(), path: "/docs/guide.pdf")
        let first = ResourceCacheKey(
            identity: identity,
            revision: .etag("\"first\""),
            variant: .content
        )!
        let changed = ResourceCacheKey(
            identity: identity,
            revision: .etag("\"changed\""),
            variant: .content
        )!
        let preview = ResourceCacheKey(
            identity: identity,
            revision: .etag("\"first\""),
            variant: .preview
        )!
        let cache = CacheCoordinator(rootURL: root)

        try await cache.store(Data("first".utf8), for: first, maximumBytes: 1024)
        try await cache.store(Data("changed".utf8), for: changed, maximumBytes: 1024)
        try await cache.store(Data("preview".utf8), for: preview, maximumBytes: 1024)

        #expect(try await cache.data(for: first, maximumBytes: 1024) == Data("first".utf8))
        #expect(try await cache.data(for: changed, maximumBytes: 1024) == Data("changed".utf8))
        #expect(try await cache.data(for: preview, maximumBytes: 1024) == Data("preview".utf8))
        #expect(ResourceCacheKey(
            identity: identity,
            revision: .unknown,
            variant: .content
        ) == nil)
    }

    @Test("超预算读取回源，来源移除清理持久内容")
    func enforcesBudgetAndPrunesSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosRemoteFolder-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let retainedSource = UUID()
        let removedSource = UUID()
        let retained = ResourceCacheKey(
            identity: makeIdentity(sourceID: retainedSource, path: "/keep.txt"),
            revision: .serverVersion("v1"),
            variant: .content
        )!
        let removed = ResourceCacheKey(
            identity: makeIdentity(sourceID: removedSource, path: "/remove.txt"),
            revision: .serverVersion("v1"),
            variant: .content
        )!
        let cache = CacheCoordinator(rootURL: root)

        try await cache.store(Data("12345".utf8), for: retained, maximumBytes: 1024)
        try await cache.store(Data("removed".utf8), for: removed, maximumBytes: 1024)
        #expect(try await cache.data(for: retained, maximumBytes: 4) == nil)
        #expect(await cache.state(for: retained) == .online)

        try await cache.store(Data("12345".utf8), for: retained, maximumBytes: 1024)
        await cache.remove(sourceID: removedSource)
        #expect(try await cache.data(for: retained, maximumBytes: 1024) == Data("12345".utf8))
        #expect(try await cache.data(for: removed, maximumBytes: 1024) == nil)

        let restored = CacheCoordinator(rootURL: root)
        #expect(try await restored.data(for: removed, maximumBytes: 1024) == nil)
    }

    private func makeIdentity(sourceID: UUID, path: String) -> ResourceIdentity {
        ResourceIdentity(
            sourceID: sourceID,
            logicalPath: ResourcePath(rawValue: path)!
        )
    }
}

@Suite("演示来源文档内容")
struct SampleSourceContentTests {
    @Test("演示来源根目录与子目录只列举直接子项")
    func listsOnlyDirectChildrenAtEveryDepth() async throws {
        let source = try #require(
            SampleData.sources.first { $0.id == SampleData.personalSourceID }
        )
        let adapter = SampleSourceAdapter(source: source)

        let rootItems = try await adapter.listResources(at: .root)
        #expect(Set(rootItems.map(\.path)) == Set(["/知识库", "/视频"]))
        #expect(rootItems.allSatisfy { $0.kind == .folder && $0.metadata.isDirectory })
        #expect(rootItems.allSatisfy { ResourcePath(rawValue: $0.path)?.parent == .root })

        let knowledgePath = try #require(ResourcePath(rawValue: "/知识库"))
        let knowledgeItems = try await adapter.listResources(at: knowledgePath)
        #expect(knowledgeItems.map(\.path) == ["/知识库/设计"])
        #expect(knowledgeItems.first?.kind == .folder)
        #expect(knowledgeItems.allSatisfy {
            ResourcePath(rawValue: $0.path)?.parent == knowledgePath
        })

        let designPath = try #require(ResourcePath(rawValue: "/知识库/设计"))
        let designItems = try await adapter.listResources(at: designPath)
        #expect(designItems.map(\.path) == ["/知识库/设计/设计系统与组件规范.pdf"])
        #expect(designItems.first?.kind == .pdf)
        #expect(designItems.allSatisfy {
            ResourcePath(rawValue: $0.path)?.parent == designPath
        })
    }

    @Test("演示来源经内容会话返回真实 Markdown 与 PDF 字节")
    func readsDemoDocumentsThroughSession() async throws {
        let markdownSource = SampleData.sources.first { $0.id == SampleData.workSourceID }!
        let markdownItem = SampleData.resources.first { $0.path == "/产品/路线图.md" }!
        let markdownAdapter = SampleSourceAdapter(source: markdownSource)
        let markdownRegistry = try SourceRegistry(
            sources: [markdownSource],
            adapters: [markdownAdapter]
        )
        let markdownSession = try await ResourceAccessService(registry: markdownRegistry)
            .makeSession(for: markdownItem)
        let markdownData = try await markdownSession.readData(maximumBytes: 10 * 1024 * 1024)
        #expect(String(decoding: markdownData, as: UTF8.self).contains("产品路线图"))

        let pdfSource = SampleData.sources.first { $0.id == SampleData.personalSourceID }!
        let pdfItem = SampleData.resources.first { $0.path.hasSuffix("设计系统与组件规范.pdf") }!
        let pdfAdapter = SampleSourceAdapter(source: pdfSource)
        let pdfRegistry = try SourceRegistry(sources: [pdfSource], adapters: [pdfAdapter])
        let pdfSession = try await ResourceAccessService(registry: pdfRegistry)
            .makeSession(for: pdfItem)
        let pdfData = try await pdfSession.readData(maximumBytes: 50 * 1024 * 1024)
        #expect(pdfData.starts(with: Data("%PDF-1.4".utf8)))
        #expect(PDFDocument(data: pdfData) != nil)
    }

    @Test("演示来源经内容会话返回可解码图片字节")
    func readsDemoImageThroughSession() async throws {
        let imageSource = SampleData.sources.first { $0.id == SampleData.workSourceID }!
        let imageItem = SampleData.resources.first { $0.path == "/产品/路线图封面.png" }!
        let adapter = SampleSourceAdapter(source: imageSource)
        let registry = try SourceRegistry(sources: [imageSource], adapters: [adapter])
        let session = try await ResourceAccessService(registry: registry)
            .makeSession(for: imageItem)
        let imageData = try await session.readData(maximumBytes: 50 * 1024 * 1024)

        #expect(UIImage(data: imageData) != nil)
    }

    @Test("演示来源经内容会话返回可播放音频字节")
    func readsDemoAudioThroughSession() async throws {
        let audioSource = SampleData.sources.first { $0.id == SampleData.workSourceID }!
        let audioItem = SampleData.resources.first { $0.path == "/产品/路线图演示.wav" }!
        let adapter = SampleSourceAdapter(source: audioSource)
        let registry = try SourceRegistry(sources: [audioSource], adapters: [adapter])
        let session = try await ResourceAccessService(registry: registry)
            .makeSession(for: audioItem)
        let audioData = try await session.readData(maximumBytes: 50 * 1024 * 1024)

        #expect(ViewerContentDecoder.isValidAudioData(audioData))
        #expect((try? AVAudioPlayer(data: audioData)) != nil)
    }

    @Test("演示来源经内容会话返回可加载视频字节")
    func readsDemoVideoThroughSession() async throws {
        let videoSource = SampleData.sources.first { $0.id == SampleData.workSourceID }!
        let videoItem = SampleData.resources.first { $0.path == "/产品/路线图演示.mp4" }!
        let adapter = SampleSourceAdapter(source: videoSource)
        let registry = try SourceRegistry(sources: [videoSource], adapters: [adapter])
        let session = try await ResourceAccessService(registry: registry)
            .makeSession(for: videoItem)
        let videoData = try await session.readData(maximumBytes: 50 * 1024 * 1024)

        #expect(videoData.count == 2_268)
        #expect(await ViewerContentDecoder.isValidVideoData(videoData))
    }
}
