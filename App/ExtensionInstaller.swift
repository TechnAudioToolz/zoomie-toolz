import Foundation
import SystemExtensions

/// Installs / uninstalls the Zoomie Cam system extension embedded in this app.
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var status = "Not checked"

    private var extensionID: String {
        (Bundle.main.bundleIdentifier ?? "com.kevinburns.zoomietoolz") + ".camera"
    }

    func install() {
        status = "Installing…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        status = "Removing…"
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve it in System Settings → General → Login Items & Extensions → Camera Extensions"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: status = "Installed. Restart Zoom and pick “Zoomie Cam”."
        case .willCompleteAfterReboot: status = "Installed — finishes after a reboot."
        @unknown default: status = "Done (\(result.rawValue))"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue {
            status = "Move Zoomie Toolz into /Applications first, then try again."
        } else if nsError.code == OSSystemExtensionError.codeSignatureInvalid.rawValue
                    || nsError.code == OSSystemExtensionError.missingEntitlement.rawValue {
            status = "This build isn't signed with an Apple Developer Team, so macOS won't install the camera. "
                + "Set DEVELOPMENT_TEAM in Config/Signing.xcconfig, build in Xcode, and run it from /Applications."
        } else {
            status = "Failed: \(error.localizedDescription)"
        }
    }
}
