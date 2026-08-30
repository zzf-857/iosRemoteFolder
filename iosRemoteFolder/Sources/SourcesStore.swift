import Foundation
import Observation
import os

private enum SourcesStoreSignposts {
    enum Outcome {
        case success
        case failure
        case cancelled
    }

    private static let signposter = OSSignposter(
        subsystem: "com.zzf857.iosRemoteFolder",
        category: "DirectoryLoading"
    )

    static func beginDirectoryList() -> OSSignpostIntervalState {
        signposter.beginInterval("DirectoryList")
    }

    static func endDirectoryList(
        _ state: OSSignpostIntervalState,
        outcome: Outcome
    ) {
        switch outcome {
        case .success:
            signposter.endInterval("DirectoryList", state, "outcome=success")
        case .failure:
            signposter.endInterval("DirectoryList", state, "outcome=failure")
        case .cancelled:
            signposter.endInterval("DirectoryList", state, "outcome=cancelled")
        }
    }

    static func outcome(for error: any Error) -> Outcome {
        let mapped = ResourceSourceError.mapping(error)
        return Task.isCancelled || error is CancellationError || mapped == .cancelled
            ? .cancelled
            : .failure
    }
}

/// 来源连接状态仓库：通过注入的 registry 驱动连接与重试，并向 UI 报告状态。
///
/// 架构边界：UI 只依赖本仓库暴露的 `entries` 与 `connect` 等方法，
/// 不直接调用 URLSession 或 FileManager；adapter 抛出的错误统一映射为
/// `ResourceSourceError` 后进入 `ResourceSourceState.failed`。
///
/// 双状态规则（D-026）：`ResourceSourceState` 是本仓库唯一事实源；
/// `ResourceSource.SourceStatus` 只是兼容旧展示的派生投影，只能由本仓库
/// 通过 `transition` 单向写入，adapter 与 UI 都不允许独立维护第三套状态。
///
/// 浏览状态（D-024）：每个来源除连接状态外，还维护当前目录路径、当前目录资源、
/// 加载中、空目录与可行动错误；连接成功后列举根目录并写入真实资源列表，
/// 而不是只写资源数量。仓库由 `AppModel` 持有，Sources 与 Browse 共享同一份。
@MainActor
@Observable
final class SourcesStore {
    struct DirectorySnapshotPolicy: Hashable, Sendable {
        static let standard = DirectorySnapshotPolicy(
            timeToLive: .seconds(30),
            maximumDirectoriesPerSource: 20,
            maximumEstimatedBytes: 8 * 1_024 * 1_024
        )

        let timeToLive: Duration
        let maximumDirectoriesPerSource: Int
        let maximumEstimatedBytes: Int

        init(
            timeToLive: Duration,
            maximumDirectoriesPerSource: Int,
            maximumEstimatedBytes: Int
        ) {
            self.timeToLive = max(timeToLive, .zero)
            self.maximumDirectoriesPerSource = max(maximumDirectoriesPerSource, 0)
            self.maximumEstimatedBytes = max(maximumEstimatedBytes, 0)
        }
    }

    struct Entry: Identifiable {
        var source: ResourceSource
        var state: ResourceSourceState
        var hasAdapter: Bool
        var browse: SourceBrowse

        var id: UUID { source.id }
    }

    /// 单个来源的浏览状态：真实目录列举结果，而非全量递归索引。
    struct SourceBrowse {
        var currentPath: ResourcePath = .root
        var items: [ResourceItem] = []
        var isLoading: Bool = false
        var error: ResourceSourceError?

