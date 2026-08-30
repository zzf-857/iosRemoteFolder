import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os

private enum ResourcePreviewSignposts {
    enum Outcome {
        case success
        case failure
        case cancelled
    }

    private static let signposter = OSSignposter(
        subsystem: "com.zzf857.iosRemoteFolder",
        category: "ResourcePreview"
    )

    static func beginQueue() -> OSSignpostIntervalState {
        signposter.beginInterval("PreviewQueue")
    }

    static func endQueue(_ state: OSSignpostIntervalState, outcome: Outcome) {
        end("PreviewQueue", state: state, outcome: outcome)
    }

    static func beginRender() -> OSSignpostIntervalState {
        signposter.beginInterval("PreviewRender")
    }

    static func endRender(_ state: OSSignpostIntervalState, outcome: Outcome) {
        end("PreviewRender", state: state, outcome: outcome)
    }

    static func outcome(for error: any Error) -> Outcome {
        let mapped = ResourceSourceError.mapping(error)
        return Task.isCancelled || error is CancellationError || mapped == .cancelled
            ? .cancelled
            : .failure
    }

    private static func end(
        _ name: StaticString,
        state: OSSignpostIntervalState,
        outcome: Outcome
    ) {
        switch outcome {
        case .success:
            signposter.endInterval(name, state, "outcome=success")
        case .failure:
            signposter.endInterval(name, state, "outcome=failure")
        case .cancelled:
            signposter.endInterval(name, state, "outcome=cancelled")
        }
    }
}

struct ResourcePreviewRequest: Hashable, Sendable {
    static let currentRendererVersion = 2
    private static let pointPrecision: CGFloat = 100
    private static let minimumPointDimension: CGFloat = 1
    private static let maximumPointDimension: CGFloat = 512
    private static let minimumDisplayScale: CGFloat = 1
    private static let maximumDisplayScale: CGFloat = 4

    let item: ResourceItem
    let pointWidthHundredths: Int
    let pointHeightHundredths: Int
    let scaleHundredths: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let rendererVersion: Int

    init?(
        item: ResourceItem,
        targetSize: CGSize,
        displayScale: CGFloat,
        rendererVersion: Int = Self.currentRendererVersion
    ) {
        guard item.sourceID == item.id.sourceID,
              let path = ResourcePath(rawValue: item.path),
              path.normalized == item.path,
              item.id.logicalPath == path.normalized,
              targetSize.width.isFinite,
              targetSize.height.isFinite,
              displayScale.isFinite,
              targetSize.width > 0,
              targetSize.height > 0,
              displayScale > 0,
              rendererVersion > 0 else {
            return nil
        }

        let width = min(max(targetSize.width, Self.minimumPointDimension), Self.maximumPointDimension)
        let height = min(max(targetSize.height, Self.minimumPointDimension), Self.maximumPointDimension)
        let scale = min(max(displayScale, Self.minimumDisplayScale), Self.maximumDisplayScale)
        let pointWidthHundredths = Int((width * Self.pointPrecision).rounded())
        let pointHeightHundredths = Int((height * Self.pointPrecision).rounded())
        let scaleHundredths = Int((scale * Self.pointPrecision).rounded())
        let normalizedWidth = CGFloat(pointWidthHundredths) / Self.pointPrecision
        let normalizedHeight = CGFloat(pointHeightHundredths) / Self.pointPrecision
        let normalizedScale = CGFloat(scaleHundredths) / Self.pointPrecision

        self.item = item
        self.pointWidthHundredths = pointWidthHundredths
        self.pointHeightHundredths = pointHeightHundredths
        self.scaleHundredths = scaleHundredths
        self.pixelWidth = max(1, Int((normalizedWidth * normalizedScale).rounded(.up)))
        self.pixelHeight = max(1, Int((normalizedHeight * normalizedScale).rounded(.up)))
        self.rendererVersion = rendererVersion
    }

    var targetSize: CGSize {
        CGSize(
            width: CGFloat(pointWidthHundredths) / Self.pointPrecision,
            height: CGFloat(pointHeightHundredths) / Self.pointPrecision
        )
    }

    var displayScale: CGFloat {
        CGFloat(scaleHundredths) / Self.pointPrecision
    }
}

enum ResourcePreviewImageFormat: String, Codable, Hashable, Sendable {
    case png
}

enum ResourcePreviewArtifact: Codable, Hashable, Sendable {
    case encodedImage(
        data: Data,
        format: ResourcePreviewImageFormat,
        pixelWidth: Int,
        pixelHeight: Int
    )
    case textExcerpt(String)
}

enum ResourceTextPreviewDecoder {
    static func decode(_ data: Data, repairingTruncatedTail: Bool) -> String {
        let input = repairingTruncatedTail ? decodablePrefix(of: data) : data
        return ViewerContentDecoder.decodeText(input)
    }

