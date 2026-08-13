import AVFoundation
import CoreGraphics
import Foundation

/// Owns every preview-only AVFoundation object and the source session behind it.
/// Closing is idempotent and follows generator -> asset -> loader -> session.
actor PreviewMediaAssetLease {
    private enum CloseState {
        case open
        case closing([CheckedContinuation<Void, Never>])
        case closed
    }

    static let cumulativeRangeByteBudget: Int64 = 16 * 1024 * 1024

    private let session: ResourceContentSession
    private let loader: MediaResourceLoaderBridge
    private let asset: AVURLAsset
    private var activeImageGeneration: PreviewImageGeneration?
    private var closeState: CloseState = .open

    init(
        session: ResourceContentSession,
        metadata: ResourceMetadata,
        resourcePath: String
    ) throws {
        guard let byteSize = metadata.byteSize,
              byteSize > 0,
              metadata.acceptsRanges else {
            throw ResourceSourceError.capabilityUnavailable
        }

        let loader = MediaResourceLoaderBridge(
            session: session,
            contentLength: byteSize,
            contentTypes: MediaResourceLoaderBridge.contentTypes(
                metadata: metadata,
                resourcePath: resourcePath
            ),
            cumulativeByteBudget: Self.cumulativeRangeByteBudget,
            sessionTerminationOwnership: .caller
        )
        let url = try MediaResourceLoaderBridge.assetURL(resourcePath: resourcePath)
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        self.session = session
        self.loader = loader
        self.asset = asset
    }

    func videoFrame(maximumSize: CGSize) async throws -> CGImage {
        try ensureOpen()
        let tracks = try await asset.load(.tracks)
        try ensureOpen()
        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw ResourceSourceError.capabilityUnavailable
        }

        let duration = try await asset.load(.duration)
        try ensureOpen()
        guard duration.isNumeric, duration.seconds > 0 else {
            throw ResourceSourceError.invalidResponse
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: max(1, maximumSize.width),
            height: max(1, maximumSize.height)
        )
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let generation = PreviewImageGeneration(generator: generator)
        activeImageGeneration = generation

        do {
            let seconds = min(duration.seconds * 0.1, 5)
            let image = try await generation.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)
            )
            if activeImageGeneration === generation {
                activeImageGeneration = nil
            }
            try ensureOpen()
            return image
        } catch {
            if activeImageGeneration === generation {
                activeImageGeneration = nil
            }
            throw error
        }
    }

    func embeddedArtwork(maximumBytes: Int64) async throws -> Data {
        guard maximumBytes > 0 else {
            throw ResourceSourceError.invalidReference
        }
        try ensureOpen()

        async let commonMetadata = asset.load(.commonMetadata)
        async let formatMetadata = asset.load(.metadata)
        let metadataItems = try await commonMetadata + formatMetadata
        try ensureOpen()
        let artworkItems = metadataItems.filter {
            Self.artworkIdentifiers.contains($0.identifier)
        }
        guard !artworkItems.isEmpty else {
            throw ResourceSourceError.capabilityUnavailable
        }

        for item in artworkItems {
            try ensureOpen()
            guard let data = try await item.load(.dataValue), !data.isEmpty else {
                continue
            }
            guard Int64(data.count) <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }
            try ensureOpen()
            return data
        }
        throw ResourceSourceError.capabilityUnavailable
    }

    func close() async {
        switch closeState {
        case .closed:
            return
        case .closing:
            await withCheckedContinuation { continuation in
                guard case .closing(var waiters) = closeState else {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                closeState = .closing(waiters)
            }
            return
        case .open:
            closeState = .closing([])
        }

        activeImageGeneration?.cancel()
        activeImageGeneration = nil
        asset.cancelLoading()
        await loader.invalidateAndWait()
        await session.close()

        guard case .closing(let waiters) = closeState else { return }
        closeState = .closed
        waiters.forEach { $0.resume() }
    }

    private func ensureOpen() throws {
        guard case .open = closeState, !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }
    }

    private static let artworkIdentifiers: Set<AVMetadataIdentifier?> = [
        .commonIdentifierArtwork,
        .id3MetadataAttachedPicture,
        .iTunesMetadataCoverArt,
        .quickTimeMetadataArtwork
    ]
}

private final class PreviewImageGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private let completionQueue = DispatchQueue(
        label: "iosRemoteFolder.preview-image-generation-completion"
    )
    private let generator: AVAssetImageGenerator
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private var terminalResult: Result<CGImage, ResourceSourceError>?

    init(generator: AVAssetImageGenerator) {
        self.generator = generator
    }

    func image(at time: CMTime) async throws -> CGImage {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, any Error>) in
                lock.lock()
                if let terminalResult {
                    lock.unlock()
                    Self.resume(continuation, with: terminalResult)
                    return
                }
                self.continuation = continuation
                submit(time: time)
                lock.unlock()
            }
        }, onCancel: {
            cancel()
        })
    }

    func cancel() {
        let continuation: CheckedContinuation<CGImage, any Error>?
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        generator.cancelAllCGImageGeneration()
        terminalResult = .failure(.cancelled)
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let continuation {
            Self.resume(continuation, with: .failure(.cancelled))
        }
    }

    private func submit(time: CMTime) {
        generator.generateCGImagesAsynchronously(
            forTimes: [NSValue(time: time)]
        ) { [weak self] _, image, _, result, error in
            guard let self else { return }
            let terminalResult: Result<CGImage, ResourceSourceError>
            switch result {
            case .succeeded:
                guard let image else {
                    terminalResult = .failure(.invalidResponse)
                    break
                }
                terminalResult = .success(image)
            case .cancelled:
                terminalResult = .failure(.cancelled)
            case .failed:
                terminalResult = .failure(
                    error.map(ResourceSourceError.mapping) ?? .invalidResponse
                )
            @unknown default:
                terminalResult = .failure(.invalidResponse)
            }
            completionQueue.async { [weak self] in
                self?.finish(terminalResult)
            }
        }
    }

    private func finish(_ result: Result<CGImage, ResourceSourceError>) {
        let continuation: CheckedContinuation<CGImage, any Error>?
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let continuation {
            Self.resume(continuation, with: result)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<CGImage, any Error>,
        with result: Result<CGImage, ResourceSourceError>
    ) {
        switch result {
        case .success(let image):
            continuation.resume(returning: image)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
