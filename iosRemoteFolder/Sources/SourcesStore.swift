import Foundation
import Observation

/// 来源连接状态仓库：持有全部 adapter，驱动连接与重试，并向 UI 报告状态。
///
/// 架构边界：UI 只依赖本仓库暴露的 `entries` 与 `connect` 等方法，
/// 不直接调用 URLSession 或 FileManager；adapter 抛出的错误统一映射为
/// `ResourceSourceError` 后进入 `ResourceSourceState.failed`。
///
/// 双状态规则（D-026）：`ResourceSourceState` 是本仓库的唯一事实源；
/// `ResourceSource.SourceStatus` 只是兼容旧展示的派生投影，只能由本仓库
/// 通过 `transition` 单向写入，adapter 与 UI 都不允许独立维护第三套状态。
@MainActor
@Observable
final class SourcesStore {
    struct Entry: Identifiable {
        var source: ResourceSource
        var state: ResourceSourceState
        var hasAdapter: Bool

        var id: UUID { source.id }
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private var adapters: [UUID: any ResourceSourceAdapter] = [:]
    @ObservationIgnored private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    /// 连接代数：每次发起连接递增；过期任务的任何状态写入都会被忽略，
    /// 保证被取消或被替换的连接任务不会覆盖新状态。
    @ObservationIgnored private var connectionGenerations: [UUID: Int] = [:]

    init(sources: [ResourceSource], adapterFor: (ResourceSource) -> (any ResourceSourceAdapter)?) {
        for source in sources {
            let adapter = adapterFor(source)
            if let adapter {
                adapters[source.id] = adapter
            }
            entries.append(Entry(source: source, state: .disconnected, hasAdapter: adapter != nil))
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
    /// 生命周期：开始时同步进入 connecting；成功进入 ready；失败进入
    /// failed（保留可行动错误）；任务被取消时回到 disconnected，
    /// 不会永久停留在 connecting。
    func connect(_ sourceID: UUID) {
        guard let adapter = adapters[sourceID] else { return }
        connectionTasks[sourceID]?.cancel()
        let generation = nextGeneration(for: sourceID)
        transition(sourceID, to: .connecting)
        let task = Task {
            do {
                try await adapter.connect()
                let resources = try await adapter.listResources()
                try Task.checkCancellation()
                guard self.isCurrentGeneration(sourceID, generation) else { return }
                self.transition(sourceID, to: .ready)
                self.update(sourceID) { entry in
                    entry.source.itemCountDescription = "\(resources.count) 个资源"
                }
            } catch {
                guard self.isCurrentGeneration(sourceID, generation) else { return }
                let mapped = ResourceSourceError.mapping(error)
                if Task.isCancelled || error is CancellationError || mapped == .cancelled {
                    // 取消不是失败：回到未连接，保持状态一致且可重新发起。
                    self.transition(sourceID, to: .disconnected)
                } else {
                    self.transition(sourceID, to: .failed(mapped))
                }
            }
        }
        connectionTasks[sourceID] = task
    }

    /// 失败来源的重试入口。
    func retry(_ sourceID: UUID) {
        connect(sourceID)
    }

    func cancelAllConnections() {
        for sourceID in connectionTasks.keys {
            _ = nextGeneration(for: sourceID)
        }
        connectionTasks.values.forEach { $0.cancel() }
        connectionTasks.removeAll()
        // 被取消的连接不允许停留在 connecting：同步回到未连接。
        let connectingIDs = entries.filter { entry in
            if case .connecting = entry.state { return true }
            return false
        }.map(\.id)
        for sourceID in connectingIDs {
            transition(sourceID, to: .disconnected)
        }
    }

    // MARK: - Private

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

    private func nextGeneration(for sourceID: UUID) -> Int {
        let generation = (connectionGenerations[sourceID] ?? 0) + 1
        connectionGenerations[sourceID] = generation
        return generation
    }

    private func isCurrentGeneration(_ sourceID: UUID, _ generation: Int) -> Bool {
        connectionGenerations[sourceID] == generation
    }

    private func update(_ sourceID: UUID, _ mutation: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == sourceID }) else { return }
        mutation(&entries[index])
    }
}
