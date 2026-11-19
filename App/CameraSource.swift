import AVFoundation
import CoreImage
import CoreVideo
import QuartzCore

/// Wraps the real webcam and keeps the most recent frame around for the engine.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "zoomie.camera", qos: .userInteractive)
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    private var lastFrameTime: CFTimeInterval = 0

    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    /// True if a frame arrived in the last second.
    var isReceivingFrames: Bool {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - lastFrameTime < 1
    }

    /// Input cameras. The virtual cameras we send to (Zoomie Cam, OBS Virtual
    /// Camera) are filtered out so we never feed our output back into itself.
    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices
            .filter {
                $0.uniqueID != SinkFeeder.deviceUID && $0.modelID != SinkFeeder.modelID
                    && $0.localizedName != SinkFeeder.obsDeviceName
            }
    }

    /// True if OBS's virtual camera is installed and enabled (it only shows up once approved).
    static var obsVirtualCameraAvailable: Bool {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.contains { $0.localizedName == SinkFeeder.obsDeviceName }
    }

    /// Full stop and start, for when the session stopped delivering frames
    /// (e.g. interrupted while the Mac slept) but still reports itself running.
    func restart(deviceID: String?) {
        queue.async { [self] in session.stopRunning() }
        start(deviceID: deviceID)
    }

    // MARK: Fake camera

    /// While set, a picture file stands in for the webcam (for marketing screenshots):
    /// the real camera is never opened, so no permission prompt and nobody's face.
    private var fakeTimer: DispatchSourceTimer?

    /// Shows `imageURL` as the camera feed, filling a 1920x1080 frame.
    func startFake(imageURL: URL) {
        guard let source = CIImage(contentsOf: imageURL, options: [.applyOrientationProperty: true]) else {
            NSLog("Zoomie Toolz: fake camera couldn't read %@", imageURL.path)
            return
        }
        let width: CGFloat = 1920, height: CGFloat = 1080
        let scale = max(width / source.extent.width, height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filled = scaled.transformed(by: CGAffineTransform(
            translationX: (width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (height - scaled.extent.height) / 2 - scaled.extent.minY))
        let ctx = CIContext()
        // A few copies, handed out in turn, so every "frame" is a new buffer like a real camera's.
        let buffers: [CVPixelBuffer] = (0..<3).compactMap { _ in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(width), Int(height), kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &pb)
            if let pb { ctx.render(filled, to: pb) }
            return pb
        }
        guard !buffers.isEmpty else { return }
        queue.async { [self] in
            session.stopRunning()
            var index = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                index = (index + 1) % buffers.count
                lock.lock(); _latest = buffers[index]; lastFrameTime = CACurrentMediaTime(); lock.unlock()
            }
            timer.resume()
            fakeTimer = timer
            NSLog("Zoomie Toolz: fake camera showing %@", imageURL.lastPathComponent)
        }
    }

    func start(deviceID: String?) {
        queue.async { [self] in
            guard fakeTimer == nil else { return }  // the fake camera is in use
            lock.lock(); _latest = nil; lock.unlock()
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }

            let devices = Self.availableDevices()
            guard let device = devices.first(where: { $0.uniqueID == deviceID }) ?? devices.first,
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                NSLog("Zoomie Toolz: camera failed to open (found %d cameras)", devices.count)
                session.commitConfiguration()
                return
            }
            NSLog("Zoomie Toolz: using camera %@", device.localizedName)
            session.addInput(input)
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .hd1280x720

            if session.outputs.isEmpty {
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
            lock.lock(); _latest = nil; lock.unlock()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if lastFrameTime == 0 {
            NSLog("Zoomie Toolz: first camera frame %dx%d", CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        }
        lock.lock(); _latest = pb; lastFrameTime = CACurrentMediaTime(); lock.unlock()
    }
}
