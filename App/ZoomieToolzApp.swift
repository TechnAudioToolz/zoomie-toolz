import SwiftUI
import Carbon.HIToolbox

@main
struct ZoomieToolzApp: App {
    @StateObject private var engine = Engine()
    @StateObject private var leaver = ZoomLeaver()
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var zoomVideo = ZoomVideoControl()
    @StateObject private var updater = UpdateChecker()
    @State private var hotKeys = HotKeys()
    @State private var started = false

    private var menuIcon: String {
        switch engine.mode {
        case .live: return "video.circle"
        case .loop: return "repeat.circle.fill"
        case .image: return "photo.circle.fill"
        case .black: return "rectangle.fill"
        }
    }

    var body: some Scene {
        Window("Zoomie Toolz", id: "main") {
            ContentView()
                .environmentObject(engine)
                .environmentObject(leaver)
                .environmentObject(installer)
                .environmentObject(zoomVideo)
                .environmentObject(updater)
                .onAppear {
                    guard !started else { return }
                    started = true
                    engine.start()
                    hotKeys.register(keyCode: kVK_ANSI_L) { [engine] in engine.toggleMode() }
                    hotKeys.register(keyCode: kVK_ANSI_R) { [engine] in engine.toggleRecording() }
                    hotKeys.register(keyCode: kVK_ANSI_I) { [engine] in engine.toggleImage() }
                    hotKeys.register(keyCode: kVK_ANSI_B) { [engine] in engine.toggleBlur() }
                    hotKeys.register(keyCode: kVK_ANSI_K) { [engine] in engine.toggleBlack() }
                    hotKeys.register(keyCode: kVK_ANSI_P) { [engine] in engine.playLastRecording() }
                    hotKeys.register(keyCode: kVK_ANSI_V) { [zoomVideo] in zoomVideo.toggle() }
                    // Let the window draw first, then walk through anything that's missing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        LaunchChecks.run(engine: engine, zoomVideo: zoomVideo)
                        updater.checkAtLaunchIfDue()
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 880)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check(manual: true) }
                Button("Check Setup…") { LaunchChecks.run(engine: engine, zoomVideo: zoomVideo, manual: true) }
            }
            CommandGroup(after: .windowArrangement) {
                OpenWindowButton(title: "Input Window", id: "input")
                    .keyboardShortcut("1", modifiers: [.command, .option])
                OpenWindowButton(title: "Output Window", id: "output")
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("Support this project…") { openDonatePage() }
                Button("More apps on GitHub") { NSWorkspace.shared.open(projectsURL) }
            }
        }

        Window("Input: Camera", id: "input") {
            LiveVideoView(feed: engine.inputFeed)
                .frame(minWidth: 320, minHeight: 180)
                .background(.black)
        }
        .defaultSize(width: 1280, height: 720)

        Window("Output: What Zoom Sees", id: "output") {
            LiveVideoView(feed: engine.outputFeed)
                .frame(minWidth: 320, minHeight: 180)
                .background(.black)
        }
        .defaultSize(width: 1280, height: 720)

        MenuBarExtra("Zoomie Toolz", systemImage: menuIcon) {
            Button(engine.mode == .loop ? "Switch to Live" : "Switch to Loop") { engine.toggleMode() }
                .disabled(!engine.hasLoop)
            Button(engine.mode == .image ? "Switch to Live" : "Show Image") { engine.toggleImage() }
                .disabled(!engine.hasImage)
            Button("Freeze Frame") { engine.freezeFrame() }
            Button(engine.mode == .black ? "Unblack" : "Black Screen") { engine.toggleBlack() }
            Toggle("Blur Background", isOn: Binding(get: { engine.blurBackground }, set: { engine.blurBackground = $0 }))
            Button(engine.isRecording ? "Stop Recording" : "Record Loop") { engine.toggleRecording() }
            Button("Play Last Recording") { engine.playLastRecording() }
                .disabled(!engine.hasRecording && !engine.isRecording)
            Divider()
            Button(zoomVideo.state == .videoOn ? "Stop Zoom Video" : "Start Zoom Video") { zoomVideo.toggle() }
                .disabled(zoomVideo.state == .zoomNotRunning || zoomVideo.state == .notInMeeting)
            if let time = leaver.scheduledTime {
                Text("Leaving Zoom at \(time.formatted(date: .omitted, time: .shortened))")
                Button("Cancel Auto-Leave") { leaver.cancel() }
            }
            Button("Leave Zoom Now") { leaver.leaveNow() }
            Divider()
            OpenWindowButton(title: "Show Input Window", id: "input")
            OpenWindowButton(title: "Show Output Window", id: "output")
            Divider()
            Button("Check Setup…") {
                NSApp.activate(ignoringOtherApps: true)
                LaunchChecks.run(engine: engine, zoomVideo: zoomVideo, manual: true)
            }
            Button("Check for Updates…") {
                NSApp.activate(ignoringOtherApps: true)
                updater.check(manual: true)
            }
            Button("Donate…") { openDonatePage() }
            Button("Quit Zoomie Toolz") { NSApp.terminate(nil) }
        }
    }
}

let projectsURL = URL(string: "https://github.com/TechnAudioToolz")!

/// The donation page ships inside the app and opens in the default browser.
func openDonatePage() {
    if let page = Bundle.main.url(forResource: "donate", withExtension: "html") {
        NSWorkspace.shared.open(page)
    }
}

/// Menu items can't read @Environment(\.openWindow) directly, so they use this.
struct OpenWindowButton: View {
    let title: String
    let id: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: id)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
