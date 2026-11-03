import AppKit
import ApplicationServices
import Combine

/// Turns your video on/off in Zoom by pressing Zoom's own "Start Video" /
/// "Stop Video" menu item through the Accessibility API. Reading that item's
/// title also tells us whether video is currently on. Needs Accessibility
/// permission for Zoomie Toolz (System Settings → Privacy & Security).
final class ZoomVideoControl: ObservableObject {
    enum State: Equatable {
        case needsPermission
        case zoomNotRunning
        case notInMeeting
        case videoOn
        case videoOff
    }

    @Published private(set) var state: State = .zoomNotRunning

    private var timer: Timer?

    init() {
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to the Accessibility settings.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func toggle() {
        guard isTrusted else {
            requestPermission()
            return
        }
        guard let item = videoMenuItem()?.element else {
            refresh()
            return
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        // Zoom updates the menu title a moment after the press.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func refresh() {
        let newState: State
        if !isTrusted {
            newState = .needsPermission
        } else if zoomApp == nil {
            newState = .zoomNotRunning
        } else if let item = videoMenuItem() {
            newState = item.title.hasPrefix("Stop") ? .videoOn : .videoOff
        } else {
            newState = .notInMeeting
        }
        if newState != state { state = newState }
    }

    private var zoomApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: ZoomLeaver.zoomBundleID).first
    }

    /// Zoom only has a "Start Video"/"Stop Video" menu item while you're in a meeting.
    private func videoMenuItem() -> (element: AXUIElement, title: String)? {
        guard let app = zoomApp else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar: AXUIElement = attribute(appElement, kAXMenuBarAttribute) else { return nil }
        for barItem in children(of: menuBar) {
            for menu in children(of: barItem) {
                for item in children(of: menu) {
                    guard let title: String = attribute(item, kAXTitleAttribute) else { continue }
                    if title.hasPrefix("Start Video") || title.hasPrefix("Stop Video") {
                        return (item, title)
                    }
                }
            }
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
