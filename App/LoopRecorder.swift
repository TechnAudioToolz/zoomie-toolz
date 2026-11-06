import AVFoundation
import CoreVideo

/// Records the engine's live output frames to an H.264 movie.
///
/// Each take is written to a temporary file and only replaces the saved loop
/// once it finishes successfully, so a failed take never wipes the last good one.
final class LoopRecorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    /// Timestamps are counted here, reset under the same lock as start(), so a
    /// frame can never be stamped with a stale count from a previous take.
    private var nextFrameIndex: Int64 = 0
    private var framesWritten = 0
    private var framesDropped = 0
    private var destination: URL?
    private let lock = NSLock()

    private(set) var isRecording = false

    enum Outcome {
        case saved(URL, frames: Int)
        case noFrames
        case failed(String)
    }

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zoomie Toolz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The last good take.
    static var defaultURL: URL { directory.appendingPathComponent("loop.mov") }

    /// The take in progress.
    private static var takeURL: URL { directory.appendingPathComponent("loop-recording.mov") }

    /// True if there's a playable saved take (not an empty file from an older version).
    static var hasSavedTake: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: defaultURL.path)[.size] as? Int) ?? 0
        return size > 0
    }

    func start(to url: URL = LoopRecorder.defaultURL, width: Int, height: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let take = Self.takeURL
        try? FileManager.default.removeItem(at: take)
        let writer = try AVAssetWriter(outputURL: take, fileType: .mov)
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
        self.destination = url
        self.startTime = nil
        nextFrameIndex = 0
        framesWritten = 0
        framesDropped = 0
        isRecording = true
        NSLog("Zoomie Toolz: recording started")
    }

    /// Appends the next frame at `fps`. Frames are spaced evenly by count.
    func append(_ pixelBuffer: CVPixelBuffer, fps: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, let writer, let input, let adaptor else { return }
        let time = CMTime(value: nextFrameIndex, timescale: fps)
        nextFrameIndex += 1
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        if input.isReadyForMoreMediaData, adaptor.append(pixelBuffer, withPresentationTime: time) {
            framesWritten += 1
        } else {
            framesDropped += 1
            if framesDropped == 1 || framesDropped % 30 == 0 {
                NSLog("Zoomie Toolz: recording dropped frame (%d dropped, writer status %d, error: %@)",
                      framesDropped, writer.status.rawValue, Self.describe(writer.error))
            }
        }
    }

    /// The full error chain; AVFoundation's top-level message is usually just
    /// "The operation could not be completed".
    static func describe(_ error: Error?) -> String {
        guard var e = error as NSError? else { return "none" }
        var parts = ["\(e.domain) \(e.code): \(e.localizedDescription)"]
        while let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.domain) \(underlying.code)")
            e = underlying
        }
        return parts.joined(separator: " <- ")
    }

    /// Finishes the take. Completion runs on the main queue.
    func stop(completion: @escaping (Outcome) -> Void) {
        lock.lock()
        guard isRecording, let writer, let input, let destination else {
            lock.unlock()
            completion(.failed("Recording wasn't running."))
            return
        }
        isRecording = false
        let written = framesWritten, dropped = framesDropped
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        lock.unlock()
        NSLog("Zoomie Toolz: recording stopped (%d frames written, %d dropped, writer status %d)",
              written, dropped, writer.status.rawValue)

        guard written > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: Self.takeURL)
            let outcome: Outcome = writer.status == .failed
                ? .failed(writer.error?.localizedDescription ?? "The video encoder stopped.")
                : .noFrames
            DispatchQueue.main.async { completion(outcome) }
            return
        }
        input.markAsFinished()
        writer.finishWriting {
            let outcome: Outcome
            if writer.status == .completed {
                do {
                    // Swap the finished take in as the new last good take.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: writer.outputURL)
                    } else {
                        try FileManager.default.moveItem(at: writer.outputURL, to: destination)
                    }
                    outcome = .saved(destination, frames: written)
                } catch {
                    outcome = .failed(error.localizedDescription)
                }
            } else {
                outcome = .failed(writer.error?.localizedDescription ?? "The video file couldn't be finished.")
            }
            NSLog("Zoomie Toolz: recording finished: %@", "\(outcome)")
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
