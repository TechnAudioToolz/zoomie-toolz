import AppKit
import AVFoundation

/// Walks through everything Zoomie Toolz needs, at launch (and from the
/// "Check Setup…" menu item), and explains anything missing with a popup.
///
/// Order: OBS installed → OBS Virtual Camera approved → camera access.
/// Accessibility (only for the Start/Stop Zoom Video button) is never asked
/// at launch; it's mentioned only by "Check Setup…" and asked when the
/// button is used.
enum LaunchChecks {
    static let obsBundleID = "com.obsproject.obs-studio"

    /// - Parameter manual: true when the user asked for it; also reports "all good".
    static func run(engine: Engine, zoomVideo: ZoomVideoControl, manual: Bool = false) {
        var allGood = true

        if engine.outputTarget == .obs {
            if !obsInstalled {
                allGood = false
                if askOBSMissing() == .quit { NSApp.terminate(nil); return }
            } else if !CameraSource.obsVirtualCameraAvailable {
                allGood = false
                askOBSCameraOff()
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            allGood = false
            askCameraAccess()
        default:
            break // .notDetermined is handled by the system prompt when the camera starts.
        }

        if manual && allGood {
            let alert = NSAlert()
            alert.messageText = "Everything's set up"
            alert.informativeText = "The virtual camera is ready and the camera is allowed. In Zoom, choose “\(engine.outputTarget.label)” under Settings → Video."
                + (zoomVideo.isTrusted ? "" : "\n\nOptional: the Start/Stop Zoom Video button needs Accessibility permission. It asks the first time you use it.")
            alert.runModal()
        }
    }

    static var obsInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: obsBundleID) != nil
    }

    // MARK: Popups

    private enum OBSChoice { case download, later, quit }

    private static func askOBSMissing() -> OBSChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Zoomie Toolz requires OBS Studio"
        alert.informativeText = """
            Zoomie Toolz sends its video to Zoom through OBS Virtual Camera, which comes with the free OBS Studio app.

            1. Download and install OBS Studio.
            2. Open it once and click “Start Virtual Camera”.
            3. Allow it in System Settings → Privacy & Security, then quit OBS.
            """
        alert.addButton(withTitle: "Download OBS Studio")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Quit")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://obsproject.com/download")!)
            return .download
        case .alertThirdButtonReturn:
            return .quit
        default:
            return .later
        }
    }

    private static func askOBSCameraOff() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Turn on OBS Virtual Camera"
        alert.informativeText = """
            OBS Studio is installed, but its virtual camera isn't turned on yet. This only has to be done once:

            1. Click “Open OBS”, then click “Start Virtual Camera” (bottom right).
            2. If macOS says system software was blocked, click “Open Privacy & Security” and click Allow.
            3. Quit OBS. Zoomie Toolz connects on its own.
            """
        alert.addButton(withTitle: "Open OBS")
        alert.addButton(withTitle: "Open Privacy & Security")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: obsBundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?General")!)
        default:
            break
        }
    }

    private static func askCameraAccess() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Zoomie Toolz needs camera access"
        alert.informativeText = "Camera access is turned off, so there's no live video to pass to Zoom. Turn on Zoomie Toolz in System Settings → Privacy & Security → Camera, then reopen the app."
        alert.addButton(withTitle: "Open Camera Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
        }
    }
}
