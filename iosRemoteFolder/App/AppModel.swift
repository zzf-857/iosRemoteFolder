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
    var resources = SampleData.resources
    var sources = SampleData.sources

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
}

