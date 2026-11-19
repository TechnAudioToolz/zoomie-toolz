import AVFoundation
import CoreImage

/// `--probe-obs`: end-to-end check of what Zoom actually receives. Turns on heavy
/// pixelation, then reads one frame back from OBS Virtual Camera (as Zoom would)
/// and saves it beside Zoomie's own output frame, in Application Support/Zoomie
/// Toolz/obs-probe. Restores the lag settings afterwards. For testing.
final class OBSProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static var current: OBSProbe?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "zoomie.obs-probe")
    private var frames = 0
    private let dir: URL
    private let done: () -> Void

    private init(dir: URL, done: @escaping () -> Void) {
        self.dir = dir
        self.done = done
    }

    static func run(engine: Engine, waited: Double = 0) {
        guard engine.cameraConnected || waited >= 30 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(engine: engine, waited: waited + 0.5) }
            return
        }
        let dir = LoopRecorder.directory.appendingPathComponent("obs-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = (engine.lagEnabled, engine.lagPixelation, engine.lagFPS)
        engine.setMode(.live)
        engine.lagPixelation = 40
        engine.lagFPS = Engine.fps
        engine.lagEnabled = true
        NSLog("Zoomie Toolz: probe: lag on (40 px blocks), output connected: %d", engine.outputConnected ? 1 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            engine.snapshotOutput(to: dir.appendingPathComponent("zoomie-output.png"))
            let probe = OBSProbe(dir: dir) {
                engine.lagEnabled = saved.0
                engine.lagPixelation = saved.1
                engine.lagFPS = saved.2
                NSLog("Zoomie Toolz: probe done, files in %@", dir.path)
            }
            current = probe
            probe.start()
        }
    }

    private func start() {
        guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first(where: { $0.localizedName == SinkFeeder.obsDeviceName }),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            NSLog("Zoomie Toolz: probe: couldn't open OBS Virtual Camera")
            done()
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        queue.async { self.session.startRunning() }
        // Give up after 10 s if nothing arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.frames < 30 else { return }
            NSLog("Zoomie Toolz: probe: only %d frames from OBS Virtual Camera", self.frames)
            self.finish()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        guard frames == 30, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }  // ~1 s in
        let url = dir.appendingPathComponent("obs-virtual-camera.png")
        try? CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: pb), to: url, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        NSLog("Zoomie Toolz: probe: saved frame from OBS Virtual Camera (%dx%d)",
              CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        DispatchQueue.main.async { self.finish() }
    }

    private func finish() {
        queue.async { self.session.stopRunning() }
        done()
        OBSProbe.current = nil
    }
}
