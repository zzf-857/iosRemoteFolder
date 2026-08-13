import SwiftUI
import UIKit

/// A bounded, decorative preview used by resource rows.
/// The pipeline is obtained from AppModel so rows never create their own
/// cache or source-reading lifetime.
struct ResourcePreviewView: View {
    let resource: ResourceItem

    @Environment(AppModel.self) private var appModel
    @Environment(\.displayScale) private var displayScale

    private let side: CGFloat = 40

    private var request: ResourcePreviewRequest? {
        guard resource.kind != .folder else { return nil }
        return ResourcePreviewRequest(
            item: resource,
            targetSize: CGSize(width: side, height: side),
            displayScale: displayScale
        )
    }

    @ViewBuilder
    var body: some View {
        if resource.kind == .folder {
            ResourceIconTile(kind: .folder, side: side)
        } else {
            PreviewTaskView(
                resource: resource,
                request: request,
                pipeline: appModel.resourcePreviewPipeline
            )
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
        }
    }
}

private struct PreviewTaskView: View {
    let resource: ResourceItem
    let request: ResourcePreviewRequest?
    let pipeline: ResourcePreviewPipeline

    @State private var state: PreviewState = .placeholder
    @State private var activeTaskID: PreviewTaskID?

    private enum PreviewState {
        case placeholder
        case loading
        case artifact(ResourcePreviewArtifact)
        case fallback
    }

    private var taskID: PreviewTaskID {
        PreviewTaskID(
            identity: resource.id,
            revision: resource.metadata.revision,
            pixelWidth: request?.pixelWidth,
            pixelHeight: request?.pixelHeight,
            scaleHundredths: request?.scaleHundredths,
            rendererVersion: request?.rendererVersion,
            kind: resource.kind
        )
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: taskID) {
                await load(expectedTaskID: taskID)
            }
            .onDisappear {
                activeTaskID = nil
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .placeholder:
            placeholder(showsProgress: false)
        case .loading:
            placeholder(showsProgress: true)
        case .artifact(let artifact):
            artifactView(artifact)
        case .fallback:
            fallback
        }
    }

    private func placeholder(showsProgress: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func artifactView(_ artifact: ResourcePreviewArtifact) -> some View {
        switch artifact {
        case .encodedImage(let data, _, _, _):
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                fallback
            }
        case .textExcerpt(let excerpt):
            Text(excerpt)
                .font(.system(size: 7, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.secondary.opacity(0.10))
        }
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(resource.kind.gradient.opacity(0.18))
            Text(fallbackLabel)
                .font(.system(size: fallbackLabel.count > 3 ? 9 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(3)
        }
    }

    private var fallbackLabel: String {
        let pathExtension = resource.name
            .split(separator: ".", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        let normalized = pathExtension
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .uppercased()
        if (2...5).contains(normalized.count) {
            return normalized
        }
        return resource.kind.title
    }

    private func load(expectedTaskID: PreviewTaskID) async {
        activeTaskID = expectedTaskID
        guard let request,
              resource.kind != .folder else {
            guard !Task.isCancelled, activeTaskID == expectedTaskID else { return }
            state = .fallback
            return
        }
        state = .loading
        do {
            let artifact = try await pipeline.preview(for: request)
            guard !Task.isCancelled, activeTaskID == expectedTaskID else { return }
            state = .artifact(artifact)
        } catch {
            guard !Task.isCancelled, activeTaskID == expectedTaskID else { return }
            state = .fallback
        }
    }
}

private struct PreviewTaskID: Hashable {
    let identity: ResourceIdentity
    let revision: ResourceRevision
    let pixelWidth: Int?
    let pixelHeight: Int?
    let scaleHundredths: Int?
    let rendererVersion: Int?
    let kind: ResourceKind
}
