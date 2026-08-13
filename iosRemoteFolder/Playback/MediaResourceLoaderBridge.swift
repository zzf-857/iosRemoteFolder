import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Strict byte-range bridge shared by playback and preview-only AVURLAssets.
/// Source URLs, request headers and credentials remain inside ResourceContentSession.
final class MediaResourceLoaderBridge: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let chunkByteBudget: Int64 = 4 * 1024 * 1024

    private enum Backing: Sendable {
        case memory(Data)
        case session(ResourceContentSession)
    }

    /// Queue-confined state. The Objective-C request never crosses into a Swift Task.
    private final class LoadingState {
        let token = UUID()
        let request: AVAssetResourceLoadingRequest
        let endOffset: Int64
        var nextOffset: Int64
        var task: Task<Void, Never>?
        var isTerminal = false

        init(
            request: AVAssetResourceLoadingRequest,
            nextOffset: Int64,
            endOffset: Int64
        ) {
            self.request = request
            self.nextOffset = nextOffset
            self.endOffset = endOffset
        }
    }

    let queue = DispatchQueue(label: "iosRemoteFolder.media-resource-loader")

    private let backing: Backing
    private let contentLength: Int64
    private let contentTypes: [String]
    private let cumulativeByteBudget: Int64?
    private var invalidated = false
    private var scheduledByteCount: Int64 = 0
    private var loadingStates: [ObjectIdentifier: LoadingState] = [:]

    init(
        data: Data,
        contentTypes: [String],
        cumulativeByteBudget: Int64? = nil
    ) {
        self.backing = .memory(data)
        self.contentLength = Int64(data.count)
        self.contentTypes = contentTypes
        self.cumulativeByteBudget = cumulativeByteBudget.map { max(0, $0) }
    }

    init(
        session: ResourceContentSession,
        contentLength: Int64,
        contentTypes: [String],
        cumulativeByteBudget: Int64? = nil
    ) {
        self.backing = .session(session)
        self.contentLength = contentLength
        self.contentTypes = contentTypes
        self.cumulativeByteBudget = cumulativeByteBudget.map { max(0, $0) }
    }

    var isSessionBacked: Bool {
        if case .session = backing { return true }
        return false
    }

    func invalidate() {
        queue.async { [self] in
            invalidateOnQueue()
        }
    }

    /// Preview leases await this queue-confined terminal point before closing
    /// their session. Playback keeps using fire-and-forget `invalidate()`.
    func invalidateAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                invalidateOnQueue()
                continuation.resume()
            }
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !invalidated else {
            loadingRequest.finishLoading(with: Self.cancelledError)
            return true
        }

        if let contentInformationRequest = loadingRequest.contentInformationRequest {
            guard let negotiatedType = negotiatedContentType(
                allowedTypes: contentInformationRequest.allowedContentTypes
            ) else {
                loadingRequest.finishLoading(with: Self.unsupportedContentTypeError)
                return true
            }
            contentInformationRequest.contentType = negotiatedType
            contentInformationRequest.contentLength = contentLength
            contentInformationRequest.isByteRangeAccessSupported = true
            contentInformationRequest.isEntireLengthAvailableOnDemand = !isSessionBacked
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let identifier = ObjectIdentifier(loadingRequest)
        guard loadingStates[identifier] == nil else {
            loadingRequest.finishLoading(with: Self.invalidRangeError)
            return true
        }
        do {
            let bounds = try requestedBounds(for: dataRequest)
            let state = LoadingState(
                request: loadingRequest,
                nextOffset: bounds.lowerBound,
                endOffset: bounds.upperBound
            )
            loadingStates[identifier] = state
            startNextChunkOnQueue(identifier: identifier, token: state.token)
        } catch {
            loadingRequest.finishLoading(
                with: ResourceSourceError.mapping(error) as NSError
            )
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let identifier = ObjectIdentifier(loadingRequest)
        guard let state = loadingStates.removeValue(forKey: identifier),
              !state.isTerminal else { return }
        state.isTerminal = true
        state.task?.cancel()
        state.task = nil
    }

    static func contentTypes(
        metadata: ResourceMetadata,
        resourcePath: String
    ) -> [String] {
        var identifiers: [String] = []
        func append(_ type: UTType?) {
            guard let identifier = type?.identifier,
                  !identifiers.contains(identifier) else { return }
            identifiers.append(identifier)
        }

        if let identifier = metadata.typeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty {
            append(UTType(identifier))
        }
        if let mimeType = metadata.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mimeType.isEmpty {
            append(UTType(mimeType: mimeType))
        }
        let pathExtension = URL(fileURLWithPath: resourcePath).pathExtension
        if !pathExtension.isEmpty {
            append(UTType(filenameExtension: pathExtension))
        }
        if identifiers.isEmpty {
            identifiers.append(UTType.data.identifier)
        }
        return identifiers
    }

    static func assetURL(resourcePath: String) throws -> URL {
        let pathExtension = URL(fileURLWithPath: resourcePath)
            .pathExtension
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        var components = URLComponents()
        components.scheme = "iosremotefolder-media"
        components.host = "asset"
        components.path = "/\(UUID().uuidString)\(suffix)"
        guard let url = components.url else {
            throw ResourceSourceError.invalidReference
        }
        return url
    }

    private func requestedBounds(
        for dataRequest: AVAssetResourceLoadingDataRequest
    ) throws -> Range<Int64> {
        dispatchPrecondition(condition: .onQueue(queue))
        let requestedOffset = dataRequest.requestedOffset
        let currentOffset = dataRequest.currentOffset
        let startOffset = currentOffset == 0 ? requestedOffset : currentOffset
        guard requestedOffset >= 0,
              startOffset >= requestedOffset,
              startOffset <= contentLength else {
            throw ResourceSourceError.invalidResponse
        }

        let endOffset: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            endOffset = contentLength
        } else {
            guard let requestedLength = Int64(exactly: dataRequest.requestedLength),
                  requestedLength >= 0 else {
                throw ResourceSourceError.invalidResponse
            }
            let (requestedEnd, overflow) = requestedOffset.addingReportingOverflow(requestedLength)
            guard !overflow, requestedEnd >= requestedOffset else {
                throw ResourceSourceError.invalidResponse
            }
            endOffset = min(requestedEnd, contentLength)
        }
        guard startOffset <= endOffset else {
            throw ResourceSourceError.invalidResponse
        }
        return startOffset..<endOffset
    }

    private func startNextChunkOnQueue(
        identifier: ObjectIdentifier,
        token: UUID
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let state = loadingStates[identifier],
              state.token == token,
              !state.isTerminal else { return }
        guard !invalidated else {
            completeOnQueue(
                identifier: identifier,
                token: token,
                error: .cancelled
            )
            return
        }
        guard !state.request.isCancelled, !state.request.isFinished else {
            abandonOnQueue(identifier: identifier, token: token)
            return
        }
        guard state.nextOffset < state.endOffset else {
            completeOnQueue(identifier: identifier, token: token, error: nil)
            return
        }

        let remaining = state.endOffset - state.nextOffset
        let length = min(Self.chunkByteBudget, remaining)
        guard reserveScheduledBytesOnQueue(length) else {
            completeOnQueue(
                identifier: identifier,
                token: token,
                error: .responseTooLarge
            )
            return
        }
        let range = ResourceByteRange(
            lowerBound: state.nextOffset,
            upperBound: state.nextOffset + length - 1
        )

        switch backing {
        case .memory(let data):
            let result: Result<Data, ResourceSourceError>
            if let lowerBound = Int(exactly: range.lowerBound),
               let upperBound = Int(exactly: range.upperBound + 1),
               lowerBound >= 0,
               upperBound <= data.count {
                result = .success(data.subdata(in: lowerBound..<upperBound))
            } else {
                result = .failure(.invalidResponse)
            }
            receiveChunkOnQueue(
                result,
                range: range,
                identifier: identifier,
                token: token
            )

        case .session(let session):
            let deliveryQueue = queue
            let task = Task { [weak self] in
                let result: Result<Data, ResourceSourceError>
                do {
                    try Task.checkCancellation()
                    let data = try await session.readData(
                        range: range,
                        maximumBytes: Self.chunkByteBudget
                    )
                    try Task.checkCancellation()
                    result = .success(data)
                } catch {
                    result = .failure(
                        Task.isCancelled || error is CancellationError
                            ? .cancelled
                            : ResourceSourceError.mapping(error)
                    )
                }
                deliveryQueue.async { [weak self] in
                    self?.receiveChunkOnQueue(
                        result,
                        range: range,
                        identifier: identifier,
                        token: token
                    )
                }
            }
            state.task = task
        }
    }

    private func receiveChunkOnQueue(
        _ result: Result<Data, ResourceSourceError>,
        range: ResourceByteRange,
        identifier: ObjectIdentifier,
        token: UUID
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let state = loadingStates[identifier],
              state.token == token,
              !state.isTerminal else { return }
        state.task = nil
        guard !invalidated else {
            completeOnQueue(
                identifier: identifier,
                token: token,
                error: .cancelled
            )
            return
        }
        guard !state.request.isCancelled, !state.request.isFinished else {
            abandonOnQueue(identifier: identifier, token: token)
            return
        }

        switch result {
        case .failure(let error):
            completeOnQueue(identifier: identifier, token: token, error: error)

        case .success(let data):
            guard let expectedLength = range.validatedLength,
                  Int64(data.count) == expectedLength,
                  let dataRequest = state.request.dataRequest else {
                completeOnQueue(
                    identifier: identifier,
                    token: token,
                    error: .invalidResponse
                )
                return
            }
            let currentOffset = dataRequest.currentOffset == 0
                ? dataRequest.requestedOffset
                : dataRequest.currentOffset
            guard currentOffset == range.lowerBound else {
                completeOnQueue(
                    identifier: identifier,
                    token: token,
                    error: .invalidResponse
                )
                return
            }

            dataRequest.respond(with: data)
            let expectedNextOffset = range.upperBound + 1
            guard dataRequest.currentOffset == expectedNextOffset else {
                completeOnQueue(
                    identifier: identifier,
                    token: token,
                    error: .invalidResponse
                )
                return
            }
            state.nextOffset = expectedNextOffset
            startNextChunkOnQueue(identifier: identifier, token: token)
        }
    }

    private func completeOnQueue(
        identifier: ObjectIdentifier,
        token: UUID,
        error: ResourceSourceError?
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let state = loadingStates[identifier],
              state.token == token,
              !state.isTerminal else { return }
        state.isTerminal = true
        state.task?.cancel()
        state.task = nil
        loadingStates.removeValue(forKey: identifier)

        guard !state.request.isCancelled, !state.request.isFinished else { return }
        if let error {
            state.request.finishLoading(with: error as NSError)
        } else {
            state.request.finishLoading()
        }
    }

    private func abandonOnQueue(identifier: ObjectIdentifier, token: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let state = loadingStates[identifier],
              state.token == token,
              !state.isTerminal else { return }
        state.isTerminal = true
        state.task?.cancel()
        state.task = nil
        loadingStates.removeValue(forKey: identifier)
    }

    private func invalidateOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !invalidated else { return }
        invalidated = true

        for (identifier, state) in Array(loadingStates) {
            completeOnQueue(
                identifier: identifier,
                token: state.token,
                error: .cancelled
            )
        }
        if case .session(let session) = backing {
            Task { await session.close() }
        }
    }

    private func reserveScheduledBytesOnQueue(_ byteCount: Int64) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard byteCount >= 0 else { return false }
        guard let cumulativeByteBudget else { return true }
        let (nextCount, overflow) = scheduledByteCount.addingReportingOverflow(byteCount)
        guard !overflow, nextCount <= cumulativeByteBudget else { return false }
        scheduledByteCount = nextCount
        return true
    }

    private func negotiatedContentType(allowedTypes: [String]?) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let allowedTypes, !allowedTypes.isEmpty else {
            return contentTypes.first
        }

        for contentType in contentTypes where allowedTypes.contains(contentType) {
            return contentType
        }
        for allowedIdentifier in allowedTypes {
            guard let allowedType = UTType(allowedIdentifier) else { continue }
            for contentIdentifier in contentTypes {
                guard let actualType = UTType(contentIdentifier) else { continue }
                if actualType == allowedType || actualType.conforms(to: allowedType) {
                    return allowedIdentifier
                }
            }
        }
        return nil
    }

    private static let cancelledError = NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorCancelled
    )

    private static let unsupportedContentTypeError = ResourceSourceError
        .capabilityUnavailable as NSError

    private static let invalidRangeError = ResourceSourceError.invalidResponse as NSError
}
