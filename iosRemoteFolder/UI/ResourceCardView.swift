import SwiftUI

struct ResourceCardView: View {
    let resource: ResourceItem

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
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(resource.kind.title)
                Text("·")
                Text(resource.sizeDescription)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
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

