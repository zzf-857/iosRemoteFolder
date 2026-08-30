import SwiftUI

enum ResourcePreviewDisplayArtifact: Sendable {
    case image(ViewerPreparedImage)
    case textExcerpt(String)
}

enum ResourcePreviewDisplayPreparer {
    // ResourcePreviewRequest clamps each side to 512 points at a 4x display scale.
    private static let maximumPixelDimension = 2_048
    private static let maximumPixelCount: Int64 = 2_048 * 2_048

    static func prepare(
        _ artifact: ResourcePreviewArtifact,
        imageExecutionObserver: (@Sendable (_ isMainThread: Bool) -> Void)? = nil
    ) async throws -> ResourcePreviewDisplayArtifact {
        try Task.checkCancellation()
        switch artifact {
        case .encodedImage(let data, .png, let pixelWidth, let pixelHeight):
            guard pixelWidth > 0,
                  pixelHeight > 0,
                  pixelWidth <= maximumPixelDimension,
                  pixelHeight <= maximumPixelDimension,
                  let pixelCount = checkedPixelCount(
                      width: pixelWidth,
                      height: pixelHeight
                  ),
                  pixelCount <= maximumPixelCount else {
                throw ResourceSourceError.invalidResponse
            }

            let image = try await ViewerContentDecoder.prepareImageOffMainActor(
                data,
                policy: ViewerImagePreparationPolicy(
                    maximumPixelDimension: max(pixelWidth, pixelHeight),
                    maximumDecodedPixelCount: pixelCount,
                    maximumSourcePixelCount: pixelCount
                ),
                executionObserver: imageExecutionObserver
            )
            guard image.pixelWidth == pixelWidth,
                  image.pixelHeight == pixelHeight else {
                throw ResourceSourceError.invalidResponse
            }
            try Task.checkCancellation()
            return .image(image)

        case .textExcerpt(let excerpt):
            return .textExcerpt(excerpt)
        }
    }

    private static func checkedPixelCount(width: Int, height: Int) -> Int64? {
        let (count, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !overflow, count > 0 else { return nil }
        return count
    }
}

enum ResourcePreviewFallbackPresentation: Equatable {
    case label
    case symbol
}

/// A bounded, decorative preview used by resource rows and Home cards.
/// The pipeline is obtained from AppModel so rows never create their own
/// cache or source-reading lifetime.
struct ResourcePreviewView: View {
    let resource: ResourceItem
    let targetSize: CGSize
    let cornerRadius: CGFloat
    let fallbackPresentation: ResourcePreviewFallbackPresentation
    let fillsAvailableWidth: Bool

    @Environment(AppModel.self) private var appModel
    @Environment(\.displayScale) private var displayScale

    init(
        resource: ResourceItem,
        targetSize: CGSize = CGSize(width: 40, height: 40),
        cornerRadius: CGFloat = 8,
        fallbackPresentation: ResourcePreviewFallbackPresentation = .label,
        fillsAvailableWidth: Bool = false
    ) {
        self.resource = resource
        self.targetSize = targetSize
        self.cornerRadius = cornerRadius
        self.fallbackPresentation = fallbackPresentation
        self.fillsAvailableWidth = fillsAvailableWidth
    }

    private var request: ResourcePreviewRequest? {
        guard resource.resolvedContentType.kind != .folder else { return nil }
        return ResourcePreviewRequest(
            item: resource,
            targetSize: targetSize,
            displayScale: displayScale
        )
    }

    @ViewBuilder
    var body: some View {
        if resource.resolvedContentType.kind == .folder {
            if fallbackPresentation == .symbol {
                ResourcePreviewSymbolFallback(resource: resource)
                    .previewFrame(
                        targetSize: targetSize,
                        fillsAvailableWidth: fillsAvailableWidth
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .accessibilityHidden(true)
            } else {
                ResourceIconTile(
                    kind: .folder,
                    side: min(targetSize.width, targetSize.height)
                )
            }
        } else {
            PreviewTaskView(
                resource: resource,
                request: request,
                pipeline: appModel.resourcePreviewPipeline,
                fallbackPresentation: fallbackPresentation
            )
            .previewFrame(
                targetSize: targetSize,
                fillsAvailableWidth: fillsAvailableWidth
            )
            .clipShape(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .accessibilityHidden(true)
        }
    }
}

private struct PreviewTaskView: View {
    let resource: ResourceItem
    let request: ResourcePreviewRequest?
    let pipeline: ResourcePreviewPipeline
    let fallbackPresentation: ResourcePreviewFallbackPresentation

    @State private var state: PreviewState = .placeholder
    @State private var activeTaskID: PreviewTaskID?

    private enum PreviewState {
        case placeholder
        case loading
        case artifact(ResourcePreviewDisplayArtifact)
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
            contentTypeFingerprint: (
                request?.contentType ?? resource.resolvedContentType
            ).stableFingerprint
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
            Color.secondary.opacity(0.12)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func artifactView(_ artifact: ResourcePreviewDisplayArtifact) -> some View {
        switch artifact {
        case .image(let image):
            Image(decorative: image.cgImage, scale: 1, orientation: .up)
                .resizable()
                .scaledToFill()
                .clipped()
        case .textExcerpt(let excerpt):
            Text(excerpt)
                .font(
                    .system(
                        size: fallbackPresentation == .symbol ? 11 : 7,
                        weight: .regular,
                        design: .monospaced
                    )
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(fallbackPresentation == .symbol ? 5 : 4)
                .padding(fallbackPresentation == .symbol ? 10 : 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(resource.resolvedContentType.kind.gradient.opacity(0.12))
        }
    }

    @ViewBuilder
    private var fallback: some View {
        switch fallbackPresentation {
        case .label:
            ZStack {
                resource.resolvedContentType.kind.gradient.opacity(0.18)
                Text(fallbackLabel)
                    .font(
                        .system(
                            size: fallbackLabel.count > 3 ? 9 : 11,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(3)
            }
        case .symbol:
            ResourcePreviewSymbolFallback(resource: resource)
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
        return resource.resolvedContentType.kind.title
    }

    private func load(expectedTaskID: PreviewTaskID) async {
        activeTaskID = expectedTaskID
        guard let request,
              resource.resolvedContentType.kind != .folder else {
            guard !Task.isCancelled, activeTaskID == expectedTaskID else { return }
            state = .fallback
            return
        }
        state = .loading
        do {
            let artifact = try await pipeline.preview(for: request)
            let displayArtifact = try await ResourcePreviewDisplayPreparer.prepare(artifact)
            guard !Task.isCancelled, activeTaskID == expectedTaskID else { return }
            state = .artifact(displayArtifact)
        } catch {
            guard !Task.isCancelled, activeTaskID == expectedTaskID else { return }
            state = .fallback
        }
    }
}

private struct ResourcePreviewSymbolFallback: View {
    let resource: ResourceItem

    var body: some View {
        ZStack {
            resource.resolvedContentType.kind.gradient
            Image(systemName: resource.resolvedContentType.kind.systemImage)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }
}

private extension View {
    @ViewBuilder
    func previewFrame(
        targetSize: CGSize,
        fillsAvailableWidth: Bool
    ) -> some View {
        if fillsAvailableWidth {
            frame(maxWidth: .infinity)
                .frame(height: targetSize.height)
        } else {
            frame(width: targetSize.width, height: targetSize.height)
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
    let contentTypeFingerprint: String
}
