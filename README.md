# SharpStream - macOS RTSP OCR Viewer

A native macOS (SwiftUI) player for live streams and video files. It can pause on the sharpest recent frame ("Smart Pause") and recognize text in that frame with Apple Vision.

Documentation lives in [docs/](docs/README.md).

## Features

### Playback
- Plays RTSP, SRT, UDP, HLS and HTTP(S) streams and local video files through libmpv (MPVKit).
- Hardware decoding with VideoToolbox (copy-back mode, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- Video is drawn with libmpv's render API into an OpenGL layer, so the picture follows window resizes, sidebar/inspector toggles and fullscreen.
- Play/pause, ±10 s skip, frame stepping (files), speed 0.25×–2×, volume.
- Files stay loaded at the end (`keep-open`), so a finished file can still be seeked and analyzed.

### Live rewind (DVR)
- Live streams can be paused and rewound inside mpv's seekable demuxer cache. The app does not keep its own frame buffer.
- The rewind window is set in Settings (10, 20, 30 or 40 minutes). The cache size is estimated from the stream bitrate and capped at 2 GB.
- The timeline shows wall-clock time and how far behind live you are; **Jump to Live** (⌘L) returns to the live edge.

### Smart Pause
- While playing, frames are sampled (4 FPS normally, dropping to 2 or 1 FPS when capture/scoring gets expensive or memory pressure rises) and scored for sharpness.
- Smart Pause (⌘S) picks the sharpest frame from the last 1–5 seconds (default 3), pauses, seeks exactly to it and shows that frame frozen on screen.
- Sharpness metrics: Laplacian variance (default), Tenengrad, Sobel. They run with vImage/vDSP on a luma plane downscaled to at most 960 px.
- Optionally runs text recognition on the selected frame (on by default).

### Text recognition (OCR)
- Apple Vision text recognition, on by default. Fast or Accurate level; languages as a comma-separated list or automatic detection; language correction off by default.
- **Recognize Text** (⌘R) pauses and recognizes the current frame.
- Recognized lines are outlined on the frozen frame (click a box to copy its line) and listed in the **Recognized Text** inspector panel with per-line confidence.

### Copy and export
- Copy recognized text (⇧⌘C) or the frame (⌥⌘C) to the clipboard.
- Save Frame As… (⌘E), Quick Save Frame (⇧⌘E) to the last-used folder, Export Recognized Text… (.txt), Export Frame with Text Boxes… (PNG/JPEG with the boxes and text drawn in).

### Library and statistics
- Sidebar with saved streams and recent streams. URLs are shown without user names, passwords or query strings.
- Add/edit streams with URL validation and a connection test.
- Files opened through the Open panel or drag and drop get a security-scoped bookmark, so they reopen from Recent/Saved after a relaunch despite the sandbox.
- Automatic reconnect for network streams with exponential backoff.
- Statistics window (⌥⌘I): connection and stream health, bitrate, receive rate, buffer level, jitter/loss proxies, resolution, frame rate, codec, keyframe interval, rewind window, Smart Pause memory and sampling rate, focus score, CPU and memory pressure.

### Session recovery
- If the app quits unexpectedly while a stream is playing, the next launch offers to resume it. A clean quit or disconnect clears this, so the prompt only appears after an unclean exit.

## Requirements

- macOS 26.2 or later (the project's `MACOSX_DEPLOYMENT_TARGET`).
- Xcode with the macOS 26.2 SDK or newer to build.

## Installation

### Build from source
```bash
git clone https://github.com/Zahin-Mohammad-plug/macOS-rtsp-ocr-viewer.git
cd macOS-rtsp-ocr-viewer
open SharpStream.xcodeproj
# Select the SharpStream scheme and run (⌘R)
```

See [BUILD.md](BUILD.md) for command-line builds, signing and tests.

### Download (not published yet)
There are no published releases. `scripts/create_dmg.sh` packages a local, unsigned DMG for your own Mac; see [BUILD.md](BUILD.md).

## Dependencies

- **MPVKit** 0.41 (Swift Package Manager, `https://github.com/mpvkit/MPVKit.git`): libmpv and FFmpeg.
- System frameworks: SwiftUI, AppKit, Vision, Accelerate, CoreVideo, CoreImage, OpenGL, QuartzCore, SQLite3.

## Usage

### Opening a stream or file
- **Drag and drop** a video file or URL onto the video area.
- **File › Open File…** (⌘O).
- **File › Open URL from Clipboard** (⇧⌘V), or the link toolbar button.
- **File › New Stream…** (⌘N) or the **+** button in the sidebar to add a stream to the library (name, URL, Test Connection, Save).
- Click a saved or recent stream in the sidebar. **File › Open Recent** and **File › Saved Streams** list them too.

### Smart Pause and text
1. Let the stream play for a couple of seconds.
2. Press ⌘S (or the **Smart Pause** button). The sharpest recent frame is frozen on screen and the status line shows how old it was and its score.
3. If "Recognize text after Smart Pause" is on, text boxes appear on the frame and in the Recognized Text panel (⌥⌘T to show/hide).
4. Click a box to copy that line, or use ⇧⌘C to copy all text.
5. Press Space or Esc to resume playback / dismiss the frozen frame.

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Play / pause |
| ← / → | Seek −5 s / +5 s (steps one frame when a file is paused) |
| ⌘← / ⌘→ | Seek −10 s / +10 s |
| ⌥⌘← / ⌥⌘→ | Back / forward 10 seconds (Playback menu) |
| , / . | Previous / next frame (files) |
| ⌘S | Smart Pause |
| ⌘R | Recognize Text |
| ⌘L | Jump to Live |
| ⇧⌘C | Copy Recognized Text |
| ⌥⌘C | Copy Frame |
| ⌘E | Save Frame As… |
| ⇧⌘E | Quick Save Frame |
| ⌘N | New Stream… |
| ⌘O | Open File… |
| ⇧⌘V | Open URL from Clipboard |
| ⇧⌘D | Disconnect |
| ⌥⌘T | Show / hide Text Panel |
| ⌥⌘I | Show Statistics |
| Esc | Dismiss the analyzed (frozen) frame |
| ⌘, | Settings |

Space, arrows, `,`, `.` and Esc are handled by a key monitor on the player window and are ignored while a text field has focus, so they never interfere with typing.

## Settings

Open with **SharpStream › Settings…** (⌘,).

- **General**: Rewind window (10/20/30/40 min), Smart Pause lookback window (1–5 s), sharpness metric (Laplacian/Tenengrad/Sobel), "Recognize text after Smart Pause", 24-hour time.
- **Text**: Enable text recognition, accuracy (Fast/Accurate), languages (comma-separated, empty = automatic), language correction, outline recognized text, show recognized text on hover.
- **Export**: Quick save format (PNG/JPEG) and JPEG quality.
- **Shortcuts**: reference list.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```
SharpStream/
├── App/
│   ├── SharpStreamApp.swift        # Scenes: main window, Statistics window, Settings
│   ├── AppState.swift              # Shared state and all user actions, key monitor
│   └── AppMenu.swift               # Menu bar commands
├── Core/
│   ├── MPVPlayerWrapper.swift      # libmpv handle, playback, frame capture
│   ├── MPVPlayerWrapper+Metrics.swift  # Demuxer-cache / transport metrics
│   ├── StreamManager.swift         # Connect/reconnect, seek mode, live DVR, sampling QoS
│   ├── FocusScorer.swift           # Sharpness scoring + bounded Smart Pause candidates
│   ├── SmartPauseCoordinator.swift # Smart Pause selection, seek, diagnostics
│   ├── OCREngine.swift             # Vision text recognition
│   ├── ExportManager.swift         # Clipboard, image/text export, box drawing
│   ├── SessionRecoveryStore.swift  # Unclean-exit resume marker
│   ├── FileAccessStore.swift       # Security-scoped bookmarks for opened files
│   ├── StreamDatabase.swift        # SQLite: saved and recent streams
│   └── TransportMetricsSampler.swift  # Health / jitter / loss proxies
├── Views/                          # MainWindow, MPVVideoView, ControlsView, OCROverlayView,
│                                   # StreamListView, StreamConfigurationView, ExportView,
│                                   # PreferencesView, StatsPanel
├── Models/                         # SavedStream, OCRResult, FrameScore, StreamStats, ...
├── Utils/                          # SharpnessMetrics, URL validation/redaction,
│                                   # PerformanceMonitor, VideoLayoutMapper, TestStreamConfig
└── Resources/                      # Info.plist, entitlements
```

## Documentation

- [docs/README.md](docs/README.md) - documentation index
- [QUICK_START.md](QUICK_START.md) - build and try it in a few minutes
- [docs/USER_GUIDE.md](docs/USER_GUIDE.md) - user guide
- [docs/FEATURES.md](docs/FEATURES.md) - feature list
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - components, threading, data flow, design decisions
- [docs/API_REFERENCE.md](docs/API_REFERENCE.md) - overview of the main types
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) - development and testing
- [BUILD.md](BUILD.md) - building, signing, packaging
- [CHANGELOG.md](CHANGELOG.md) - changes

## Contributing

Issues and pull requests are welcome.

## License

No license has been chosen yet.

## Acknowledgments

- [MPVKit](https://github.com/mpvkit/MPVKit), mpv and FFmpeg for playback
- Apple Vision for text recognition
