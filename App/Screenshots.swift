import AppKit
import CoreGraphics

/// Marketing screenshots:
///
///     open -a "Zoomie Toolz" --args --fake-camera person.jpg --screenshots ~/Desktop/shots
///
/// Captures the main window in the dark theme in a few states. Use it with
/// `--fake-camera` and a picture of someone who doesn't exist, so no real face
/// or room is in the shots. The app captures only its own window, which needs
/// no Screen Recording permission.
enum Screenshots {
    static func run(engine: Engine, into folder: URL, picture: URL?, waited: Double = 0) {
        // Wait for video so the previews aren't empty.
        guard engine.cameraConnected || waited >= 30 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                run(engine: engine, into: folder, picture: picture, waited: waited + 0.5)
            }
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // The Picture thumbnail would otherwise show the user's own saved picture.
        if let picture { engine.showTemporaryStill(picture) }
        guard let window = NSApp.windows.first(where: { $0.title == "Zoomie Toolz" }) else {
            NSLog("Zoomie Toolz: screenshots: main window not found")
            return
        }
        // Just tall enough to show every control without scrolling or blank space.
        let screen = window.screen ?? NSScreen.main!
        let height = min(1090, screen.visibleFrame.height - 20)
        window.setFrame(NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - height - 10,
                               width: 1240, height: height), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let shots: [(name: String, setup: () -> Void)] = [
            ("zoomie-toolz-party-hat", { engine.setMode(.live); engine.funnyFace = .partyHat }),
            ("zoomie-toolz-googly-eyes", { engine.funnyFace = .googlyEyes }),
            ("zoomie-toolz-sunglasses", { engine.funnyFace = .sunglasses }),
            ("zoomie-toolz-mask", { engine.funnyFace = .clownMask }),
        ]
        for (i, shot) in shots.enumerated() {
            let start = 1.5 + Double(i) * 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + start) { shot.setup() }
            DispatchQueue.main.asyncAfter(deadline: .now() + start + 2.5) {
                window.makeFirstResponder(nil)  // no highlighted text field in the shot
                capture(window, to: folder.appendingPathComponent(shot.name + ".png"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(shots.count) * 3.0 + 0.5) {
            engine.funnyFace = .off
            NSApp.appearance = nil
            NSLog("Zoomie Toolz: screenshots done, saved in %@", folder.path)
        }
    }

    // CGWindowListCreateImage is deprecated in macOS 14 but still works, and capturing
    // our own window with it needs no Screen Recording permission (ScreenCaptureKit does).
    private static func capture(_ window: NSWindow, to url: URL) {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            NSLog("Zoomie Toolz: screenshot failed for %@", url.lastPathComponent)
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("Zoomie Toolz: saved %@ (%dx%d)", url.lastPathComponent, image.width, image.height)
    }
}
