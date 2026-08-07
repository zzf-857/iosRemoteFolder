import AVFoundation

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