        /// 已加载且当前目录确实没有任何资源。
        var isEmpty: Bool { !isLoading && error == nil && items.isEmpty }
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private let registry: SourceRegistry
    /// 与 registry 快照中的 adapter 注册版本配对；只用于判断来源替换，
    /// 不携带 adapter 或底层客户端。
    @ObservationIgnored private var adapterRevisions: [UUID: UUID] = [:]
    @ObservationIgnored private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var browseTasks: [UUID: Task<Void, Never>] = [:]
    /// 连接代数：每次发起连接递增；过期任务的任何状态写入都会被忽略，
    /// 保证被取消或被替换的连接任务不会覆盖新状态。
    @ObservationIgnored private var connectionGenerations: [UUID: Int] = [:]
    /// 浏览加载代数：与连接代数同理，避免过期列举覆盖新目录。
    @ObservationIgnored private var browseGenerations: [UUID: Int] = [:]
    @ObservationIgnored private let directorySnapshotPolicy: DirectorySnapshotPolicy
    @ObservationIgnored private let directorySnapshotNow: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var directorySnapshots: [DirectorySnapshotKey: DirectorySnapshot] = [:]
    @ObservationIgnored private var directorySnapshotAccessSequence: UInt64 = 0
    @ObservationIgnored private var directorySnapshotEstimatedBytes = 0
    /// Composition-root hook for indexing successful, current-generation
    /// directory listings. Failure and cancellation paths never invoke it.
    @ObservationIgnored var onDirectorySnapshot: (
        @MainActor (UUID, ResourcePath, [ResourceItem]) async -> Void
    )?

