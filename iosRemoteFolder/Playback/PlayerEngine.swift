import AVFoundation
import Foundation

@MainActor
protocol PlayerEngine: AnyObject {
    var player: AVPlayer { get }
    func load(url: URL)
    func play()
    func pause()
}

@MainActor
final class AVPlayerEngine: PlayerEngine {
    let player = AVPlayer()

    func load(url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }
}

/// Data-backed audio playback used by the content viewer.
///
/// The viewer receives already-bounded bytes from `ResourceContentSession`; this
/// engine owns the AVFoundation object and keeps playback controls on the main
/// actor without exposing a source adapter or URL to the UI.
@MainActor
final class AVAudioPlayerEngine {
    let player: AVAudioPlayer

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
    }

    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { seek(to: newValue) }
    }
    var isPlaying: Bool { player.isPlaying }

    @discardableResult
    func play() -> Bool {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to time: TimeInterval) {
        let upperBound = max(player.duration, 0)
        player.currentTime = min(max(time, 0), upperBound)
    }

    func stop() {
        player.stop()
        player.currentTime = 0
    }
}

/// Data-backed video playback used by the content viewer.
///
/// AVPlayer normally needs a URL. The resource loader keeps the URL private to
/// Playback and serves the already-bounded session bytes by byte range, so the
/// viewer never reaches an adapter, request header, or file-system path.
@MainActor
final class AVVideoPlayerEngine {
    let player: AVPlayer

    private let asset: AVURLAsset
    private let resourceLoader: InMemoryAssetResourceLoader
    private var isStopped = false

    init(data: Data) {
        let loader = InMemoryAssetResourceLoader(
            data: data,
            contentType: "public.mpeg-4"
        )
        let url = URL(string: "iosremotefolder-video://asset/\(UUID().uuidString).mp4")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        self.asset = asset
        self.resourceLoader = loader
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player.automaticallyWaitsToMinimizeStalling = false
    }

    var duration: TimeInterval {
        guard let duration = player.currentItem?.duration,
              duration.isNumeric else { return 0 }
        return max(0, duration.seconds)
    }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    func prepare() async throws {
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw ResourceSourceError.invalidResponse
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw ResourceSourceError.invalidResponse
        }
    }

    @discardableResult
    func play() -> Bool {
        guard !isStopped else { return false }
        player.play()
        return true
    }

    func pause() {
        player.pause()
    }

    func seek(to time: TimeInterval) {
        guard !isStopped, duration > 0 else { return }
        let clamped = min(max(time, 0), duration)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        resourceLoader.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

private final class InMemoryAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "iosRemoteFolder.video-resource-loader")

    private let data: Data
    private let contentType: String
    private let lock = NSLock()
    private var invalidated = false

    init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !isInvalidated else {
            loadingRequest.finishLoading(with: Self.cancelledError)
            return true
        }

        if let contentInformationRequest = loadingRequest.contentInformationRequest {
            contentInformationRequest.contentType = contentType
            contentInformationRequest.contentLength = Int64(data.count)
            contentInformationRequest.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let startOffset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        let requestedLength = Int64(dataRequest.requestedLength)
        let totalLength = Int64(data.count)
        guard startOffset >= 0,
              requestedLength >= 0,
              startOffset <= totalLength,
              requestedLength <= totalLength - startOffset,
              let start = Int(exactly: startOffset),
              let end = Int(exactly: startOffset + requestedLength) else {
            loadingRequest.finishLoading(with: Self.invalidRangeError)
            return true
        }

        if end > start {
            dataRequest.respond(with: data.subdata(in: start..<end))
        }
        loadingRequest.finishLoading()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Requests are served synchronously from immutable memory. AVFoundation
        // owns cancellation of any request that is still pending.
    }

    private var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    private static let cancelledError = NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorCancelled
    )

    private static let invalidRangeError = NSError(
        domain: "iosRemoteFolder.video-resource-loader",
        code: 1
    )
}
