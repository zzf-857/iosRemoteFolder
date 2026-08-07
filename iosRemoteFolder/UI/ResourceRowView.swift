import SwiftUI

struct ResourceRowView: View {
    let resource: ResourceItem

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: resource.kind.systemImage)
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 36, height: 36)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(resource.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(resource.kind.title) · \(resource.modifiedDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }
}