    private static func decodablePrefix(of data: Data) -> Data {
        let bytes = Array(data)
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
            || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return fixedWidthPrefix(bytes, bomLength: 4, codeUnitWidth: 4)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return utf16Prefix(bytes, littleEndian: true)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return utf16Prefix(bytes, littleEndian: false)
        }
        return Data(bytes.prefix(validUTF8PrefixLength(bytes)))
    }

    private static func fixedWidthPrefix(
        _ bytes: [UInt8],
        bomLength: Int,
        codeUnitWidth: Int
    ) -> Data {
        guard bytes.count > bomLength else { return Data(bytes) }
        let completePayloadBytes = ((bytes.count - bomLength) / codeUnitWidth) * codeUnitWidth
        return Data(bytes.prefix(bomLength + completePayloadBytes))
    }

    private static func utf16Prefix(
        _ bytes: [UInt8],
        littleEndian: Bool
    ) -> Data {
        var endIndex = 2 + ((max(bytes.count - 2, 0) / 2) * 2)
        guard endIndex >= 4 else { return Data(bytes.prefix(endIndex)) }

        let lastUnitStart = endIndex - 2
        let codeUnit: UInt16
        if littleEndian {
            codeUnit = UInt16(bytes[lastUnitStart])
                | (UInt16(bytes[lastUnitStart + 1]) << 8)
        } else {
            codeUnit = (UInt16(bytes[lastUnitStart]) << 8)
                | UInt16(bytes[lastUnitStart + 1])
        }
        if (0xD800...0xDBFF).contains(codeUnit) {
            endIndex -= 2
        }
        return Data(bytes.prefix(endIndex))
    }

    private static func validUTF8PrefixLength(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var sequenceStart = bytes.count - 1
        while sequenceStart >= 0, bytes[sequenceStart] & 0xC0 == 0x80 {
            sequenceStart -= 1
        }
        guard sequenceStart >= 0 else { return bytes.count }

        let expectedLength: Int
        switch bytes[sequenceStart] {
        case 0xC2...0xDF: expectedLength = 2
        case 0xE0...0xEF: expectedLength = 3
        case 0xF0...0xF4: expectedLength = 4
        default: return bytes.count
        }
        return bytes.count - sequenceStart < expectedLength ? sequenceStart : bytes.count
    }
}

