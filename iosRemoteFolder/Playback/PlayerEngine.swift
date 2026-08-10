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
