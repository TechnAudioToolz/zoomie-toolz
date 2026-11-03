import AVFoundation
import CoreVideo
import QuartzCore

/// Plays a movie file on an endless loop and hands out the current frame on demand.
final class LoopPlayer {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var lastFrame: CVPixelBuffer?

    private(set) var url: URL?

    func load(_ url: URL) {
        stop()
        self.url = url
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        let looper = AVPlayerLooper(player: player, templateItem: item)

        // Each looped copy of the item needs its own video output; an output
        // can only belong to one item.
        for loopItem in looper.loopingPlayerItems {
            loopItem.add(AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]))
        }

        self.player = player
        self.looper = looper
    }

    func play() { player?.play() }

    func pause() { player?.pause() }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        player = nil
        looper = nil
        lastFrame = nil
        url = nil
    }

    /// The frame that should be on screen right now (or the previous one if nothing new).
    func currentFrame() -> CVPixelBuffer? {
        guard let output = player?.currentItem?.outputs.lazy.compactMap({ $0 as? AVPlayerItemVideoOutput }).first
        else { return lastFrame }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            lastFrame = pb
        }
        return lastFrame
    }
}
