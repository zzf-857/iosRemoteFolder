import Foundation
import Observation

/// 来源连接状态仓库：持有全部 adapter，驱动连接与重试，并向 UI 报告状态。
///
/// 架构边界：UI 只依赖本仓库暴露的 `entries` 与 `connect` 等方法，
/// 不直接调用 URLSession 或 FileManager；adapter 抛出的错误统一映射为
/// `ResourceSourceError` 后进入 `ResourceSourceState.failed`。
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
    func connect(_ sourceID: UUID) {
        guard let adapter = adapters[sourceID] else { return }
        connectionTasks[sourceID]?.cancel()
        update(sourceID) { entry in
            entry.state = .connecting
        }
        let task = Task {
            do {
                try await adapter.connect()
                let resources = try await adapter.listResources()
                try Task.checkCancellation()
                update(sourceID) { entry in
                    entry.state = .ready
                    entry.source.status = .connected
                    entry.source.itemCountDescription = "\(resources.count) 个资源"
                }
            } catch {
                guard !Task.isCancelled else { return }
                let mapped = ResourceSourceError.mapping(error)
                update(sourceID) { entry in
                    entry.state = .failed(mapped)
                    entry.source.status = .needsAttention
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
        connectionTasks.values.forEach { $0.cancel() }
        connectionTasks.removeAll()
    }

    private func update(_ sourceID: UUID, _ mutation: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == sourceID }) else { return }
        mutation(&entries[index])
    }
}
