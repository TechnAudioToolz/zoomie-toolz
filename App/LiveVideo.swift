import AVFoundation
import SwiftUI

/// A stream of frames that any number of live video views can show.
/// Frames go straight to each view's display layer, bypassing SwiftUI, so
/// previews run at full frame rate without re-rendering the window.
final class FrameFeed {
    private let lock = NSLock()
    private var layers: [WeakLayer] = []

    private struct WeakLayer { weak var layer: AVSampleBufferDisplayLayer? }

    func add(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); defer { lock.unlock() }
        layers.removeAll { $0.layer == nil || $0.layer === layer }
        layers.append(WeakLayer(layer: layer))
    }

    func remove(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); defer { lock.unlock() }
        layers.removeAll { $0.layer == nil || $0.layer === layer }
    }

    /// Call from any thread.
    func push(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let targets = layers.compactMap(\.layer)
        lock.unlock()
        guard !targets.isEmpty, let sample = Self.makeSample(pixelBuffer) else { return }
        for layer in targets {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }

    private static func makeSample(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// Live video from a FrameFeed.
struct LiveVideoView: NSViewRepresentable {
    let feed: FrameFeed

    func makeNSView(context: Context) -> LiveVideoNSView {
        let view = LiveVideoNSView()
        view.attach(to: feed)
        return view
    }

    func updateNSView(_ view: LiveVideoNSView, context: Context) {
        view.attach(to: feed)
    }

    static func dismantleNSView(_ view: LiveVideoNSView, coordinator: ()) {
        view.detach()
    }
}

final class LiveVideoNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private weak var feed: FrameFeed?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(to feed: FrameFeed) {
        guard self.feed !== feed else { return }
        self.feed?.remove(displayLayer)
        self.feed = feed
        feed.add(displayLayer)
    }

    func detach() {
        feed?.remove(displayLayer)
        feed = nil
    }
}
