import AVFoundation
import CoreVideo

/// Records the engine's live output frames to an H.264 movie.
final class LoopRecorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private let lock = NSLock()

    private(set) var isRecording = false

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zoomie Toolz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("loop.mov")
    }

    func start(to url: URL = LoopRecorder.defaultURL, width: Int, height: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.startTime = nil
        isRecording = true
    }

    func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, let writer, let input, let adaptor else { return }
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        if input.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
    }

    /// Finishes the file. Completion runs on the main queue with the URL, or nil on failure.
    func stop(completion: @escaping (URL?) -> Void) {
        lock.lock()
        guard isRecording, let writer, let input else {
            lock.unlock()
            completion(nil)
            return
        }
        isRecording = false
        let hadFrames = startTime != nil
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        lock.unlock()

        guard hadFrames else {
            writer.cancelWriting()
            DispatchQueue.main.async { completion(nil) }
            return
        }
        input.markAsFinished()
        writer.finishWriting {
            let url = writer.status == .completed ? writer.outputURL : nil
            DispatchQueue.main.async { completion(url) }
        }
    }
}
