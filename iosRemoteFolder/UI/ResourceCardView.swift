import SwiftUI

struct ResourceCardView: View {
    let resource: ResourceItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(resource.accent.color.opacity(0.16))
                    .aspectRatio(1.35, contentMode: .fit)
                Image(systemName: resource.kind.systemImage)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(resource.accent.color)
                    .padding(18)
            }
            Text(resource.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if dynamicTypeSize.isAccessibilitySize {
                metadataStack
            } else {
                ViewThatFits(in: .horizontal) {
                    metadataLine
                    metadataStack
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(resource.name))
        .accessibilityValue(Text("\(resource.kind.title)，\(ResourceMetadataFormatter.size(for: resource.metadata))"))
    }

    private var metadataLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(resource.kind.title)
            Text("·")
            Text(ResourceMetadataFormatter.size(for: resource.metadata))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var metadataStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(resource.kind.title)
            Text(ResourceMetadataFormatter.size(for: resource.metadata))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension ResourceAccent {
    var color: Color {
        switch self {
        case .teal: AppTheme.accent
        case .blue: AppTheme.secondaryAccent
        case .orange: AppTheme.warmAccent
        case .pink: .pink
        case .purple: .purple
        }
    }
}
