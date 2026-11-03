import AVFoundation
import AppKit
import CoreImage
import CoreVideo
import Combine
import Vision

/// Owns the whole pipeline: camera + loop player + still image in, one
/// 1920x1080 frame out every 1/30s to the virtual camera (and the previews).
final class Engine: ObservableObject {
    enum Mode: String { case live, loop, image, black }

    // 1080p to match OBS Virtual Camera's advertised format (Zoomie Cam uses the same).
    static let width = 1920
    static let height = 1080
    static let fps = 30.0
    private static let crossfade = 0.35

    @Published private(set) var mode: Mode = .live
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0.0
    @Published private(set) var hasLoop = false
    @Published private(set) var loopName: String?
    /// True once a loop has been recorded (kept on disk between launches).
    @Published private(set) var hasRecording = FileManager.default.fileExists(atPath: LoopRecorder.defaultURL.path)
    /// Switch Zoom straight to the new loop when a recording stops.
    @Published var autoPlayAfterRecording = UserDefaults.standard.object(forKey: "autoPlayAfterRecording") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPlayAfterRecording, forKey: "autoPlayAfterRecording") }
    }
    @Published private(set) var hasImage = false
    @Published private(set) var imageName: String?
    @Published private(set) var cameraConnected = false
    @Published private(set) var cameraDenied = false
    /// Which virtual camera Zoom should be pointed at.
    @Published var outputTarget = SinkFeeder.Target(rawValue: UserDefaults.standard.string(forKey: "outputTarget") ?? "") ?? .obs {
        didSet {
            UserDefaults.standard.set(outputTarget.rawValue, forKey: "outputTarget")
            let target = outputTarget
            renderQueue.async { self.sink.target = target }
        }
    }
    /// True while frames are reaching the chosen virtual camera.
    @Published private(set) var outputConnected = false
    /// What Zoom lists the virtual camera as.
    @Published private(set) var cameraName = UserDefaults.standard.string(forKey: "cameraName") ?? "Zoomie Cam"
    @Published private(set) var renameStatus: String?
    /// Blurs everything behind you in the live camera feed (person segmentation via Vision).
    @Published var blurBackground = UserDefaults.standard.bool(forKey: "blurBackground") {
        didSet {
            UserDefaults.standard.set(blurBackground, forKey: "blurBackground")
            let on = blurBackground
            renderQueue.async { self.renderBlur = on; self.lastCameraBuffer = nil }
        }
    }
    /// Blur radius in pixels.
    @Published var blurAmount = UserDefaults.standard.object(forKey: "blurAmount") as? Double ?? 18 {
        didSet {
            UserDefaults.standard.set(blurAmount, forKey: "blurAmount")
            let amount = blurAmount
            renderQueue.async { self.renderBlurAmount = amount; self.lastCameraBuffer = nil }
        }
    }
    @Published var selectedCameraID: String? = UserDefaults.standard.string(forKey: "cameraID") {
        didSet {
            UserDefaults.standard.set(selectedCameraID, forKey: "cameraID")
            camera.start(deviceID: selectedCameraID)
        }
    }

    /// Live output (what Zoom sees), for previews and the Output window.
    let outputFeed = FrameFeed()
    /// Live raw frames from the selected camera, before any effects.
    let inputFeed = FrameFeed()
    /// Thumbnail of the current still image.
    @Published private(set) var stillPreview: NSImage?

    let camera = CameraSource()
    private let player = LoopPlayer()
    private let recorder = LoopRecorder()
    private let sink = SinkFeeder()

    private let renderQueue = DispatchQueue(label: "zoomie.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?

    // Render-queue state.
    private var renderMode: Mode = .live
    private var previousMode: Mode = .live
    private var transitionStart: CFTimeInterval = 0
    private var lastLive: CIImage?
    private var lastLoop: CIImage?
    private var still: CIImage?
    private var lastCameraBuffer: CVPixelBuffer?
    private var renderBlur = false
    private var renderBlurAmount = 18.0
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let sequenceHandler = VNSequenceRequestHandler()
    private var recordStart: CFTimeInterval = 0
    private var recordFrameIndex: Int64 = 0
    private var tickCount = 0

    init() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        sink.target = outputTarget
        renderBlur = blurBackground
        renderBlurAmount = blurAmount

        if FileManager.default.fileExists(atPath: LoopRecorder.defaultURL.path) {
            loadLoop(LoopRecorder.defaultURL)
        }
        if let image = CIImage(contentsOf: Self.stillURL) {
            still = aspectFill(image)
            stillPreview = NSImage(contentsOf: Self.stillURL)
            hasImage = true
            imageName = UserDefaults.standard.string(forKey: "imageName") ?? "Saved image"
        }
    }

    /// The current still image, normalized to the output size as a PNG so it survives restarts.
    static var stillURL: URL {
        LoopRecorder.defaultURL.deletingLastPathComponent().appendingPathComponent("still.png")
    }

    func start() {
        startCamera()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Self.fps, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func startCamera() {
        NSLog("Zoomie Toolz: camera permission %d", AVCaptureDevice.authorizationStatus(for: .video).rawValue)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera.start(deviceID: selectedCameraID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraDenied = !granted
                    if granted { self.camera.start(deviceID: self.selectedCameraID) }
                }
            }
        default:
            cameraDenied = true
        }
    }

    // MARK: Controls (main thread)

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        if newMode == .loop && !hasLoop { return }
        if newMode == .image && !hasImage { return }
        mode = newMode
        if newMode == .loop { player.play() }
        renderQueue.async {
            self.previousMode = self.renderMode
            self.renderMode = newMode
            self.transitionStart = CACurrentMediaTime()
        }
    }

    func toggleMode() {
        setMode(mode == .loop ? .live : .loop)
    }

    func toggleImage() {
        setMode(mode == .image ? .live : .image)
    }

    private var modeBeforeBlack: Mode = .live

    /// Black screen on/off. Turning it off goes back to whatever was showing before.
    func toggleBlack() {
        if mode == .black {
            setMode(modeBeforeBlack)
        } else {
            modeBeforeBlack = mode
            setMode(.black)
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        // Always record what the camera sees, even if we're showing something else.
        if mode != .live { setMode(.live) }
        player.stop()
        hasLoop = false
        hasRecording = false  // the new take replaces the old file
        loopName = nil
        do {
            try recorder.start(width: Self.width, height: Self.height)
        } catch {
            NSLog("Zoomie Toolz: recording failed to start: \(error)")
            return
        }
        isRecording = true
        recordingSeconds = 0
        renderQueue.async {
            self.recordStart = CACurrentMediaTime()
            self.recordFrameIndex = 0
            self.lastLoop = nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recorder.stop { [weak self] url in
            guard let self, let url else { return }
            self.hasRecording = true
            self.loadLoop(url)
            if self.autoPlayAfterRecording { self.setMode(.loop) }
        }
    }

    func renameCamera(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendRename(trimmed)
    }

    private func sendRename(_ name: String) {
        renderQueue.async {
            let ok = self.sink.rename(to: name)
            DispatchQueue.main.async {
                if ok {
                    self.cameraName = name
                    UserDefaults.standard.set(name, forKey: "cameraName")
                    self.renameStatus = "Renamed. Restart Zoom to see the new name."
                } else {
                    self.renameStatus = "Couldn't reach the virtual camera. Is it installed?"
                }
            }
        }
    }

    /// Uses an image file (any format Core Image reads) as the still.
    func loadImage(_ url: URL) {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return }
        setStill(image, name: url.lastPathComponent)
    }

    /// Grabs whatever the camera is showing right now and uses it as the still.
    func freezeFrame() {
        renderQueue.async {
            guard let frame = self.lastLive else { return }
            DispatchQueue.main.async { self.setStill(frame, name: "Frozen frame") }
        }
    }

    private func setStill(_ image: CIImage, name: String) {
        let filled = aspectFill(image)
            .composited(over: CIImage(color: .black))
            .cropped(to: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        // Render once so we keep a flat bitmap instead of a filter chain on the source file.
        guard let cg = ciContext.createCGImage(filled, from: filled.extent) else { return }
        let flat = CIImage(cgImage: cg)
        try? ciContext.writePNGRepresentation(of: flat, to: Self.stillURL, format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        UserDefaults.standard.set(name, forKey: "imageName")
        hasImage = true
        imageName = name
        stillPreview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        renderQueue.async { self.still = flat }
        setMode(.image)
    }

    /// Loads the most recent recording (even if another video was loaded since) and loops it.
    func playLastRecording() {
        if isRecording {
            // Finish the take first; it becomes the last recording.
            isRecording = false
            recorder.stop { [weak self] url in
                guard let self, let url else { return }
                self.hasRecording = true
                self.loadLoop(url)
                self.setMode(.loop)
            }
            return
        }
        guard hasRecording else { return }
        if player.url != LoopRecorder.defaultURL { loadLoop(LoopRecorder.defaultURL) }
        setMode(.loop)
    }

    func loadLoop(_ url: URL) {
        player.load(url)
        hasLoop = true
        loopName = url == LoopRecorder.defaultURL ? "Recorded loop" : url.lastPathComponent
        if mode == .loop { player.play() }
    }

    // MARK: Render loop

    private func tick() {
        let now = CACurrentMediaTime()

        // Only process each camera frame once; segmentation isn't free.
        if let pb = camera.latestFrame, pb !== lastCameraBuffer {
            lastCameraBuffer = pb
            inputFeed.push(pb)
            let image = renderBlur ? blurringBackground(of: pb) : CIImage(cvPixelBuffer: pb)
            lastLive = aspectFill(image)
        }
        let inTransition = now - transitionStart < Self.crossfade
        if renderMode == .loop || (inTransition && previousMode == .loop) {
            if let pb = player.currentFrame() {
                lastLoop = aspectFill(CIImage(cvPixelBuffer: pb))
            }
        }

        // Live without camera frames shows a "Camera starting…" card, so it can
        // never be mistaken for the black screen.
        let live = camera.isReceivingFrames ? lastLive : noCameraCard
        func frame(for mode: Mode) -> CIImage? {
            switch mode {
            case .live: return live
            case .loop: return lastLoop
            case .image: return still
            case .black: return Self.blackFrame
            }
        }
        let target = frame(for: renderMode)
        let other = frame(for: previousMode)
        let progress = min(1, (now - transitionStart) / Self.crossfade)

        var image: CIImage
        if let target, let other, progress < 1 {
            image = other.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: target,
                kCIInputTimeKey: progress,
            ])
        } else if let target {
            image = target
        } else {
            image = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.1))
        }
        image = image.cropped(to: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))

        guard let pool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let out else { return }
        ciContext.render(image, to: out)

        sink.send(out)
        outputFeed.push(out)

        if recorder.isRecording && renderMode == .live && lastLive != nil && camera.isReceivingFrames {
            let t = CMTime(value: recordFrameIndex, timescale: CMTimeScale(Self.fps))
            recorder.append(out, at: t)
            recordFrameIndex += 1
        }

        // Status a few times a second is plenty and keeps the main thread quiet.
        tickCount += 1
        if tickCount % 6 == 0 {
            let connected = camera.isReceivingFrames
            let sinkConnected = sink.isConnected
            let elapsed = now - recordStart
            DispatchQueue.main.async {
                if self.cameraConnected != connected { self.cameraConnected = connected }
                if self.outputConnected != sinkConnected { self.outputConnected = sinkConnected }
                if self.isRecording { self.recordingSeconds = elapsed }
            }
        }
    }

    func toggleBlur() {
        blurBackground.toggle()
    }

    /// Keeps the person sharp and blurs everything else. Falls back to the
    /// plain frame if Vision can't find a mask.
    private func blurringBackground(of pb: CVPixelBuffer) -> CIImage {
        let image = CIImage(cvPixelBuffer: pb)
        guard (try? sequenceHandler.perform([segmentation], on: pb)) != nil,
              let maskBuffer = segmentation.results?.first?.pixelBuffer else { return image }

        var mask = CIImage(cvPixelBuffer: maskBuffer)
        mask = mask.transformed(by: CGAffineTransform(scaleX: image.extent.width / mask.extent.width,
                                                      y: image.extent.height / mask.extent.height))
        // Soften the cutout edge so hair and shoulders don't look clipped.
        mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: image.extent)

        let background = image.clampedToExtent()
            .applyingGaussianBlur(sigma: renderBlurAmount)
            .cropped(to: image.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        ])
    }

    private static let blackFrame = CIImage(color: .black)
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

    /// Dark card with a message, shown in Live while the camera has no frames.
    private lazy var noCameraCard: CIImage = {
        let size = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let background = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.14)).cropped(to: size)
        guard let text = CIFilter(name: "CITextImageGenerator", parameters: [
            "inputText": "Camera starting…",
            "inputFontName": "HelveticaNeue",
            "inputFontSize": 64,
            "inputScaleFactor": 1,
        ])?.outputImage else { return background }
        // The generator draws black text; turn it light gray.
        let dimmed = text.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: 0.75, y: 0.75, z: 0.78, w: 0),
        ])
        let x = (size.width - text.extent.width) / 2 - text.extent.minX
        let y = (size.height - text.extent.height) / 2 - text.extent.minY
        return dimmed.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: background)
    }()

    /// Scales and centers an image so it fills the 16:9 output frame.
    private func aspectFill(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = max(CGFloat(Self.width) / extent.width, CGFloat(Self.height) / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (CGFloat(Self.width) - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (CGFloat(Self.height) - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}
