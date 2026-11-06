import AVFoundation
import CoreVideo
import QuartzCore

/// Plays a movie file on an endless loop and hands out the current frame on demand.
///
/// Uses one AVPlayer + AVPlayerItemVideoOutput and seeks back to the start
/// at the end. (AVPlayerLooper was tried first, but video outputs added to
/// its looping copies never attach, so no frames ever came out.)
final class LoopPlayer {
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var endObserver: NSObjectProtocol?
    private var lastFrame: CVPixelBuffer?
    private let lock = NSLock()

    private(set) var url: URL?

    func load(_ url: URL) {
        stop()
        self.url = url
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player?.play()
        }

        self.player = player
        self.output = output
    }

    func play() { player?.play() }

    /// Jumps back to the first frame and plays.
    func restart() {
        lock.lock(); lastFrame = nil; lock.unlock()
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }

    func pause() { player?.pause() }

    func stop() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        output = nil
        lock.lock(); lastFrame = nil; lock.unlock()
        url = nil
    }

    /// The frame that should be on screen right now (or the previous one if nothing new).
    func currentFrame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let output else { return lastFrame }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            lastFrame = pb
        }
        return lastFrame
    }
}
