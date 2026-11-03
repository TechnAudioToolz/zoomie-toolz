import Foundation
import CoreMediaIO
import CoreVideo
import CoreText
import IOKit.audio
import os.log

// Shared constants. The host app renders every frame to exactly this format
// before pushing it into the sink stream, so the extension never has to scale.
let kFrameRate: Int = 30
let kWidth: Int32 = 1920
let kHeight: Int32 = 1080
let kDefaultDeviceName = "Zoomie Cam"
let kDeviceUUID = UUID(uuidString: "6A1E0C55-2F1B-4E2A-9B7C-5A0F3D1C8E01")!
let kNameDefaultsKey = "cameraName"

/// Custom property the app sets to rename the camera. Value is a CFString.
let kRenameProperty = CMIOExtensionProperty(rawValue: "4cc_name_glob_0000")
let kPixelFormat = kCVPixelFormatType_32BGRA

private let log = Logger(subsystem: "com.kevinburns.zoomietoolz.extension", category: "provider")

// MARK: - Device

/// One virtual camera with two streams:
///  - source: what Zoom (or any app) reads from
///  - sink:   what the Zoomie Toolz app writes frames into
/// Frames arriving on the sink are forwarded to the source. If the app isn't
/// feeding us, a placeholder card is shown instead.
class ZoomieDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    private var sourceStream: ZoomieStreamSource!
    private var sinkStream: ZoomieSinkStreamSource!

    private var streamingCounter = 0
    private var sinkStarted = false
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrameHostTime: UInt64 = 0

    private let queue = DispatchQueue(label: "zoomie.device", qos: .userInteractive)
    private var placeholderTimer: DispatchSourceTimer?
    private var placeholderBuffer: CVPixelBuffer?
    private var videoDescription: CMFormatDescription!

    let name: String
    /// Called when the app asks for a new name. The provider swaps in a new device.
    var onRename: ((String) -> Void)?

    init(localizedName: String) {
        name = localizedName
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: kDeviceUUID, legacyDeviceID: kDeviceUUID.uuidString, source: self)

        let dims = CMVideoDimensions(width: kWidth, height: kHeight)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kPixelFormat,
                                       width: dims.width, height: dims.height, extensions: nil,
                                       formatDescriptionOut: &videoDescription)
        let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        let format = CMIOExtensionStreamFormat(formatDescription: videoDescription,
                                               maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration,
                                               validFrameDurations: nil)

        sourceStream = ZoomieStreamSource(localizedName: "Zoomie Cam.Video",
                                          streamID: UUID(uuidString: "6A1E0C55-2F1B-4E2A-9B7C-5A0F3D1C8E02")!,
                                          streamFormat: format, device: device)
        sinkStream = ZoomieSinkStreamSource(localizedName: "Zoomie Cam.Sink",
                                            streamID: UUID(uuidString: "6A1E0C55-2F1B-4E2A-9B7C-5A0F3D1C8E03")!,
                                            streamFormat: format, device: device)
        do {
            // Order matters: the host app looks up the sink as stream index 1.
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }

        placeholderBuffer = makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, kRenameProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            props.model = "Zoomie Cam"
        }
        if properties.contains(kRenameProperty) {
            props.setPropertyState(CMIOExtensionPropertyState(value: name as NSString), forProperty: kRenameProperty)
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        if let newName = deviceProperties.propertiesDictionary[kRenameProperty]?.value as? String {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != name { onRename?(trimmed) }
        }
    }

    /// Stops timers before this device is removed from the provider.
    func teardown() {
        queue.async {
            self.placeholderTimer?.cancel()
            self.placeholderTimer = nil
            self.sinkStarted = false
            self.sinkClient = nil
            self.streamingCounter = 0
        }
    }

    // MARK: Source (Zoom-facing) lifecycle

    func startStreaming() {
        queue.async {
            self.streamingCounter += 1
            guard self.placeholderTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(0))
            timer.setEventHandler { [weak self] in self?.placeholderTick() }
            timer.resume()
            self.placeholderTimer = timer
        }
    }

    func stopStreaming() {
        queue.async {
            self.streamingCounter = max(0, self.streamingCounter - 1)
            if self.streamingCounter == 0 {
                self.placeholderTimer?.cancel()
                self.placeholderTimer = nil
            }
        }
    }

    /// Sends the placeholder card whenever the app hasn't delivered a frame recently.
    private func placeholderTick() {
        let now = mach_absolute_time_ns()
        let sinkIsLive = sinkStarted && now &- lastSinkFrameHostTime < 500_000_000
        guard !sinkIsLive, streamingCounter > 0, let pb = placeholderBuffer else { return }
        if let sbuf = makeSampleBuffer(pb, hostTimeNs: now) {
            sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: now)
        }
    }

    // MARK: Sink (app-facing) lifecycle

    func startStreamingSink(client: CMIOExtensionClient) {
        queue.async {
            self.sinkClient = client
            self.sinkStarted = true
            self.consumeBuffer()
        }
    }

    func stopStreamingSink() {
        queue.async {
            self.sinkStarted = false
            self.sinkClient = nil
        }
    }

    private func consumeBuffer() {
        guard sinkStarted, let client = sinkClient else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, seq, _, _, _ in
            guard let self else { return }
            self.queue.async {
                if let sbuf {
                    let now = mach_absolute_time_ns()
                    self.lastSinkFrameHostTime = now
                    if self.streamingCounter > 0 {
                        self.sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: now)
                    }
                    self.sinkStream.stream.notifyScheduledOutputChanged(
                        CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds: now))
                    self.consumeBuffer()
                } else {
                    // Nothing queued yet; try again shortly instead of spinning.
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consumeBuffer() }
                }
            }
        }
    }

    // MARK: Helpers

    private func makeSampleBuffer(_ pb: CVPixelBuffer, hostTimeNs: UInt64) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(kFrameRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(hostTimeNs), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &desc)
        guard let desc else { return nil }
        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                 formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sbuf)
        return sbuf
    }

    private func makePlaceholder() -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(kWidth), Int(kHeight), kPixelFormat, attrs as CFDictionary, &pb)
        guard let pb else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: Int(kWidth), height: Int(kHeight), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return pb }

        ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Int(kWidth), height: Int(kHeight)))

        let font = CTFontCreateWithName("Helvetica Neue" as CFString, 56, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.6, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(name) — open Zoomie Toolz", attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (CGFloat(kWidth) - bounds.width) / 2, y: (CGFloat(kHeight) - bounds.height) / 2)
        CTLineDraw(line, ctx)
        return pb
    }
}

