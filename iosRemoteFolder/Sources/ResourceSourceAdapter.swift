import Foundation

protocol ResourceSourceAdapter: Sendable {
    var source: ResourceSource { get }
    func listResources() async throws -> [ResourceItem]
}

enum ResourceSourceError: LocalizedError, Sendable {
    case authenticationRequired
    case unavailable
    case capabilityUnavailable

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "来源需要重新认证"
        case .unavailable: "来源暂时不可用"
        case .capabilityUnavailable: "此来源不支持当前操作"
        }
    }
}

struct SampleSourceAdapter: ResourceSourceAdapter {
    let source: ResourceSource

    func listResources() async throws -> [ResourceItem] {
        try await Task.sleep(for: .milliseconds(180))
        guard source.status != .needsAttention else {
            throw ResourceSourceError.authenticationRequired
        }
        return SampleData.resources.filter { $0.sourceID == source.id }
    }
}

