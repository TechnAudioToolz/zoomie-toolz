<p align="center"><img src="Art/AppIcon.png" width="160" alt="Zoomie Toolz icon"></p>

# Zoomie Toolz

A free Mac app that sits between your webcam and Zoom. Loop a clip of yourself, show a picture or a black screen, blur your background, turn your Zoom video on and off from anywhere, and leave meetings on time. Everything runs on your Mac: no accounts, no uploads, no telemetry.

Video reaches Zoom through **OBS Virtual Camera** (part of the free OBS Studio), so no Apple Developer account is needed.

## Download

**[Zoomie-Toolz-1.2.2.dmg](https://github.com/TechnAudioToolz/zoomie-toolz/releases/latest)** (under Assets on the latest release, about 2.5 MB)

- Needs **macOS 14 Sonoma or newer**, on Apple Silicon or Intel.
- Open the `.dmg` and drag **Zoomie Toolz** to Applications.
- **First launch:** the app isn't registered with Apple, so macOS blocks it once. Go to **System Settings → Privacy & Security** and click **Open Anyway**. You only do this once.

## One-time setup

1. Install **[OBS Studio](https://obsproject.com/download)** (free), or `brew install --cask obs`.
2. Open OBS once and click **Start Virtual Camera** (bottom right).
3. macOS says system software was blocked. Allow it:
   - **macOS 14 Sonoma:** System Settings → **Privacy & Security** → click **Allow** next to the OBS message.
   - **macOS 15 or newer:** System Settings → General → **Login Items & Extensions** → Camera Extensions → turn on OBS.
4. Quit OBS. It doesn't need to be open after this.
5. Open Zoomie Toolz and allow camera access. The **Virtual camera** dot turns green when it's sending video.
6. In Zoom: **Settings → Video → Camera → OBS Virtual Camera**.

Zoomie Toolz checks all of this every time it opens and shows a popup explaining anything that's missing. Run the checks again any time from **Zoomie Toolz → Check Setup…** or the menu bar.

## What it does

- **Live previews:** *Input* (your camera, untouched) and *Output* (exactly what Zoom sees) side by side. The window resizes and the previews grow with it. The ↗ button on each opens it in its own window (`⌥⌘1` / `⌥⌘2`).
- **Live:** passes your camera straight through.
- **Loop:** **Record Loop** (`⌃⌥R`), sit naturally for 10–30 seconds, and stop. With **Auto-play after recording** on (the default), Zoom switches straight to the clip on repeat. **Play Last Recording** (`⌃⌥P`) loops your most recent take any time, even after loading another video. **Load Video…** loops any movie file instead, and the folder button next to it opens your recordings folder in Finder. If a take records nothing, Zoomie tells you why and keeps your previous recording.
- **Image:** show a still instead of live video (`⌃⌥I`). **Choose Image…** picks any picture and **Freeze Frame** grabs what your camera shows right now. Click the picture thumbnail to choose another.
- **Black** (`⌃⌥K`): a plain black screen, like having your camera off while your Zoom video stays on. Press it again (**Unblack**) to go back to whatever was showing before, or press **Live** next to it to go straight to your camera.
- **Blur background** (`⌃⌥B`): keeps you sharp and blurs everything behind you, with a strength slider. Uses Apple's on-device person detection. Loops recorded and frames frozen with blur on are blurred too.
- **Start/Stop Zoom Video** (`⌃⌥V`): presses Zoom's own Start/Stop Video for you and shows whether your video is on. Optional: it's the only feature that needs Accessibility permission, and it asks the first time you use it (never at launch).
- **Leave Zoom automatically:** force-quits Zoom at a set time, or in 15/30/60 minutes, which drops you straight out of the meeting (no "leave meeting?" prompt, no special permissions). The time is filled in with the next top of the hour when the app opens (open at 6:01 pm → 7:00 pm). **Leave Now** does it straight away.
- **Cuts or fades:** switching between Live, Loop, Image and Black is a hard cut by default. The **Fade between modes** slider adds a fade of up to 1 second. Play Last Recording always starts the loop from its first frame.
- **Updates:** **Zoomie Toolz → Check for Updates…** (also in the menu bar, and **Check Now** in the window) asks GitHub for the latest release and offers the new DMG. With **Check automatically** on (the default) it checks quietly once a day at launch and only speaks up when there's a new version; **Skip This Version** stops the reminder for that release. The only thing sent is one request for the public release info on GitHub. Nothing is installed by itself.
- **Hotkeys work anywhere**, even while Zoom is in front. All controls are also in the **menu bar**, so you can close the window and keep it running.

Tip: for a loop nobody notices, start and end the clip in roughly the same pose.

If the camera stops sending video (for example after your Mac sleeps), Zoomie restarts it by itself. If the camera isn't sending frames yet (for example while macOS is still asking for camera permission), Live shows a "Camera starting…" card.

Zoomie Toolz has to stay running for Zoom to see your video. If it's closed, OBS Virtual Camera shows OBS's placeholder.

## Building from source

Needs Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/TechnAudioToolz/zoomie-toolz.git && cd zoomie-toolz
xcodegen generate                 # only needed after editing project.yml
scripts/make_offline_dmg.sh       # the release DMG: build/Zoomie-Toolz-<version>.dmg
```

For a quick debug build that runs in place:

```bash
xcodebuild -project ZoomieToolz.xcodeproj -scheme ZoomieToolz -derivedDataPath build/preview CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= ENABLE_HARDENED_RUNTIME=NO build && open "build/preview/Build/Products/Debug/Zoomie Toolz.app"
```

## Optional: your own "Zoomie Cam" (paid Apple Developer account)

The project also contains its own camera extension, **Zoomie Cam**, which shows up in Zoom under its own name (and can be renamed from the app). macOS only installs camera extensions signed by a paid Apple Developer account, so the release DMG leaves it out and uses OBS Virtual Camera instead.

1. Set `DEVELOPMENT_TEAM` in `Config/Signing.xcconfig` (and optionally `APP_BUNDLE_ID`).
2. Open `ZoomieToolz.xcodeproj`, check Signing & Capabilities for both targets (System Extension on the app, App Groups on the extension), and build.
3. Copy **Zoomie Toolz.app** to /Applications and open it from there.
4. Under **Virtual camera**, choose **Send video to: Zoomie Cam**, click **Install**, and approve it in System Settings.
5. Restart Zoom and choose **Zoomie Cam**.

## How it works

```
Webcam ─▶ Zoomie Toolz ─(CoreMediaIO sink stream)─▶ OBS Virtual Camera  ─▶ Zoom
            │ 30 fps, 1920x1080                     (or Zoomie Cam)
            │ live / loop / image, blur, crossfade
            └▶ loop recording (H.264, ~/Library/Application Support/Zoomie Toolz/)
```

OBS's camera extension and Zoomie Cam both have a "sink" stream that accepts frames from another app and passes them to whatever app is reading the camera. Zoomie Toolz renders every frame and pushes it into that sink.

| File | What it does |
|---|---|
| `App/Engine.swift` | 30 fps render loop: live / loop / image, blur, crossfade, recording |
| `App/SinkFeeder.swift` | Finds the virtual camera through CoreMediaIO and sends frames into its sink |
| `App/CameraSource.swift` | The real webcam (AVCaptureSession) |
| `App/LoopPlayer.swift`, `App/LoopRecorder.swift` | Looping playback and recording |
| `App/LiveVideo.swift` | Live preview views and windows |
| `App/ZoomVideoControl.swift` | Reads and presses Zoom's Start/Stop Video menu item (Accessibility) |
| `App/ZoomLeaver.swift` | Scheduled Zoom quit |
| `App/UpdateChecker.swift` | Checks GitHub's latest release and offers the download |
| `App/LaunchChecks.swift` | Setup checks and popups at launch |
| `App/HotKeys.swift` | Global hotkeys (no Accessibility needed) |
| `App/ExtensionInstaller.swift`, `Extension/` | The optional Zoomie Cam camera extension |
| `scripts/make_offline_dmg.sh` | Builds the release DMG |
| `Resources/donate.html` | The Donate page |

## Troubleshooting

- **macOS keeps asking for camera or Accessibility permission:** every new build of the app (each update, or each time you build it yourself) is a "new app" to macOS, because it isn't signed with an Apple Developer certificate. Install it once in /Applications and open it from there; it keeps its permissions until you update it. If System Settings already shows Zoomie Toolz as allowed but it still asks, remove the old entry (−) and allow it again.

- **Zoom shows the OBS logo instead of you:** make sure Zoomie Toolz is open and the Virtual camera dot is green. Quit and reopen Zoom if it was open before OBS's camera was approved.
- **"OBS Virtual Camera" missing in Zoom:** the OBS approval didn't finish. Run **Check Setup…** and follow the popup.
- **Start/Stop Zoom Video stays grey:** allow Zoomie Toolz under Privacy & Security → Accessibility. If you rebuild the app yourself, macOS may ask again; remove the old entry and add it back.
- **"Join a Zoom meeting" while you're in one:** the button looks for Zoom's "Start Video" / "Stop Video" menu items, so a Zoom set to another language won't match yet.
- **No camera in the Input preview:** allow Zoomie Toolz under Privacy & Security → Camera.

## Support

Zoomie Toolz is free. If it's useful, the **Donate** button (heart in the toolbar) opens the support page. More free, offline Mac tools from [TechnAudioToolz](https://github.com/TechnAudioToolz).

Not affiliated with Zoom Video Communications or the OBS Project.

## License

MIT. See [LICENSE](LICENSE).
