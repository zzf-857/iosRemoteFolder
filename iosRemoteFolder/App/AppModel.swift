import Foundation
import Observation

enum AppTab: String, CaseIterable, Hashable, Identifiable {
    case home
    case browse
    case sources
    case offline

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    var currentTab: AppTab = .home
    var searchText = ""
    var selectedKind: ResourceKind?
    var resources: [ResourceItem]
    var sources: [ResourceSource]
    /// 来源连接与浏览状态的唯一仓库，由应用级状态持有，
    /// Sources 与 Browse 共享同一份，不再各自创建独立 store。
    var sourcesStore: SourcesStore
    @ObservationIgnored let resourceAccessService: ResourceAccessService
    @ObservationIgnored private let registry: SourceRegistry

    init() {
        let demoSources = SampleData.sources
        let adapters = Self.makeDemoAdapters(for: demoSources)
        let registry: SourceRegistry
        do {
            registry = try SourceRegistry(sources: demoSources, adapters: adapters)
        } catch {
            fatalError("演示来源接线无效：\(error.localizedDescription)")
        }

        self.resources = SampleData.resources
        self.sources = demoSources
        self.registry = registry
        self.sourcesStore = SourcesStore(registry: registry)
        self.resourceAccessService = ResourceAccessService(registry: registry)
    }

    var filteredResources: [ResourceItem] {
        resources.filter { resource in
            let matchesKind = selectedKind == nil || resource.kind == selectedKind
            let matchesSearch = searchText.isEmpty || resource.name.localizedCaseInsensitiveContains(searchText)
            return matchesKind && matchesSearch
        }
    }

    func resetFilters() {
        selectedKind = nil
        searchText = ""
    }

    /// 演示来源的装配只属于 composition root；SourcesStore 不再创建 adapter。
    private static func makeDemoAdapters(
        for sources: [ResourceSource]
    ) -> [any ResourceSourceAdapter] {
        var adapters: [any ResourceSourceAdapter] = []
        for source in sources {
            switch source.kind {
            case .local:
                adapters.append(
                    LocalFilesSourceAdapter(source: source, rootURL: URL.documentsDirectory)
                )
            case .http:
                adapters.append(
                    HTTPSourceAdapter(source: source, descriptors: demoHTTPDescriptors)
                )
            case .alist, .webdav, .lan:
                break
            }
        }
        return adapters
    }

    private static let demoHTTPDescriptors: [HTTPResourceDescriptor] = [
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
