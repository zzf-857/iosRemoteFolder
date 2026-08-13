import SwiftUI

struct SourceRowView: View {
    let source: ResourceSource
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedRow
            } else {
                ViewThatFits(in: .horizontal) {
                    compactRow
                    stackedRow
                }
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var compactRow: some View {
        HStack(alignment: .top, spacing: 14) {
            sourceIcon
            sourceDetails
                .layoutPriority(1)
            Spacer(minLength: 0)
            statusView
        }
        .padding(.vertical, 7)
    }

    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                sourceIcon
                sourceDetails
                    .layoutPriority(1)
            }
            statusView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(source.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(source.kind.title + " · " + source.itemCountDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceIcon: some View {
        SourceIconTile(kind: source.kind, side: 44)
    }

    private var statusView: some View {
        StatusPill(
            title: source.status.title,
            color: AppTheme.statusColor(for: source.status)
        )
        .frame(minHeight: 44, alignment: .leading)
    }
}
