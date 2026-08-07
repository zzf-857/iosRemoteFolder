import SwiftUI

struct SourceRowView: View {
    let source: ResourceSource

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: source.kind.systemImage)
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 42, height: 42)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(source.name)
                    .font(.headline)
                Text(source.kind.title + " · " + source.itemCountDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Circle()
                    .fill(source.status == .connected ? AppTheme.accent : AppTheme.warmAccent)
                    .frame(width: 8, height: 8)
                Text(source.status.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }
}

