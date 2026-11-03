import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

/// Pushes frames into a virtual camera's sink stream using the CoreMediaIO
/// C API. Connects lazily and retries until the camera is there.
///
/// Two targets are supported:
///  - Zoomie Cam: our own extension (needs Apple Developer signing to install)
///  - OBS Virtual Camera: OBS Studio's signed camera extension, which accepts
///    frames from any app the same way. Free, no developer account needed.
final class SinkFeeder {
    enum Target: String, CaseIterable, Identifiable {
        case obs, zoomieCam
        var id: String { rawValue }
        var label: String {
            switch self {
            case .obs: return "OBS Virtual Camera"
            case .zoomieCam: return "Zoomie Cam"
            }
        }
    }

    /// Changing the target drops the current connection; the next frame reconnects.
    var target: Target = .obs {
        didSet { if target != oldValue { disconnect(); lastAttempt = .distantPast } }
    }

    static let obsDeviceName = "OBS Virtual Camera"

    /// Fixed device ID from the extension. The camera's display name can be
    /// changed, so we never look it up by name.
    static let deviceUID = "6A1E0C55-2F1B-4E2A-9B7C-5A0F3D1C8E01"
    static let modelID = "Zoomie Cam"
    private static let renameSelector = CMIOObjectPropertySelector(0x6E61_6D65) // 'name'

    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private(set) var isConnected = false
    private var lastAttempt = Date.distantPast

    /// Returns true if the frame was queued.
    @discardableResult
    func send(_ pixelBuffer: CVPixelBuffer) -> Bool {
        if !isConnected {
            // Don't hammer CMIO lookups every frame.
            guard Date().timeIntervalSince(lastAttempt) > 1 else { return false }
            lastAttempt = Date()
            connect()
            guard isConnected else { return false }
        }
        guard let queue else { return false }
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) { return false }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &desc)
        guard let desc else { return false }
        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard let sbuf else { return false }
        // The queue takes ownership of the retained buffer.
        return CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sbuf).toOpaque()) == noErr
    }

    func disconnect() {
        if isConnected {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
        isConnected = false
        queue = nil
    }

    /// Asks the extension to rename the camera. Returns false if it isn't installed/running.
    @discardableResult
    func rename(to name: String) -> Bool {
        guard target == .zoomieCam, let device = findDevice() else { return false }
        var addr = CMIOObjectPropertyAddress(mSelector: Self.renameSelector,
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let cfName = name as CFString
        var value = Unmanaged.passUnretained(cfName)
        let status = CMIOObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<CFString>.size), &value)
        withExtendedLifetime(cfName) {}
        // The extension replaces the device, so our sink stream is gone. Reconnect on the next frame.
        disconnect()
        lastAttempt = Date()
        return status == noErr
    }

    private func connect() {
        guard let device = findDevice() else { return }
        let streams = streamIDs(of: device)
        // Both extensions register [source, sink] in that order.
        guard streams.count >= 2 else { return }
        let sink = streams[1]

        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanagedQueue)
        guard status == noErr, let q = unmanagedQueue?.takeRetainedValue() else { return }
        guard CMIODeviceStartStream(device, sink) == noErr else { return }

        deviceID = device
        sinkStreamID = sink
        queue = q
        isConnected = true
        NSLog("Zoomie Toolz: connected to %@", target.label)
    }

    private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func findDevice() -> CMIOObjectID? {
        var addr = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        var used: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == noErr else { return nil }

        for device in devices {
            switch target {
            case .zoomieCam:
                if stringProperty(kCMIODevicePropertyDeviceUID, of: device) == Self.deviceUID
                    || stringProperty(kCMIODevicePropertyModelUID, of: device) == Self.modelID {
                    return device
                }
            case .obs:
                if stringProperty(kCMIOObjectPropertyName, of: device) == Self.obsDeviceName {
                    return device
                }
            }
        }
        return nil
    }

    private func stringProperty(_ selector: Int, of object: CMIOObjectID) -> String? {
        var addr = address(selector)
        var size: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        var value: Unmanaged<CFString>?
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func streamIDs(of device: CMIOObjectID) -> [CMIOStreamID] {
        var addr = address(kCMIODevicePropertyStreams)
        var size: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return [] }
        var streams = [CMIOStreamID](repeating: 0, count: Int(size) / MemoryLayout<CMIOStreamID>.size)
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &streams) == noErr else { return [] }
        return streams
    }
}
