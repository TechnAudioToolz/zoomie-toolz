import Foundation
import CoreMediaIO

let providerSource = ZoomieProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
