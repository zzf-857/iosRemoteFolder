import Foundation

actor ResourceIndexStore {
    private var items: [ResourceItem] = []

    func replace(with items: [ResourceItem]) {
        self.items = items
    }

    func search(_ query: String) -> [ResourceItem] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