private func mach_absolute_time_ns() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

// MARK: - Source stream (read by Zoom)

class ZoomieStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet { if activeFormatIndex >= 1 { log.error("Invalid format index") } }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex { activeFormatIndex = idx }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? ZoomieDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        (device.source as? ZoomieDeviceSource)?.stopStreaming()
    }
}

// MARK: - Sink stream (written by the Zoomie Toolz app)

class ZoomieSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) { props.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { props.sinkBuffersRequiredForStartup = 1 }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex { activeFormatIndex = idx }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else { return }
        (device.source as? ZoomieDeviceSource)?.startStreamingSink(client: client)
    }

    func stopStream() throws {
        (device.source as? ZoomieDeviceSource)?.stopStreamingSink()
    }
}

// MARK: - Provider

class ZoomieProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: ZoomieDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        let savedName = UserDefaults.standard.string(forKey: kNameDefaultsKey) ?? kDefaultDeviceName
        do {
            try addDevice(named: savedName)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    private func addDevice(named name: String) throws {
        let source = ZoomieDeviceSource(localizedName: name)
        source.onRename = { [weak self] newName in
            // Don't tear the device down from inside its own property callback.
            DispatchQueue.main.async { self?.rename(to: newName) }
        }
        try provider.addDevice(source.device)
        deviceSource = source
    }

    /// CMIO device names are fixed at creation, so renaming means replacing
    /// the device. Same device ID, so apps can recognize it as the same camera.
    private func rename(to newName: String) {
        log.info("Renaming camera to \(newName, privacy: .public)")
        UserDefaults.standard.set(newName, forKey: kNameDefaultsKey)
        if let old = deviceSource {
            old.teardown()
            try? provider.removeDevice(old.device)
        }
        do {
            try addDevice(named: newName)
        } catch {
            log.error("Rename failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { props.manufacturer = "Zoomie Toolz" }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
