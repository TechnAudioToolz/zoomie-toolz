import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var leaver: ZoomLeaver
    @EnvironmentObject var installer: ExtensionInstaller
    @EnvironmentObject var zoomVideo: ZoomVideoControl
    @EnvironmentObject var updater: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    @State private var cameras: [AVCaptureDevice] = []
    /// Defaults to the next top of the hour at launch (6:01pm → 7:00pm).
    @State private var leaveTime = ContentView.nextTopOfHour()
    @State private var nameDraft = ""

    var body: some View {
        // Previews stay pinned at the top and grow with the window; the controls
        // scroll underneath so the window can still fit a laptop screen.
        VStack(alignment: .leading, spacing: 12) {
            previews
                .padding([.horizontal, .top], 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    zoomVideoBar
                    cameraSection
                    Divider()
                    leaveSection
                    Divider()
                    setupSection
                    Divider()
                    updatesSection
                }
                .padding([.horizontal, .bottom], 20)
                .padding(.top, 4)
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .toolbar {
            Button { NSWorkspace.shared.open(projectsURL) } label: { Label("More Apps", systemImage: "square.grid.2x2") }
                .help("More free apps from TechnAudioToolz")
            Button { openDonatePage() } label: { Label("Donate", systemImage: "heart") }
                .help("Donate: support this project")
        }
        .onAppear {
            refreshCameras()
            nameDraft = engine.cameraName
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshCameras() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshCameras() }
    }

    static func nextTopOfHour(after date: Date = Date()) -> Date {
        Calendar.current.nextDate(after: date, matching: DateComponents(minute: 0, second: 0),
                                  matchingPolicy: .nextTime) ?? date.addingTimeInterval(3600)
    }

    /// Keeps the camera list current and makes sure a real camera is selected.
    private func refreshCameras() {
        cameras = CameraSource.availableDevices()
        if !cameras.contains(where: { $0.uniqueID == engine.selectedCameraID }), let first = cameras.first {
            engine.selectedCameraID = first.uniqueID
        }
    }

    /// Big Start/Stop Video button that drives Zoom's own video toggle.
    private var zoomVideoBar: some View {
        HStack(spacing: 12) {
            switch zoomVideo.state {
            case .needsPermission:
                Button { zoomVideo.requestPermission() } label: {
                    Label("Allow Zoom Control…", systemImage: "lock.open")
                }
                Text("Needs Accessibility permission to press Start/Stop Video in Zoom.")
                    .font(.caption).foregroundStyle(.secondary)
            case .zoomNotRunning, .notInMeeting:
                Button {} label: { Label("Zoom Video", systemImage: "video.slash") }
                    .disabled(true)
                Text(zoomVideo.state == .zoomNotRunning ? "Zoom isn't running." : "Join a Zoom meeting to use this.")
                    .font(.caption).foregroundStyle(.secondary)
            case .videoOn, .videoOff:
                let on = zoomVideo.state == .videoOn
                Button { zoomVideo.toggle() } label: {
                    Label(on ? "Stop Zoom Video" : "Start Zoom Video", systemImage: on ? "video.slash.fill" : "video.fill")
                        .frame(minWidth: 150)
                }
                .controlSize(.large)
                .tint(on ? .red : .green)
                .buttonStyle(.borderedProminent)
                Text(on ? "Your video is ON in Zoom" : "Your video is OFF in Zoom")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(on ? .green : .secondary)
            }
            Spacer()
            Text("⌃⌥V").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var selectedCameraName: String {
        cameras.first { $0.uniqueID == engine.selectedCameraID }?.localizedName
            ?? cameras.first?.localizedName ?? "No camera"
    }

    /// Raw camera input and the final output (what Zoom sees), side by side.
    private var previews: some View {
        HStack(alignment: .top, spacing: 12) {
            previewTile("Input: \(selectedCameraName)", window: "input") {
                LiveVideoView(feed: engine.inputFeed)
                    .overlay {
                        if engine.cameraDenied {
                            VStack(spacing: 6) {
                                Text("Camera access is off for Zoomie Toolz").font(.caption)
                                Button("Open Camera Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                                }
                                .controlSize(.small)
                            }
                            .foregroundStyle(.white)
                        } else if !engine.cameraConnected {
                            Text("Waiting for camera…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
            }
            previewTile("Output: what Zoom sees", window: "output") {
                LiveVideoView(feed: engine.outputFeed)
                    .overlay(alignment: .topLeading) { badge }
            }
        }
    }

    /// Thumbnail of the current picture; click to choose another.
    private var picturePreview: some View {
        ZStack {
            Color.black
            if let image = engine.stillPreview {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text("No picture").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { pickImage() }
        .help("Picture preview. Click to choose a different picture.")
    }

    private func previewTile<Content: View>(_ title: String, window: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { openWindow(id: window) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help("Open in its own window")
            }
            content()
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var badge: some View {
        Group {
            if engine.isRecording {
                Label(String(format: "REC %.0fs", engine.recordingSeconds), systemImage: "record.circle")
                    .foregroundStyle(.white).padding(6).background(.red, in: Capsule())
            } else if engine.mode == .loop {
                Label("LOOP", systemImage: "repeat")
                    .foregroundStyle(.white).padding(6).background(.blue, in: Capsule())
            } else if engine.mode == .image {
                Label("IMAGE", systemImage: "photo")
                    .foregroundStyle(.white).padding(6).background(.purple, in: Capsule())
            } else if engine.mode == .black {
                Label("BLACK", systemImage: "rectangle.fill")
                    .foregroundStyle(.white).padding(6).background(.gray, in: Capsule())
            } else {
                Label("LIVE", systemImage: "video.fill")
                    .foregroundStyle(.white).padding(6).background(.green, in: Capsule())
            }
        }
        .font(.caption.bold())
        .padding(8)
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Camera", selection: $engine.selectedCameraID) {
                    ForEach(cameras, id: \.uniqueID) { cam in
                        Text(cam.localizedName).tag(Optional(cam.uniqueID))
                    }
                }
                .frame(maxWidth: 280)
            }

            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { engine.mode }, set: { engine.setMode($0) })) {
                    Text("Live").tag(Engine.Mode.live)
                    Text("Loop").tag(Engine.Mode.loop)
                    Text("Image").tag(Engine.Mode.image)
                    Text("Black").tag(Engine.Mode.black)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .disabled(engine.isRecording)

                Button(engine.isRecording ? "Stop Recording" : "Record Loop") {
                    engine.toggleRecording()
                }
                .tint(engine.isRecording ? .red : nil)

                Button { engine.playLastRecording() } label: {
                    Label("Play Last Recording", systemImage: "play.fill")
                }
                .disabled(!engine.hasRecording && !engine.isRecording)
                .help("Loop your most recent recording in Zoom (⌃⌥P)")

                Button("Load Video…") { pickVideo() }
                    .disabled(engine.isRecording)
                Button { showRecordingsFolder() } label: { Image(systemName: "folder") }
                    .help("Show your recordings folder in Finder")
            }

            Toggle("Auto-play after recording", isOn: $engine.autoPlayAfterRecording)
                .help("When you stop recording, Zoom switches straight to the new loop")

            HStack(spacing: 10) {
                Toggle("Blur background", isOn: $engine.blurBackground)
                Slider(value: $engine.blurAmount, in: 4...40) { Text("Amount") }
                    .frame(width: 180)
                    .disabled(!engine.blurBackground)
            }

            HStack(spacing: 10) {
                picturePreview
                VStack(alignment: .leading, spacing: 6) {
                    Text("Picture").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Choose Image…") { pickImage() }
                        Button("Freeze Frame") { engine.freezeFrame() }
                            .disabled(!engine.cameraConnected)
                            .help("Use what the camera shows right now as the still image")
                        Button { engine.toggleBlack() } label: {
                            Label(engine.mode == .black ? "Unblack" : "Black",
                                  systemImage: engine.mode == .black ? "rectangle" : "rectangle.fill")
                        }
                        .help(engine.mode == .black ? "Go back to what was showing before (⌃⌥K)"
                                                    : "Show a plain black screen in Zoom (⌃⌥K)")
                        Button { engine.setMode(.live) } label: {
                            Label("Live", systemImage: "video.fill")
                        }
                        .disabled(engine.mode == .live || engine.isRecording)
                        .help("Go straight back to your live camera")
                    }
                }
            }
            .disabled(engine.isRecording)

            Text(engine.loopName.map { "Loop: \($0)" } ?? "No loop yet. Record a few seconds of yourself, then switch to Loop.")
                .font(.caption).foregroundStyle(.secondary)
            Text(engine.imageName.map { "Image: \($0)" } ?? "No image yet. Choose a picture or freeze the current frame.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Hotkeys work anywhere: ⌃⌥L Live/Loop · ⌃⌥I Live/Image · ⌃⌥K black · ⌃⌥B blur · ⌃⌥R record · ⌃⌥P play last recording · ⌃⌥V Zoom video")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var leaveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leave Zoom automatically").font(.headline)
            if let time = leaver.scheduledTime {
                HStack {
                    Text("Leaving at \(time.formatted(date: .omitted, time: .shortened)) (in \(format(leaver.remaining)))")
                    Spacer()
                    Button("Cancel") { leaver.cancel() }
                }
            } else {
                HStack {
                    DatePicker("At", selection: $leaveTime, displayedComponents: .hourAndMinute)
                        .frame(width: 140)
                    Button("Schedule") { leaver.schedule(at: leaveTime) }
                    Spacer()
                    ForEach([15, 30, 60], id: \.self) { m in
                        Button("\(m)m") { leaver.schedule(inMinutes: m) }
                    }
                }
            }
            HStack {
                Button("Leave Now") { leaver.leaveNow() }
                if let result = leaver.lastResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Virtual camera").font(.headline)
                Spacer()
                Circle()
                    .fill(engine.outputConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(engine.outputConnected ? "Sending to \(engine.outputTarget.label)" : "Not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Send video to", selection: $engine.outputTarget) {
                Text("OBS Virtual Camera (free, no developer account)").tag(SinkFeeder.Target.obs)
                Text("Zoomie Cam (needs Apple Developer signing)").tag(SinkFeeder.Target.zoomieCam)
            }
            .frame(maxWidth: 460)

            switch engine.outputTarget {
            case .obs:
                obsHelp
            case .zoomieCam:
                zoomieCamSetup
            }
        }
    }

    private var updatesSection: some View {
        HStack(spacing: 12) {
            Text("Updates").font(.headline)
            Toggle("Check automatically", isOn: $updater.checkAutomatically)
                .help("Once a day at launch, asks GitHub for the latest version number. Nothing else is sent.")
            Button("Check Now") { updater.check(manual: true) }
                .disabled(updater.isChecking)
            Text(updater.status ?? "Version \(UpdateChecker.currentVersion)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var obsHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            if engine.outputConnected {
                Text("In Zoom, choose “OBS Virtual Camera” under Settings → Video. OBS itself doesn't need to be open.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("One-time setup: install OBS Studio (free), open it, click “Start Virtual Camera” and approve it in System Settings, then quit OBS. Zoomie Toolz connects automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Get OBS Studio…") { NSWorkspace.shared.open(URL(string: "https://obsproject.com/download")!) }
                    .controlSize(.small)
            }
        }
    }

    private var zoomieCamSetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Install") { installer.install() }
                Button("Uninstall") { installer.uninstall() }
                Text(installer.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField("Camera name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit { engine.renameCamera(to: nameDraft) }
                Button("Rename") { engine.renameCamera(to: nameDraft) }
                    .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty || nameDraft == engine.cameraName)
            }
            Text(engine.renameStatus ?? "Zoom lists it as “\(engine.cameraName)”.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Opens the recordings folder with the last take selected.
    private func showRecordingsFolder() {
        if LoopRecorder.hasSavedTake {
            NSWorkspace.shared.activateFileViewerSelecting([LoopRecorder.defaultURL])
        } else {
            NSWorkspace.shared.open(LoopRecorder.directory)
        }
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.directoryURL = LoopRecorder.directory
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadLoop(url)
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadImage(url)
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