actor ResourcePreviewPipeline {
    private struct CacheKey: Hashable, Sendable {
        let identity: ResourceIdentity
        let revision: ResourceRevision
        let pixelWidth: Int
        let pixelHeight: Int
        let scaleHundredths: Int
        let rendererVersion: Int
        let artifactKind: String

        init(request: ResourcePreviewRequest, revision: ResourceRevision? = nil) {
            identity = request.item.id
            self.revision = revision ?? request.item.metadata.revision
            pixelWidth = request.pixelWidth
            pixelHeight = request.pixelHeight
            scaleHundredths = request.scaleHundredths
            rendererVersion = request.rendererVersion
            artifactKind = switch request.item.kind {
            case .image, .pdf: "image"
            case .text, .markdown: "text"
            case .folder: "folder"
            case .video: "video"
            case .audio: "audio"
            case .unknown: "unknown"
            }
        }

        var persistenceToken: String? {
            guard revision.isKnown else { return nil }
            return [
                identity.identityKey,
                revision.previewPersistenceToken,
                "px:\(pixelWidth)x\(pixelHeight)",
                "scale:\(scaleHundredths)",
                "renderer:\(rendererVersion)",
                "kind:\(artifactKind)"
            ].joined(separator: "\u{1F}")
        }
    }

    private struct MemoryEntry: Sendable {
        let artifact: ResourcePreviewArtifact
        let cost: Int
        var accessOrder: UInt64
    }

    private struct DiskManifestEntry: Codable, Sendable {
        let sourceID: UUID
        let byteCount: Int64
        var lastAccess: Date
    }

    private struct DiskRecord: Codable, Sendable {
        let keyDigest: String
        let artifact: ResourcePreviewArtifact
    }

    private struct GeneratedPreview: Sendable {
        let artifact: ResourcePreviewArtifact
        let revision: ResourceRevision
    }

    private struct TextPreviewInput: Sendable {
        let data: Data
        let isTruncatedPrefix: Bool
    }

    private struct Waiter {
        let continuation: CheckedContinuation<ResourcePreviewArtifact, any Error>
    }

    private struct InFlight {
        let id: UUID
        let task: Task<GeneratedPreview, any Error>
        var waiters: [UUID: Waiter]
        let sourceID: UUID
        let globalEpoch: UInt64
        let sourceEpoch: UInt64
    }

    private static let imageByteBudget: Int64 = 12 * 1024 * 1024
    private static let artworkByteBudget: Int64 = 12 * 1024 * 1024
    private static let pdfByteBudget: Int64 = 16 * 1024 * 1024
    private static let textByteBudget: Int64 = 256 * 1024
    private static let textPrefixByteBudget: Int64 = 64 * 1024
    private static let quickLookByteBudget: Int64 = 4 * 1024 * 1024
    private static let requestDeadline: Duration = .seconds(8)
    private static let memoryCostBudget = 16 * 1024 * 1024
    private static let diskByteBudget: Int64 = 64 * 1024 * 1024
    private static let maximumDiskRecordBytes: Int64 = 20 * 1024 * 1024
    private static let maximumManifestBytes: Int64 = 2 * 1024 * 1024
    private static let manifestFilename = "manifest.json"
    private static let materializationRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("iosRemoteFolder", isDirectory: true)
        .appendingPathComponent("preview-materialization-v1", isDirectory: true)

    private let accessService: ResourceAccessService
    private let cacheDirectory: URL
    private let manifestURL: URL
    private let concurrencyLimiter = PreviewConcurrencyLimiter(limit: 3)
    private let fileManager = FileManager.default
    private let accessFlushDelay: Duration
    private let currentDate: @Sendable () -> Date
    private let manifestDataWriter: @Sendable (Data, URL) throws -> Void

    private var inFlight: [CacheKey: InFlight] = [:]
    private var memoryCache: [CacheKey: MemoryEntry] = [:]
    private var memoryCost = 0
    private var accessCounter: UInt64 = 0
    private var diskManifest: [String: DiskManifestEntry]
    private var manifestAccessesAreDirty = false
    private var manifestAccessFlushTask: Task<Void, Never>?
    private var manifestAccessFlushGeneration: UInt64 = 0
    private var globalEpoch: UInt64 = 0
    private var sourceEpochs: [UUID: UInt64] = [:]

    init(
        accessService: ResourceAccessService,
        cacheDirectory: URL? = nil,
        accessFlushDelay: Duration = .milliseconds(250),
        currentDate: @escaping @Sendable () -> Date = { Date() },
        manifestDataWriter: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.accessService = accessService
        let root = cacheDirectory ?? Self.defaultCacheDirectory()
        self.cacheDirectory = root
        self.manifestURL = root.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        self.accessFlushDelay = accessFlushDelay
        self.currentDate = currentDate
        self.manifestDataWriter = manifestDataWriter
        self.diskManifest = Self.loadManifest(
            at: root.appendingPathComponent(Self.manifestFilename, isDirectory: false),
            cacheDirectory: root
        )
    }

    deinit {
        manifestAccessFlushTask?.cancel()
        guard manifestAccessesAreDirty else { return }
        try? Self.persistManifest(
            diskManifest,
            at: manifestURL,
            cacheDirectory: cacheDirectory,
            dataWriter: manifestDataWriter
        )
    }

    func preview(for request: ResourcePreviewRequest) async throws -> ResourcePreviewArtifact {
        guard !Task.isCancelled else { throw ResourceSourceError.cancelled }
        let requestedKey = CacheKey(request: request)

        if let cached = memoryArtifact(for: requestedKey) {
            guard !Task.isCancelled else { throw ResourceSourceError.cancelled }
            return cached
        }
        if let cached = diskArtifact(for: requestedKey) {
            guard !Task.isCancelled else { throw ResourceSourceError.cancelled }
            insertMemory(cached, for: requestedKey)
            return cached
        }

        let waiterID = UUID()
        do {
            let artifact = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<ResourcePreviewArtifact, any Error>) in
                    addWaiter(
                        continuation,
                        id: waiterID,
                        request: request,
                        key: requestedKey
                    )
                    if Task.isCancelled {
                        cancelWaiter(waiterID, for: requestedKey)
                    }
                }
            }, onCancel: {
                Task { await self.cancelWaiter(waiterID, for: requestedKey) }
            })
            guard !Task.isCancelled else { throw ResourceSourceError.cancelled }
            return artifact
        } catch {
            throw Self.mapError(error)
        }
    }

    func removeAll() {
        globalEpoch &+= 1
        cancelManifestAccessFlush(discardingChanges: true)
        let cancelledEntries = Array(inFlight.values)
        inFlight.removeAll()
        cancelledEntries.forEach(cancelInFlight)
        memoryCache.removeAll()
        memoryCost = 0
        sourceEpochs.removeAll()
        diskManifest.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
    }

    func flushPendingManifestAccesses() throws {
        cancelManifestAccessFlush(discardingChanges: false)
        try persistDirtyManifestAccesses()
    }

    func remove(sourceID: UUID) {
        invalidate(sourceID: sourceID)
    }

    func retain(sourceIDs: Set<UUID>) {
        let knownSourceIDs = Set(inFlight.values.map(\.sourceID))
            .union(memoryCache.keys.map { $0.identity.sourceID })
            .union(diskManifest.values.map(\.sourceID))
        for sourceID in knownSourceIDs where !sourceIDs.contains(sourceID) {
            invalidate(sourceID: sourceID)
        }
    }

    private func addWaiter(
        _ continuation: CheckedContinuation<ResourcePreviewArtifact, any Error>,
        id waiterID: UUID,
        request: ResourcePreviewRequest,
        key: CacheKey
    ) {
        if var existing = inFlight[key] {
            existing.waiters[waiterID] = Waiter(continuation: continuation)
            inFlight[key] = existing
            return
        }

        let id = UUID()
        let sourceID = request.item.sourceID
        let sourceEpoch = sourceEpochs[sourceID, default: 0]
        let globalEpoch = self.globalEpoch
        let accessService = self.accessService
        let limiter = concurrencyLimiter
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try await Self.generate(
                request: request,
                accessService: accessService,
                limiter: limiter
            )
        }
        let entry = InFlight(
            id: id,
            task: task,
            waiters: [waiterID: Waiter(continuation: continuation)],
            sourceID: sourceID,
            globalEpoch: globalEpoch,
            sourceEpoch: sourceEpoch
        )
        inFlight[key] = entry
        Task { [weak self] in
            let result: Result<GeneratedPreview, ResourceSourceError>
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(Self.mapError(error))
            }
            await self?.complete(
                result,
                request: request,
                requestedKey: key,
                inFlightID: id,
                globalEpoch: globalEpoch,
                sourceEpoch: sourceEpoch
            )
        }
    }

    private func complete(
        _ result: Result<GeneratedPreview, ResourceSourceError>,
        request: ResourcePreviewRequest,
        requestedKey: CacheKey,
        inFlightID: UUID,
        globalEpoch: UInt64,
        sourceEpoch: UInt64
    ) {
        guard let current = inFlight[requestedKey], current.id == inFlightID else { return }
        inFlight.removeValue(forKey: requestedKey)

        guard self.globalEpoch == globalEpoch,
              sourceEpochs[request.item.sourceID, default: 0] == sourceEpoch else {
            current.waiters.values.forEach {
                $0.continuation.resume(throwing: ResourceSourceError.cancelled)
            }
            return
        }

        switch result {
        case .success(let generated):
            let resolvedKey = CacheKey(request: request, revision: generated.revision)
            insertMemory(generated.artifact, for: resolvedKey)
            if request.item.metadata.revision.isUnknown, resolvedKey != requestedKey {
                // Only an unknown list snapshot may alias the probed revision in memory.
                insertMemory(generated.artifact, for: requestedKey)
            }
            if request.item.metadata.revision.isKnown {
                storeDisk(generated.artifact, for: resolvedKey)
            }
            current.waiters.values.forEach { $0.continuation.resume(returning: generated.artifact) }
        case .failure(let error):
            current.waiters.values.forEach { $0.continuation.resume(throwing: error) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for key: CacheKey) {
        guard var current = inFlight[key],
              let waiter = current.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: ResourceSourceError.cancelled)
        if current.waiters.isEmpty {
            current.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = current
        }
    }

    private func invalidate(sourceID: UUID) {
        sourceEpochs[sourceID, default: 0] &+= 1

        let inFlightKeys = inFlight.compactMap { key, entry in
            entry.sourceID == sourceID ? key : nil
        }
        for key in inFlightKeys {
            guard let entry = inFlight.removeValue(forKey: key) else { continue }
            cancelInFlight(entry)
        }

        let memoryKeys = memoryCache.keys.filter { $0.identity.sourceID == sourceID }
        for key in memoryKeys {
            if let removed = memoryCache.removeValue(forKey: key) {
                memoryCost = max(0, memoryCost - removed.cost)
            }
        }

        let diskDigests = diskManifest.compactMap { digest, entry in
            entry.sourceID == sourceID ? digest : nil
        }
        for digest in diskDigests {
            removeDiskFile(digest: digest)
            diskManifest.removeValue(forKey: digest)
        }
        if !diskDigests.isEmpty {
            try? persistManifestImmediately()
        }
    }

    private func cancelInFlight(_ entry: InFlight) {
        entry.task.cancel()
        entry.waiters.values.forEach {
            $0.continuation.resume(throwing: ResourceSourceError.cancelled)
        }
    }

    private func memoryArtifact(for key: CacheKey) -> ResourcePreviewArtifact? {
        guard var entry = memoryCache[key] else { return nil }
        accessCounter &+= 1
        entry.accessOrder = accessCounter
        memoryCache[key] = entry
        return entry.artifact
    }

    private func insertMemory(_ artifact: ResourcePreviewArtifact, for key: CacheKey) {
        if let old = memoryCache.removeValue(forKey: key) {
            memoryCost = max(0, memoryCost - old.cost)
        }
        accessCounter &+= 1
        let cost = artifact.previewMemoryCost
        memoryCache[key] = MemoryEntry(
            artifact: artifact,
            cost: cost,
            accessOrder: accessCounter
        )
        memoryCost = memoryCost.addingClamped(cost)

        while memoryCost > Self.memoryCostBudget,
              let oldest = memoryCache.min(by: { $0.value.accessOrder < $1.value.accessOrder }) {
            memoryCache.removeValue(forKey: oldest.key)
            memoryCost = max(0, memoryCost - oldest.value.cost)
        }
    }

    private func diskArtifact(for key: CacheKey) -> ResourcePreviewArtifact? {
        guard let token = key.persistenceToken else { return nil }
        pruneDiskIfNeeded()
        let digest = Self.digest(token)
        guard var manifestEntry = diskManifest[digest] else {
            return nil
        }
        let url = diskFileURL(digest: digest)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= 0,
              fileSize.int64Value <= Self.maximumDiskRecordBytes,
              manifestEntry.byteCount == fileSize.int64Value,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let record = try? PropertyListDecoder().decode(DiskRecord.self, from: data),
              record.keyDigest == digest else {
            removeDiskFile(digest: digest)
            diskManifest.removeValue(forKey: digest)
            try? persistManifestImmediately()
            return nil
        }

        manifestEntry.lastAccess = currentDate()
        diskManifest[digest] = manifestEntry
        scheduleManifestAccessFlush()
        return record.artifact
    }

    private func storeDisk(_ artifact: ResourcePreviewArtifact, for key: CacheKey) {
        guard let token = key.persistenceToken else { return }
        let digest = Self.digest(token)
        let record = DiskRecord(keyDigest: digest, artifact: artifact)
        guard let data = try? PropertyListEncoder.previewEncoder.encode(record),
              Int64(data.count) <= Self.maximumDiskRecordBytes else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: diskFileURL(digest: digest), options: .atomic)
            diskManifest[digest] = DiskManifestEntry(
                sourceID: key.identity.sourceID,
                byteCount: Int64(data.count),
                lastAccess: currentDate()
            )
            try persistManifestImmediately()
            pruneDiskIfNeeded()
        } catch {
            removeDiskFile(digest: digest)
            diskManifest.removeValue(forKey: digest)
        }
    }

    private func pruneDiskIfNeeded() {
        var total = diskManifest.values.reduce(into: Int64(0)) { partial, entry in
            partial = partial.addingClamped(entry.byteCount)
        }
        guard total > Self.diskByteBudget else { return }

        for (digest, entry) in diskManifest.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            removeDiskFile(digest: digest)
            diskManifest.removeValue(forKey: digest)
            total = max(0, total - entry.byteCount)
            if total <= Self.diskByteBudget { break }
        }
        try? persistManifestImmediately()
    }

    private func scheduleManifestAccessFlush() {
        manifestAccessesAreDirty = true
        manifestAccessFlushGeneration &+= 1
        let generation = manifestAccessFlushGeneration
        manifestAccessFlushTask?.cancel()

        let delay = accessFlushDelay
        manifestAccessFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.flushScheduledManifestAccesses(generation: generation)
        }
    }

    private func flushScheduledManifestAccesses(generation: UInt64) {
        // A cancelled debounce may already be queued on the actor. It must not
        // flush or clear the newer task that replaced it.
        guard generation == manifestAccessFlushGeneration else { return }
        manifestAccessFlushTask = nil
        try? persistDirtyManifestAccesses()
    }

    private func persistDirtyManifestAccesses() throws {
        guard manifestAccessesAreDirty else { return }
        try Self.persistManifest(
            diskManifest,
            at: manifestURL,
            cacheDirectory: cacheDirectory,
            dataWriter: manifestDataWriter
        )
        manifestAccessesAreDirty = false
    }

    private func persistManifestImmediately() throws {
        cancelManifestAccessFlush(discardingChanges: false)
        do {
            try Self.persistManifest(
                diskManifest,
                at: manifestURL,
                cacheDirectory: cacheDirectory,
                dataWriter: manifestDataWriter
            )
            manifestAccessesAreDirty = false
        } catch {
            if manifestAccessesAreDirty {
                scheduleManifestAccessFlush()
            }
            throw error
        }
    }

    private func cancelManifestAccessFlush(discardingChanges: Bool) {
        manifestAccessFlushGeneration &+= 1
        manifestAccessFlushTask?.cancel()
        manifestAccessFlushTask = nil
        if discardingChanges {
            manifestAccessesAreDirty = false
        }
    }

    private static func persistManifest(
        _ manifest: [String: DiskManifestEntry],
        at manifestURL: URL,
        cacheDirectory: URL,
        dataWriter: @Sendable (Data, URL) throws -> Void
    ) throws {
        guard !manifest.isEmpty else {
            try? FileManager.default.removeItem(at: manifestURL)
            return
        }
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(manifest)
        try dataWriter(data, manifestURL)
    }

    private func diskFileURL(digest: String) -> URL {
        cacheDirectory.appendingPathComponent(digest + ".preview", isDirectory: false)
    }

    private func removeDiskFile(digest: String) {
        try? fileManager.removeItem(at: diskFileURL(digest: digest))
    }

    private static func generate(
        request: ResourcePreviewRequest,
        accessService: ResourceAccessService,
        limiter: PreviewConcurrencyLimiter
    ) async throws -> GeneratedPreview {
        switch request.item.kind {
        case .folder:
            throw ResourceSourceError.capabilityUnavailable
        case .video, .audio, .image, .pdf, .text, .markdown, .unknown:
            break
        }

        let race = PreviewRenderRace(
            request: request,
            accessService: accessService,
            limiter: limiter,
            deadline: requestDeadline
        )
        return try await withTaskCancellationHandler(operation: {
            try await race.value()
        }, onCancel: {
            Task { await race.cancel() }
        })
    }

    private static func render(
        request: ResourcePreviewRequest,
        session: ResourceContentSession,
        installMediaLease: @Sendable (PreviewMediaAssetLease) async -> Bool
    ) async throws -> GeneratedPreview {
        try Task.checkCancellation()
        let metadata = try await session.fetchMetadata()
        let artifact: ResourcePreviewArtifact

        switch request.item.kind {
        case .image:
            let data = try await boundedData(
                from: session,
                metadata: metadata,
                maximumBytes: imageByteBudget
            )
            artifact = try renderImage(data, request: request)
        case .pdf:
            let data = try await boundedData(
                from: session,
                metadata: metadata,
                maximumBytes: pdfByteBudget
            )
            artifact = try renderPDF(data, request: request)
        case .text, .markdown:
            let input = try await textPreviewInput(
                from: session,
                metadata: metadata
            )
            artifact = try renderText(input)
        case .unknown:
            artifact = try await renderQuickLookThumbnail(
                session: session,
                metadata: metadata,
                request: request
            )
        case .video, .audio:
            guard metadata.acceptsRanges else {
                throw ResourceSourceError.capabilityUnavailable
            }
            let lease = try PreviewMediaAssetLease(
                session: session,
                metadata: metadata,
                resourcePath: request.item.path
            )
            guard await installMediaLease(lease) else {
                await lease.close()
                throw ResourceSourceError.cancelled
            }
            switch request.item.kind {
            case .video:
                let image = try await lease.videoFrame(
                    maximumSize: CGSize(
                        width: request.pixelWidth,
                        height: request.pixelHeight
                    )
                )
                artifact = try encodedImageArtifact(image)
            case .audio:
                let artwork = try await lease.embeddedArtwork(
                    maximumBytes: artworkByteBudget
                )
                artifact = try renderImage(artwork, request: request)
            default:
                throw ResourceSourceError.invalidResponse
            }
        case .folder:
            throw ResourceSourceError.capabilityUnavailable
        }
        try Task.checkCancellation()
        return GeneratedPreview(artifact: artifact, revision: metadata.revision)
    }

    private static func boundedData(
        from session: ResourceContentSession,
        metadata: ResourceMetadata,
        maximumBytes: Int64
    ) async throws -> Data {
        guard let byteSize = metadata.byteSize,
              byteSize >= 0,
              byteSize <= maximumBytes else {
            throw ResourceSourceError.responseTooLarge
        }
        return try await session.readData(maximumBytes: maximumBytes)
    }

    private static func textPreviewInput(
        from session: ResourceContentSession,
        metadata: ResourceMetadata
    ) async throws -> TextPreviewInput {
        if metadata.acceptsRanges,
           let byteSize = metadata.byteSize,
           byteSize > textPrefixByteBudget {
            let range = ResourceByteRange(
                lowerBound: 0,
                upperBound: textPrefixByteBudget - 1
            )
            let data = try await session.readData(
                range: range,
                maximumBytes: textPrefixByteBudget
            )
            return TextPreviewInput(data: data, isTruncatedPrefix: true)
        }

        let data = try await boundedData(
            from: session,
            metadata: metadata,
            maximumBytes: textByteBudget
        )
        return TextPreviewInput(data: data, isTruncatedPrefix: false)
    }

    private static func renderQuickLookThumbnail(
        session: ResourceContentSession,
        metadata: ResourceMetadata,
        request: ResourcePreviewRequest
    ) async throws -> ResourcePreviewArtifact {
        guard let byteSize = metadata.byteSize,
              byteSize >= 0,
              byteSize <= quickLookByteBudget else {
            throw ResourceSourceError.responseTooLarge
        }
        guard let filename = quickLookFilename(for: request.item.name) else {
            throw ResourceSourceError.capabilityUnavailable
        }
        try Task.checkCancellation()

        let data = try await session.readData(maximumBytes: quickLookByteBudget)
        try Task.checkCancellation()

        let directory = materializationRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent(
                filename,
                isDirectory: false
            )
            try data.write(to: fileURL, options: .atomic)
            try Task.checkCancellation()
            return try await generateQuickLookThumbnail(
                for: fileURL,
                request: request
            )
        } catch {
            throw mapError(error)
        }
    }

    private static func quickLookFilename(for resourceName: String) -> String? {
        let rawExtension = URL(fileURLWithPath: resourceName).pathExtension
        let sanitized = rawExtension.utf8.filter { byte in
            switch byte {
            case 48...57, 65...90, 97...122:
                true
            default:
                false
            }
        }
        let boundedExtension = String(decoding: sanitized.prefix(10), as: UTF8.self)
        guard !boundedExtension.isEmpty else { return nil }
        return "resource.\(boundedExtension)"
    }

    private static func generateQuickLookThumbnail(
        for fileURL: URL,
        request: ResourcePreviewRequest
    ) async throws -> ResourcePreviewArtifact {
        let thumbnailRequest = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: request.targetSize,
            scale: request.displayScale,
            representationTypes: [.thumbnail]
        )
        thumbnailRequest.iconMode = false

        let image = try await QuickLookThumbnailContinuation(
            request: thumbnailRequest
        ).value()
        try Task.checkCancellation()
        let encoded = try encodePNG(image)
        return .encodedImage(
            data: encoded,
            format: .png,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private static func renderImage(
        _ data: Data,
        request: ResourcePreviewRequest
    ) throws -> ResourcePreviewArtifact {
        try Task.checkCancellation()
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            throw ResourceSourceError.invalidResponse
        }
        let maximumPixelSize = max(request.pixelWidth, request.pixelHeight)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ResourceSourceError.invalidResponse
        }
        let encoded = try encodePNG(image)
        return .encodedImage(
            data: encoded,
            format: .png,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private static func renderPDF(
        _ data: Data,
        request: ResourcePreviewRequest
    ) throws -> ResourcePreviewArtifact {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            throw ResourceSourceError.invalidResponse
        }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            throw ResourceSourceError.invalidResponse
        }

        let width = request.pixelWidth
        let height = request.pixelHeight
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ResourceSourceError.unavailable
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let scale = min(CGFloat(width) / bounds.width, CGFloat(height) / bounds.height)
        let renderedSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let origin = CGPoint(
            x: (CGFloat(width) - renderedSize.width) / 2,
            y: (CGFloat(height) - renderedSize.height) / 2
        )
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw ResourceSourceError.invalidResponse
        }
        let encoded = try encodePNG(image)
        return .encodedImage(
            data: encoded,
            format: .png,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private static func renderText(_ input: TextPreviewInput) throws -> ResourcePreviewArtifact {
        try Task.checkCancellation()
        let decoded = ResourceTextPreviewDecoder.decode(
            input.data,
            repairingTruncatedTail: input.isTruncatedPrefix
        )

        let lines = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let excerpt = lines.prefix(3).joined(separator: " ")
        let bounded = String(excerpt.prefix(180))
        guard !bounded.isEmpty else { throw ResourceSourceError.invalidResponse }
        return .textExcerpt(bounded)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ResourceSourceError.unavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ResourceSourceError.invalidResponse
        }
        return output as Data
    }

    private static func encodedImageArtifact(
        _ image: CGImage
    ) throws -> ResourcePreviewArtifact {
        .encodedImage(
            data: try encodePNG(image),
            format: .png,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Races rendering against the product-level deadline without making the
    /// timeout wait for a renderer that is slow to observe cancellation.
    private actor PreviewRenderRace {
        private let request: ResourcePreviewRequest
        private let accessService: ResourceAccessService
        private let limiter: PreviewConcurrencyLimiter
        private let deadline: Duration

        private var terminalResult: Result<GeneratedPreview, ResourceSourceError>?
        private var continuation: CheckedContinuation<GeneratedPreview, any Error>?
        private var activeSession: ResourceContentSession?
        private var activeMediaLease: PreviewMediaAssetLease?
        private var renderTask: Task<Void, Never>?
        private var deadlineTask: Task<Void, Never>?

        init(
            request: ResourcePreviewRequest,
            accessService: ResourceAccessService,
            limiter: PreviewConcurrencyLimiter,
            deadline: Duration
        ) {
            self.request = request
            self.accessService = accessService
            self.limiter = limiter
            self.deadline = deadline
        }

        func value() async throws -> GeneratedPreview {
            if Task.isCancelled {
                await finish(.failure(.cancelled))
            }
            if let terminalResult {
                return try terminalResult.get()
            }

            return try await withCheckedThrowingContinuation { continuation in
                if let terminalResult {
                    Self.resume(continuation, with: terminalResult)
                    return
                }
                self.continuation = continuation
                startIfNeeded()
            }
        }

        func cancel() async {
            await finish(.failure(.cancelled))
        }

        private func startIfNeeded() {
            guard renderTask == nil, deadlineTask == nil, terminalResult == nil else { return }
            let request = self.request
            let accessService = self.accessService
            let limiter = self.limiter
            let deadline = self.deadline
            let owner = self

            renderTask = Task.detached(priority: .utility) {
                let queueInterval = ResourcePreviewSignposts.beginQueue()
                let result: Result<GeneratedPreview, ResourceSourceError>
                do {
                    try await limiter.acquire()
                } catch {
                    ResourcePreviewSignposts.endQueue(
                        queueInterval,
                        outcome: ResourcePreviewSignposts.outcome(for: error)
                    )
                    await owner.finish(
                        .failure(ResourcePreviewPipeline.mapError(error))
                    )
                    return
                }
                ResourcePreviewSignposts.endQueue(queueInterval, outcome: .success)

                let renderInterval = ResourcePreviewSignposts.beginRender()
                do {
                    try Task.checkCancellation()
                    let session = try await accessService.makeSession(for: request.item)
                    guard await owner.install(session: session) else {
                        throw ResourceSourceError.cancelled
                    }
                    result = .success(try await ResourcePreviewPipeline.render(
                        request: request,
                        session: session,
                        installMediaLease: { lease in
                            await owner.install(mediaLease: lease)
                        }
                    ))
                } catch {
                    result = .failure(ResourcePreviewPipeline.mapError(error))
                }
                await limiter.release()
                switch result {
                case .success:
                    ResourcePreviewSignposts.endRender(renderInterval, outcome: .success)
                case .failure(let error):
                    ResourcePreviewSignposts.endRender(
                        renderInterval,
                        outcome: ResourcePreviewSignposts.outcome(for: error)
                    )
                }
                await owner.finish(result)
            }

            deadlineTask = Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(for: deadline)
                    await owner.finish(.failure(.timedOut))
                } catch {
                    // Cancellation means rendering or caller cancellation won the race.
                }
            }
        }

        private func install(session: ResourceContentSession) async -> Bool {
            guard terminalResult == nil else {
                await session.close()
                return false
            }
            activeSession = session
            return true
        }

        private func install(mediaLease: PreviewMediaAssetLease) -> Bool {
            guard terminalResult == nil else { return false }
            activeMediaLease = mediaLease
            activeSession = nil
            return true
        }

        private func finish(
            _ result: Result<GeneratedPreview, ResourceSourceError>
        ) async {
            guard terminalResult == nil else { return }
            terminalResult = result
            let continuation = self.continuation
            self.continuation = nil
            renderTask?.cancel()
            deadlineTask?.cancel()
            renderTask = nil
            deadlineTask = nil
            let session = activeSession
            activeSession = nil
            let mediaLease = activeMediaLease
            activeMediaLease = nil

            if let mediaLease {
                await mediaLease.close()
            } else {
                // Close before publication so timeout and cancellation immediately
                // terminate source operations instead of waiting for rendering cleanup.
                await session?.close()
            }
            if let continuation {
                Self.resume(continuation, with: result)
            }
        }

        private static func resume(
            _ continuation: CheckedContinuation<GeneratedPreview, any Error>,
            with result: Result<GeneratedPreview, ResourceSourceError>
        ) {
            switch result {
            case .success(let generated):
                continuation.resume(returning: generated)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private static func mapError(_ error: any Error) -> ResourceSourceError {
        if error is CancellationError { return .cancelled }
        return ResourceSourceError.mapping(error)
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("iosRemoteFolder", isDirectory: true)
            .appendingPathComponent("previews-v1", isDirectory: true)
    }

    private static func loadManifest(
        at manifestURL: URL,
        cacheDirectory: URL
    ) -> [String: DiskManifestEntry] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [:] }
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: manifestURL.path),
              let manifestSize = attributes[.size] as? NSNumber,
              manifestSize.int64Value >= 0,
              manifestSize.int64Value <= maximumManifestBytes,
              let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
              let decoded = try? JSONDecoder().decode(
                  [String: DiskManifestEntry].self,
                  from: data
              ) else {
            try? fileManager.removeItem(at: cacheDirectory)
            return [:]
        }

        var manifest: [String: DiskManifestEntry] = [:]
        for (digest, entry) in decoded {
            let url = cacheDirectory.appendingPathComponent(digest + ".preview", isDirectory: false)
            guard digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  entry.byteCount >= 0,
                  entry.byteCount <= maximumDiskRecordBytes,
                  let fileAttributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let fileSize = fileAttributes[.size] as? NSNumber,
                  fileSize.int64Value == entry.byteCount else {
                try? fileManager.removeItem(at: url)
                continue
            }
            manifest[digest] = entry
        }

        var total = manifest.values.reduce(into: Int64(0)) { partial, entry in
            partial = partial.addingClamped(entry.byteCount)
        }
        for (digest, entry) in manifest.sorted(by: { $0.value.lastAccess < $1.value.lastAccess })
        where total > diskByteBudget {
            try? fileManager.removeItem(
                at: cacheDirectory.appendingPathComponent(digest + ".preview", isDirectory: false)
            )
            manifest.removeValue(forKey: digest)
            total = max(0, total - entry.byteCount)
        }

        if let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) {
            let retained = Set(manifest.keys.map { $0 + ".preview" })
            for url in files where url.pathExtension == "preview" && !retained.contains(url.lastPathComponent) {
                try? fileManager.removeItem(at: url)
            }
        }
        return manifest
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class QuickLookThumbnailContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private let request: QLThumbnailGenerator.Request
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private var terminalResult: Result<CGImage, ResourceSourceError>?

    init(request: QLThumbnailGenerator.Request) {
        self.request = request
    }

    func value() async throws -> CGImage {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, any Error>) in
                guard install(continuation) else { return }
                submit()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    private func install(
        _ continuation: CheckedContinuation<CGImage, any Error>
    ) -> Bool {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            Self.resume(continuation, with: terminalResult)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func submit() {
        lock.lock()
        let shouldSubmit = terminalResult == nil
        lock.unlock()
        guard shouldSubmit else { return }

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [weak self] representation, error in
            self?.complete(representation: representation, error: error)
        }

        // Cancellation may win after the preflight check but before Quick Look
        // accepts the request. Cancel again after submission in that narrow race.
        lock.lock()
        let wasCancelled: Bool
        if case .failure(.cancelled)? = terminalResult {
            wasCancelled = true
        } else {
            wasCancelled = false
        }
        lock.unlock()
        if wasCancelled {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }

    private func complete(
        representation: QLThumbnailRepresentation?,
        error: (any Error)?
    ) {
        let result: Result<CGImage, ResourceSourceError>
        if let error {
            result = .failure(ResourceSourceError.mapping(error))
        } else if let representation, representation.type == .thumbnail {
            result = .success(representation.cgImage)
        } else {
            result = .failure(.capabilityUnavailable)
        }
        finish(result)
    }

    private func cancel() {
        guard finish(.failure(.cancelled)) else { return }
        QLThumbnailGenerator.shared.cancel(request)
    }

    @discardableResult
    private func finish(
        _ result: Result<CGImage, ResourceSourceError>
    ) -> Bool {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return false
        }
        terminalResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if let continuation {
            Self.resume(continuation, with: result)
        }
        return true
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

private actor PreviewConcurrencyLimiter {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var active = 0
    private var order: [UUID] = []
    private var waiters: [UUID: Waiter] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if active < limit {
                    active += 1
                    continuation.resume()
                } else {
                    order.append(id)
                    waiters[id] = Waiter(continuation: continuation)
                }
            }
        }, onCancel: {
            Task { await self.cancel(id: id) }
        })
    }

    func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation.resume()
            return
        }
        active = max(0, active - 1)
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private extension ResourcePreviewArtifact {
    var previewMemoryCost: Int {
        switch self {
        case .encodedImage(let data, _, let pixelWidth, let pixelHeight):
            let (pixels, pixelOverflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
            let (decodedBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            let decodedCost = pixelOverflow || byteOverflow ? Int.max : decodedBytes
            return max(data.count, decodedCost)
        case .textExcerpt(let value):
            return value.utf8.count
        }
    }
}

private extension ResourceRevision {
    var previewPersistenceToken: String {
        switch self {
        case .etag(let value):
            "etag:\(value)"
        case .serverVersion(let value):
            "server:\(value)"
        case .modifiedAndSize(let modifiedAt, let byteSize):
            "modified:\(modifiedAt.timeIntervalSinceReferenceDate.bitPattern):\(byteSize)"
        case .unknown:
            "unknown"
        }
    }
}

private extension PropertyListEncoder {
    static var previewEncoder: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}

private extension Int {
    func addingClamped(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? Int.max : sum
    }
}

private extension Int64 {
    func addingClamped(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? Int64.max : sum
    }
}
