import Foundation
import Observation

/// 来源连接状态仓库：持有全部 adapter，驱动连接与重试，并向 UI 报告状态。
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

    @ObservationIgnored private var adapters: [UUID: any ResourceSourceAdapter] = [:]
    @ObservationIgnored private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var browseTasks: [UUID: Task<Void, Never>] = [:]
    /// 连接代数：每次发起连接递增；过期任务的任何状态写入都会被忽略，
    /// 保证被取消或被替换的连接任务不会覆盖新状态。
    @ObservationIgnored private var connectionGenerations: [UUID: Int] = [:]
    /// 浏览加载代数：与连接代数同理，避免过期列举覆盖新目录。
    @ObservationIgnored private var browseGenerations: [UUID: Int] = [:]

    init(sources: [ResourceSource], adapterFor: (ResourceSource) -> (any ResourceSourceAdapter)?) {
        for source in sources {
            let adapter = adapterFor(source)
            if let adapter {
                adapters[source.id] = adapter
            }
            entries.append(Entry(source: source, state: .disconnected, hasAdapter: adapter != nil, browse: SourceBrowse()))
        }
    }

    /// 当前阶段的演示接线：本地来源指向应用文稿目录，HTTP 来源指向本机直链示例；
    /// Alist、WebDAV 等协议尚未接入 adapter。
    static func demo() -> SourcesStore {
        SourcesStore(sources: SampleData.sources) { source in
            let adapter: (any ResourceSourceAdapter)?
            switch source.kind {
            case .local:
                adapter = LocalFilesSourceAdapter(source: source, rootURL: URL.documentsDirectory)
            case .http:
                adapter = HTTPSourceAdapter(source: source, descriptors: demoHTTPDescriptors)
            case .alist, .webdav, .lan:
                adapter = nil
            }
            return adapter
        }
    }

    static var demoHTTPDescriptors: [HTTPResourceDescriptor] {
        [
            HTTPResourceDescriptor(
                path: "/示例/产品手册.pdf",
                name: "产品手册.pdf",
                kind: .pdf,
                url: URL(string: "http://127.0.0.1:48080/files/product-handbook.pdf")!
            ),
            HTTPResourceDescriptor(
                path: "/示例/团队合影.jpg",
                name: "团队合影.jpg",
                kind: .image,
                url: URL(string: "http://127.0.0.1:48080/files/team-photo.jpg")!
            )
        ]
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
    func connect(_ sourceID: UUID) {
        guard let adapter = adapters[sourceID] else { return }
        connectionTasks[sourceID]?.cancel()
        let generation = nextConnectionGeneration(for: sourceID)
        transition(sourceID, to: .connecting)
        let task = Task {
            do {
                try await adapter.connect()
                let resources = try await adapter.listResources(at: .root)
                try Task.checkCancellation()
                guard self.isCurrentConnectionGeneration(sourceID, generation) else { return }
                self.transition(sourceID, to: .ready)
                self.update(sourceID) { entry in
                    entry.source.itemCountDescription = "\(resources.count) 个资源"
                    entry.browse.currentPath = .root
                    entry.browse.items = resources
                    entry.browse.isLoading = false
                    entry.browse.error = nil
                }
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
        connect(sourceID)
    }

    /// 若来源处于可连接状态则发起连接（用于来源被选中时按需连接）。
    func ensureConnected(_ sourceID: UUID) {
        guard let entry = entry(for: sourceID), entry.state.canConnect else { return }
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
        guard let adapter = adapters[sourceID] else { return }
        browseTasks[sourceID]?.cancel()
        let generation = nextBrowseGeneration(for: sourceID)
        update(sourceID) { entry in
            entry.browse.currentPath = path
            // 切换目录时立即清空旧 items，避免在新面包屑下继续展示旧目录内容；
            // 失败状态也与目标目录一致（error 在结果返回时再写入）。
            entry.browse.items = []
            entry.browse.isLoading = true
            entry.browse.error = nil
        }
        let task = Task {
            do {
                let items = try await adapter.listResources(at: path)
                try Task.checkCancellation()
                guard self.isCurrentBrowseGeneration(sourceID, generation) else { return }
                self.update(sourceID) { entry in
                    entry.browse.items = items
                    entry.browse.isLoading = false
                    entry.browse.error = nil
                }
            } catch {
                guard self.isCurrentBrowseGeneration(sourceID, generation) else { return }
                let mapped = ResourceSourceError.mapping(error)
                if Task.isCancelled || error is CancellationError || mapped == .cancelled {
                    self.update(sourceID) { entry in entry.browse.isLoading = false }
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

    /// 进入一个文件夹：文件夹的 `path` 即其完整规范化逻辑路径。
    /// 拒绝来源不匹配或身份/路径矛盾的文件夹，避免越界下钻。
    func enter(_ sourceID: UUID, folder: ResourceItem) {
        guard folder.kind == .folder,
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

    private func entry(for sourceID: UUID) -> Entry? {
        entries.first { $0.id == sourceID }
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

    private func nextConnectionGeneration(for sourceID: UUID) -> Int {
        let generation = (connectionGenerations[sourceID] ?? 0) + 1
        connectionGenerations[sourceID] = generation
        return generation
    }

    private func isCurrentConnectionGeneration(_ sourceID: UUID, _ generation: Int) -> Bool {
        connectionGenerations[sourceID] == generation
    }

    private func nextBrowseGeneration(for sourceID: UUID) -> Int {
        let generation = (browseGenerations[sourceID] ?? 0) + 1
        browseGenerations[sourceID] = generation
        return generation
    }

    private func isCurrentBrowseGeneration(_ sourceID: UUID, _ generation: Int) -> Bool {
        browseGenerations[sourceID] == generation
    }

    private func update(_ sourceID: UUID, _ mutation: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == sourceID }) else { return }
        mutation(&entries[index])
    }
}
