import SwiftUI

struct ResourceRowView: View {
    enum Interaction {
        case actionable(resultHint: String)
        case staticContent
    }

    enum DisclosureOwnership {
        case resourceRow
        case container
        case none
    }

    let resource: ResourceItem
    let interaction: Interaction
    let disclosureOwnership: DisclosureOwnership
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var rendersDisclosure: Bool {
        switch (interaction, disclosureOwnership) {
        case (.actionable, .resourceRow):
            true
        default:
            false
        }
    }

    var body: some View {
        accessibleRow
    }

    @ViewBuilder
    private var accessibleRow: some View {
        switch interaction {
        case .actionable(let resultHint):
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(resource.name))
                .accessibilityValue(Text(metadataText))
                .accessibilityHint(Text(resultHint))
        case .staticContent:
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(resource.name))
                .accessibilityValue(Text(metadataText))
                .accessibilityRemoveTraits(.isButton)
        }
    }

    private var rowContent: some View {
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
    }

    private var compactRow: some View {
        HStack(alignment: .top, spacing: 14) {
            resourceIcon
            resourceDetails
                .layoutPriority(1)
            Spacer(minLength: 0)
            if rendersDisclosure {
                disclosure
            }
        }
        .padding(.vertical, 6)
    }

    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                resourceIcon
                Text(resource.name)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if rendersDisclosure {
                    disclosure
                }
            }
            Text(metadataText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var resourceDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(resource.name)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(metadataText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metadataText: String {
        "\(resource.kind.title) · \(ResourceMetadataFormatter.modified(for: resource.metadata))"
    }

    private var resourceIcon: some View {
        ResourcePreviewView(resource: resource)
    }

    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHidden(true)
    }
}