    init(
        registry: SourceRegistry,
        directorySnapshotPolicy: DirectorySnapshotPolicy = .standard,
        directorySnapshotNow: @escaping @MainActor () -> ContinuousClock.Instant = {
            ContinuousClock.now
        }
    ) {
        self.registry = registry
        self.directorySnapshotPolicy = directorySnapshotPolicy
        self.directorySnapshotNow = directorySnapshotNow
        let snapshots = registry.initialSnapshots
        self.adapterRevisions = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.id, $0.adapterRevision) }
        )
        self.entries = snapshots.map { snapshot in
            Entry(
                source: snapshot.source,
                state: .disconnected,
                hasAdapter: snapshot.hasAdapter,
                browse: SourceBrowse()
            )
        }
    }

    // MARK: - 动态来源同步

    /// 用 registry 的不可变快照同步来源。新增来源从未连接开始；替换来源会
    /// 取消旧连接/浏览任务、递增代数并清空目录状态；未变化来源保留当前投影。
    /// `failures` 只由 composition root 提供，用于恢复 stale/失效 bookmark 的
    /// 可行动状态，Store 不解析 bookmark，也不持有 adapter。
    func synchronize(
        with snapshots: [SourceRegistrySnapshot],
        failures: [UUID: ResourceSourceError] = [:]
    ) {
        var incomingIDs = Set<UUID>()
        var uniqueSnapshots: [SourceRegistrySnapshot] = []
        uniqueSnapshots.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            guard incomingIDs.insert(snapshot.id).inserted else { continue }
            uniqueSnapshots.append(snapshot)
        }

        let oldEntriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let oldIDs = Set(oldEntriesByID.keys)
        let removedIDs = oldIDs.subtracting(incomingIDs)

        for sourceID in removedIDs {
            cancelWork(for: sourceID)
            removeDirectorySnapshots(for: sourceID)
            connectionGenerations.removeValue(forKey: sourceID)
            browseGenerations.removeValue(forKey: sourceID)
            adapterRevisions.removeValue(forKey: sourceID)
        }

        var nextEntries: [Entry] = []
        nextEntries.reserveCapacity(uniqueSnapshots.count)
        for snapshot in uniqueSnapshots {
            if var existing = oldEntriesByID[snapshot.id],
               Self.sameSourceDescriptor(existing.source, snapshot.source),
               existing.hasAdapter == snapshot.hasAdapter,
               adapterRevisions[snapshot.id] == snapshot.adapterRevision,
               failures[snapshot.id] == nil {
                // Registry 的 source 描述可能带有初始化状态；运行时状态仍只由
                // Store 投影，避免 snapshot 反向写入第二套连接事实。
                existing.source.status = Self.projectedStatus(for: existing.state)
                existing.hasAdapter = snapshot.hasAdapter
                nextEntries.append(existing)
                continue
            }

            if oldEntriesByID[snapshot.id] != nil {
                cancelWork(for: snapshot.id)
                removeDirectorySnapshots(for: snapshot.id)
            }
            adapterRevisions[snapshot.id] = snapshot.adapterRevision
            let state: ResourceSourceState
            if let failure = failures[snapshot.id] {
                state = .failed(failure)
            } else {
                state = .disconnected
            }
            var source = snapshot.source
            source.status = Self.projectedStatus(for: state)
            nextEntries.append(
                Entry(
                    source: source,
                    state: state,
                    hasAdapter: snapshot.hasAdapter,
                    browse: SourceBrowse()
                )
            )
        }
        entries = nextEntries
    }

    /// 便于 composition root 在完成 registry mutation 后显式同步 Store。
    func sync(with snapshots: [SourceRegistrySnapshot], failures: [UUID: ResourceSourceError] = [:]) {
        synchronize(with: snapshots, failures: failures)
    }

    // MARK: - 连接

    /// 连接所有尚未连接且拥有 adapter 的来源；已连接或连接中的来源不重复触发。
    func connectAll() {
        for entry in entries where entry.hasAdapter {
            if case .disconnected = entry.state {
                connect(entry.id)
            }
        }
    }

    /// 连接（或重试）指定来源；重复调用会取消上一次未完成的连接任务。
    ///
    /// 生命周期：开始时同步进入 connecting；成功进入 ready 并写入当前目录（根目录）
    /// 的真实资源列表；失败进入 failed（保留可行动错误）；任务被取消时回到 disconnected，
    /// 不会永久停留在 connecting。
    func connect(_ sourceID: UUID, initialPath: ResourcePath = .root) {
        guard let entry = entry(for: sourceID), entry.hasAdapter else { return }
        connectionTasks[sourceID]?.cancel()
        let generation = nextConnectionGeneration(for: sourceID)
        transition(sourceID, to: .connecting)
        update(sourceID) { entry in
            entry.browse.currentPath = initialPath
            entry.browse.items = []
            entry.browse.isLoading = false
            entry.browse.error = nil
        }
        let registry = self.registry
        let task = Task {
            defer {
                self.finishConnectionTask(sourceID: sourceID, generation: generation)
            }
            do {
                try await registry.connect(sourceID: sourceID)
                let resources = try await Self.measuredDirectoryList(
                    registry: registry,
                    sourceID: sourceID,
                    path: initialPath
                )
                try Task.checkCancellation()
                guard self.isCurrentConnectionGeneration(sourceID, generation) else { return }
                self.transition(sourceID, to: .ready)
                self.update(sourceID) { entry in
                    entry.source.itemCountDescription = "\(resources.count) 个资源"
                    entry.browse.currentPath = initialPath
                    entry.browse.items = resources
                    entry.browse.isLoading = false
                    entry.browse.error = nil
                }
                self.storeDirectorySnapshot(resources, sourceID: sourceID, path: initialPath)
                await self.onDirectorySnapshot?(sourceID, initialPath, resources)
            } catch {
                guard self.isCurrentConnectionGeneration(sourceID, generation) else { return }
                let mapped = ResourceSourceError.mapping(error)
                if Task.isCancelled || error is CancellationError || mapped == .cancelled {
                    // 取消不是失败：回到未连接，保持状态一致且可重新发起。
                    self.transition(sourceID, to: .disconnected)
                } else {
                    self.transition(sourceID, to: .failed(mapped))
                }
                self.update(sourceID) { entry in entry.browse.isLoading = false }
            }
        }
        connectionTasks[sourceID] = task
    }

    /// 失败来源的重试入口。
    func retry(_ sourceID: UUID) {
        let targetPath = entry(for: sourceID)?.browse.currentPath ?? .root
        connect(sourceID, initialPath: targetPath)
    }

    /// 弱网/断网恢复入口：恢复连接级和当前目录级的明确瞬时失败。
    ///
    /// 认证、权限、协议违约等需要用户行动或提示确定性问题的失败不自动重连，
    /// 避免用错误凭证反复请求服务器或掩盖真实问题。连接中和目录加载中的
    /// 来源由各自任务生命周期负责，重复的前台/网络恢复事件不会重启它们。
    func recoverTransientFailures() {
        for entry in entries where entry.hasAdapter {
            switch entry.state {
            case .failed(let error) where error.isAutomaticallyRecoverable:
                retry(entry.id)
            case .ready:
                guard !entry.browse.isLoading,
                      let error = entry.browse.error,
                      error.isAutomaticallyRecoverable else { continue }
                loadDirectory(entry.id, at: entry.browse.currentPath)
            case .disconnected, .connecting, .failed:
                continue
            }
        }
    }

    /// 兼容既有调用方；自动恢复行为统一由 `recoverTransientFailures()` 定义。
    func reconnectFailedSources() {
        recoverTransientFailures()
    }

    /// 仅为尚未连接的来源发起首次按需连接。失败后的再次连接必须走
    /// 显式 retry 或受控的瞬时故障恢复，避免视图生命周期回调暗中重试。
    func ensureConnected(_ sourceID: UUID) {
        guard let entry = entry(for: sourceID), case .disconnected = entry.state else { return }
        connect(sourceID)
    }

    func cancelAllConnections() {
        for sourceID in connectionTasks.keys {
            _ = nextConnectionGeneration(for: sourceID)
        }
        for sourceID in browseTasks.keys {
            _ = nextBrowseGeneration(for: sourceID)
            browseTasks[sourceID]?.cancel()
        }
        connectionTasks.values.forEach { $0.cancel() }
        browseTasks.values.forEach { $0.cancel() }
        connectionTasks.removeAll()
        browseTasks.removeAll()
        // 被取消的连接不允许停留在 connecting：同步回到未连接。
        let connectingIDs = entries.filter { entry in
            if case .connecting = entry.state { return true }
            return false
        }.map(\.id)
        for sourceID in connectingIDs {
            transition(sourceID, to: .disconnected)
        }
        // 被取消/替换的浏览任务必须结束 isLoading，避免过期任务无法覆盖新结果
        // 却又让界面永久停留在加载中；同时清除可能已失效的错误状态。
        for entry in entries {
            update(entry.id) { e in
                e.browse.isLoading = false
                e.browse.error = nil
            }
        }
    }

    // MARK: - 浏览

    /// 列举指定来源的当前目录资源（真实来源闭环）。
    /// 重复调用会取消上一次未完成的列举任务。
    func loadDirectory(_ sourceID: UUID, at path: ResourcePath) {
        guard let entry = entry(for: sourceID), entry.hasAdapter else { return }
        browseTasks[sourceID]?.cancel()
        browseTasks.removeValue(forKey: sourceID)
        let generation = nextBrowseGeneration(for: sourceID)
        let cachedSnapshot = directorySnapshot(sourceID: sourceID, path: path)
        update(sourceID) { entry in
            entry.browse.currentPath = path
            entry.browse.items = cachedSnapshot?.items ?? []
            entry.browse.isLoading = cachedSnapshot?.isFresh != true
            entry.browse.error = nil
        }
        // Fresh snapshots are the requested directory state, so no adapter
        // call or indexing callback is needed. Stale snapshots remain visible
        // while the normal current-generation request refreshes them.
        guard cachedSnapshot?.isFresh != true else { return }
        let registry = self.registry
        let task = Task {
            defer {
                self.finishBrowseTask(sourceID: sourceID, generation: generation)
            }
            do {
                let items = try await Self.measuredDirectoryList(
                    registry: registry,
                    sourceID: sourceID,
                    path: path
                )
                try Task.checkCancellation()
                guard self.isCurrentBrowseGeneration(sourceID, generation) else { return }
                self.update(sourceID) { entry in
                    entry.browse.items = items
                    entry.browse.isLoading = false
                    entry.browse.error = nil
                }
                self.storeDirectorySnapshot(items, sourceID: sourceID, path: path)
                await self.onDirectorySnapshot?(sourceID, path, items)
            } catch {
                guard self.isCurrentBrowseGeneration(sourceID, generation) else { return }
                let mapped = ResourceSourceError.mapping(error)
                if Task.isCancelled || error is CancellationError || mapped == .cancelled {
                    self.update(sourceID) { entry in entry.browse.isLoading = false }
                } else if cachedSnapshot != nil {
                    // A refresh failure must not turn a usable stale snapshot
                    // into a blocking error page. A later navigation can retry.
                    self.update(sourceID) { entry in
                        entry.browse.isLoading = false
                        entry.browse.error = nil
                    }
                } else {
                    self.update(sourceID) { entry in
                        entry.browse.isLoading = false
                        entry.browse.error = mapped
                    }
                }
            }
        }
        browseTasks[sourceID] = task
    }

    /// 列举根目录。
    func loadRoot(_ sourceID: UUID) {
        loadDirectory(sourceID, at: .root)
    }

    /// Opens an indexed directory whether the source is already ready or must
    /// reconnect first. A reconnect lists the requested path as its first
    /// current-generation snapshot instead of flashing the root directory.
    func openDirectory(_ sourceID: UUID, at path: ResourcePath) {
        guard let entry = entry(for: sourceID), entry.hasAdapter else { return }
        if case .ready = entry.state {
            loadDirectory(sourceID, at: path)
        } else {
            connect(sourceID, initialPath: path)
        }
    }

    /// 进入一个文件夹：文件夹的 `path` 即其完整规范化逻辑路径。
    /// 拒绝来源不匹配或身份/路径矛盾的文件夹，避免越界下钻。
    func enter(_ sourceID: UUID, folder: ResourceItem) {
        guard folder.resolvedContentType.kind == .folder,
              folder.sourceID == sourceID,
              folder.id.sourceID == sourceID,
              folder.id.logicalPath == folder.path,
              let path = ResourcePath(rawValue: folder.path) else { return }
        loadDirectory(sourceID, at: path)
    }

    /// 返回上一级目录（根目录时保持在根）。
    func goUp(_ sourceID: UUID) {
        guard let entry = entry(for: sourceID) else { return }
        let parent = entry.browse.currentPath.parent ?? .root
        loadDirectory(sourceID, at: parent)
    }

    // MARK: - Private

    private struct DirectorySnapshotKey: Hashable {
        let sourceID: UUID
        let path: ResourcePath
    }

    private struct DirectorySnapshot {
        let items: [ResourceItem]
        let storedAt: ContinuousClock.Instant
        var lastAccessSequence: UInt64
        let estimatedBytes: Int
    }

    private struct DirectorySnapshotLookup {
        let items: [ResourceItem]
        let isFresh: Bool
    }

    private func directorySnapshot(
        sourceID: UUID,
        path: ResourcePath
    ) -> DirectorySnapshotLookup? {
        let key = DirectorySnapshotKey(sourceID: sourceID, path: path)
        guard var snapshot = directorySnapshots[key] else { return nil }
        snapshot.lastAccessSequence = nextDirectorySnapshotAccessSequence()
        directorySnapshots[key] = snapshot
        let age = snapshot.storedAt.duration(to: directorySnapshotNow())
        return DirectorySnapshotLookup(
            items: snapshot.items,
            isFresh: age >= .zero && age < directorySnapshotPolicy.timeToLive
        )
    }

    private func storeDirectorySnapshot(
        _ items: [ResourceItem],
        sourceID: UUID,
        path: ResourcePath
    ) {
        guard directorySnapshotPolicy.maximumDirectoriesPerSource > 0,
              directorySnapshotPolicy.maximumEstimatedBytes > 0 else {
            removeDirectorySnapshot(sourceID: sourceID, path: path)
            return
        }

        let key = DirectorySnapshotKey(sourceID: sourceID, path: path)
        if let previous = directorySnapshots.removeValue(forKey: key) {
            directorySnapshotEstimatedBytes -= previous.estimatedBytes
        }
        let estimatedBytes = Self.estimatedDirectorySnapshotBytes(path: path, items: items)
        directorySnapshots[key] = DirectorySnapshot(
            items: items,
            storedAt: directorySnapshotNow(),
            lastAccessSequence: nextDirectorySnapshotAccessSequence(),
            estimatedBytes: estimatedBytes
        )
        directorySnapshotEstimatedBytes = Self.saturatingAdd(
            directorySnapshotEstimatedBytes,
            estimatedBytes
        )
        evictDirectorySnapshotsIfNeeded(for: sourceID)
    }

    private func evictDirectorySnapshotsIfNeeded(for sourceID: UUID) {
        while directorySnapshots.keys.lazy.filter({ $0.sourceID == sourceID }).count
            > directorySnapshotPolicy.maximumDirectoriesPerSource,
              let key = leastRecentlyUsedDirectorySnapshotKey(sourceID: sourceID) {
            removeDirectorySnapshot(for: key)
        }
        while directorySnapshotEstimatedBytes > directorySnapshotPolicy.maximumEstimatedBytes,
              let key = leastRecentlyUsedDirectorySnapshotKey(sourceID: nil) {
            removeDirectorySnapshot(for: key)
        }
    }

    private func leastRecentlyUsedDirectorySnapshotKey(
        sourceID: UUID?
    ) -> DirectorySnapshotKey? {
        directorySnapshots.lazy
            .filter { sourceID == nil || $0.key.sourceID == sourceID }
            .min { lhs, rhs in
                if lhs.value.lastAccessSequence == rhs.value.lastAccessSequence {
                    if lhs.key.sourceID == rhs.key.sourceID {
                        return lhs.key.path.normalized < rhs.key.path.normalized
                    }
                    return lhs.key.sourceID.uuidString < rhs.key.sourceID.uuidString
                }
                return lhs.value.lastAccessSequence < rhs.value.lastAccessSequence
            }?
            .key
    }

    private func removeDirectorySnapshots(for sourceID: UUID) {
        let keys = directorySnapshots.keys.filter { $0.sourceID == sourceID }
        for key in keys {
            removeDirectorySnapshot(for: key)
        }
    }

    private func removeDirectorySnapshot(sourceID: UUID, path: ResourcePath) {
        removeDirectorySnapshot(for: DirectorySnapshotKey(sourceID: sourceID, path: path))
    }

    private func removeDirectorySnapshot(for key: DirectorySnapshotKey) {
        guard let removed = directorySnapshots.removeValue(forKey: key) else { return }
        directorySnapshotEstimatedBytes = max(
            directorySnapshotEstimatedBytes - removed.estimatedBytes,
            0
        )
    }

    private func nextDirectorySnapshotAccessSequence() -> UInt64 {
        directorySnapshotAccessSequence &+= 1
        return directorySnapshotAccessSequence
    }

    private static func estimatedDirectorySnapshotBytes(
        path: ResourcePath,
        items: [ResourceItem]
    ) -> Int {
        var total = saturatingAdd(128, path.normalized.utf8.count)
        for item in items {
            var itemBytes = 256
            itemBytes = saturatingAdd(itemBytes, item.name.utf8.count)
            itemBytes = saturatingAdd(itemBytes, item.path.utf8.count)
            itemBytes = saturatingAdd(itemBytes, item.id.logicalPath.utf8.count)
            itemBytes = saturatingAdd(itemBytes, item.metadata.mimeType?.utf8.count ?? 0)
            itemBytes = saturatingAdd(itemBytes, item.metadata.typeIdentifier?.utf8.count ?? 0)
            switch item.metadata.revision {
            case .etag(let value), .serverVersion(let value):
                itemBytes = saturatingAdd(itemBytes, value.utf8.count)
            case .modifiedAndSize, .unknown:
                break
            }
            total = saturatingAdd(total, itemBytes)
        }
        return total
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func measuredDirectoryList(
        registry: SourceRegistry,
        sourceID: UUID,
        path: ResourcePath
    ) async throws -> [ResourceItem] {
        let interval = SourcesStoreSignposts.beginDirectoryList()
        do {
            let items = try await registry.listResources(sourceID: sourceID, at: path)
            try Task.checkCancellation()
            SourcesStoreSignposts.endDirectoryList(interval, outcome: .success)
            return items
        } catch {
            SourcesStoreSignposts.endDirectoryList(
                interval,
                outcome: SourcesStoreSignposts.outcome(for: error)
            )
            throw error
        }
    }

    private func entry(for sourceID: UUID) -> Entry? {
        entries.first { $0.id == sourceID }
    }

    /// 取消来源所有在途工作并递增代数，使迟到结果无法重新写入新来源状态。
    private func cancelWork(for sourceID: UUID) {
        _ = nextConnectionGeneration(for: sourceID)
        _ = nextBrowseGeneration(for: sourceID)
        connectionTasks[sourceID]?.cancel()
        browseTasks[sourceID]?.cancel()
        connectionTasks.removeValue(forKey: sourceID)
        browseTasks.removeValue(forKey: sourceID)
    }

    /// 状态写入的唯一入口：`ResourceSourceState` 是唯一事实源，
    /// `SourceStatus` 作为兼容投影同步更新。
    private func transition(_ sourceID: UUID, to state: ResourceSourceState) {
        update(sourceID) { entry in
            entry.state = state
            entry.source.status = Self.projectedStatus(for: state)
        }
    }

    /// `ResourceSourceState` 到旧 `SourceStatus` 的单向投影；不新增第三套状态。
    private static func projectedStatus(for state: ResourceSourceState) -> ResourceSource.SourceStatus {
        switch state {
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .ready:
            return .connected
        case .failed:
            return .needsAttention
        }
    }

    /// `ResourceSource` also carries connection status and an item-count label,
    /// both of which are Store-owned runtime projections. Dynamic registry sync
    /// compares only the immutable source descriptor so adding or replacing one
    /// source cannot clear another source's ready/browse state.
    private static func sameSourceDescriptor(
        _ lhs: ResourceSource,
        _ rhs: ResourceSource
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.kind == rhs.kind
            && lhs.endpoint == rhs.endpoint
    }

    private func nextConnectionGeneration(for sourceID: UUID) -> Int {
        let generation = (connectionGenerations[sourceID] ?? 0) + 1
        connectionGenerations[sourceID] = generation
        return generation
    }

    private func isCurrentConnectionGeneration(_ sourceID: UUID, _ generation: Int) -> Bool {
        connectionGenerations[sourceID] == generation
    }

    private func finishConnectionTask(sourceID: UUID, generation: Int) {
        guard isCurrentConnectionGeneration(sourceID, generation) else { return }
        connectionTasks.removeValue(forKey: sourceID)
    }

    private func nextBrowseGeneration(for sourceID: UUID) -> Int {
        let generation = (browseGenerations[sourceID] ?? 0) + 1
        browseGenerations[sourceID] = generation
        return generation
    }

    private func isCurrentBrowseGeneration(_ sourceID: UUID, _ generation: Int) -> Bool {
        browseGenerations[sourceID] == generation
    }

    private func finishBrowseTask(sourceID: UUID, generation: Int) {
        guard isCurrentBrowseGeneration(sourceID, generation) else { return }
        browseTasks.removeValue(forKey: sourceID)
    }

    private func update(_ sourceID: UUID, _ mutation: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == sourceID }) else { return }
        mutation(&entries[index])
    }
}
