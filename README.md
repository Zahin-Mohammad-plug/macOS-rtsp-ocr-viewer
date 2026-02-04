# SharpStream - macOS RTSP OCR Viewer

A native macOS application for viewing RTSP streams with smart frame selection, OCR text recognition, and VLC-style playback controls.

> 🎬 **Quick Test**: Drag an MP4 file onto the video player window to test playback immediately!
> 
> 📚 **Documentation**: See [docs/](docs/) for detailed architecture, API reference, and development guides.

## Features

### Stream Management
- **Multi-Protocol Support**: RTSP, SRT, UDP, TS, HLS, MP4, MKV
- **Auto-Reconnect**: Automatic reconnection with exponential backoff
- **Stream Library**: Save and manage multiple stream URLs
- **Quick Entry**: Paste stream URLs from clipboard with validation

### Playback Controls
- **VLC-Style Controls**: Play/Pause, seek, speed control (0.25x - 2x), volume
- **Timeline Scrubber**: Seek to any point in the buffer
- **Frame Navigation**: Step frame-by-frame with arrow keys
- **Smart Pause**: Automatically finds the sharpest frame in the last N seconds

### Smart Frame Selection
- **Focus Scoring**: Laplacian variance algorithm (OpenCV or Swift-native)
- **Configurable Lookback**: 1-5 second window (default 3 seconds)
- **Visual Feedback**: Shows selected-frame status and timeline marker (or live buffer badge)
- **Adaptive Performance**: 4 FPS baseline with automatic degrade (2 FPS / 1 FPS) under pressure

### OCR Features
- **Text Recognition**: Vision framework OCR with selectable text overlay
- **Auto-OCR**: Optional automatic OCR on smart pause
- **Export Options**: Save OCR text, copy to clipboard, export with frame overlay
- **Multi-Language**: Configurable language support

### Statistics & Monitoring
- **Connection Stats**: Status, bitrate, resolution, frame rate
- **Buffer Health**: RAM/disk usage, buffer duration
- **Performance Metrics**: CPU/GPU usage, focus scoring FPS, memory pressure

### Export & Save
- **Frame Export**: Save current frame as PNG/JPEG
- **OCR Export**: Export recognized text to .txt file
- **Clipboard**: Copy frames and text to clipboard
- **Composite Export**: Export frame with OCR overlay


## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- Swift 5.9 or later

## Installation

### Option 1: Direct Download (DMG) - COMING SOON
1. Download the latest DMG from releases
2. Drag SharpStream.app to Applications folder
3. Open the app (may require allowing in System Preferences > Security)

### Option 2: Homebrew Cask
```bash
brew install --cask sharp-stream
```

### Option 3: Build from Source
```bash
git clone https://github.com/zahin-mohammad-plug/macOS-rtsp-ocr-viewer.git
cd macOS-rtsp-ocr-viewer
open SharpStream.xcodeproj
# Build and run in Xcode
```

## Dependencies

### Swift Package Manager
- **MPVKit** (v0.41.0): Multi-protocol stream playback (RTSP, SRT, UDP, TS, HLS, MP4, MKV)
  - Provides libmpv C API bindings for video playback
  - Hardware-accelerated decoding support
  - See [MPVKIT_INTEGRATION.md](MPVKIT_INTEGRATION.md) for detailed integration documentation
- **OpenCV-SPM** (v4.13.0): Focus scoring algorithms via [opencv-spm](https://github.com/yeatse/opencv-spm) (optional, falls back to Swift-native)

### System Frameworks
- AVFoundation
- Vision
- Accelerate
- AppKit
- SwiftUI

## Usage

### Adding a Stream
1. Click the "+" button in the sidebar
2. Enter a friendly name and stream URL
3. Click "Test Connection" to verify
4. Click "Save" to add to your library

### Quick Stream Entry
- **Drag & Drop**: Drag a video file (MP4, MKV, MOV, AVI, TS, etc.) onto the video player area - works anytime!
- **Paste URL**: Use ⌘⇧N to paste a stream URL from clipboard
- **Toolbar**: Use the "Paste Stream URL" button in the toolbar
- **File Menu**: File > Open... (⌘O) to browse for video files

**Testing**: The easiest way to test is to drag an MP4 file onto the window!

### Smart Pause
1. Click "Smart Pause" or press ⌘S
2. The app finds the sharpest frame in the last 3 seconds (configurable)
3. Selected-frame feedback appears in controls (status + marker/live badge)
4. If auto-OCR is enabled, text recognition runs automatically

### Keyboard Shortcuts
- **Space**: Play/Pause
- **⌘←/→**: Rewind/Forward 10 seconds
- **←/→**: Step frame backward/forward
- **⌘S**: Smart Pause
- **⌘+/-**: Increase/Decrease playback speed
- **⌘N**: New stream
- **⌘⇧N**: Paste stream URL

## Configuration

Access preferences via **SharpStream > Preferences** or **⌘,**

### Buffer Settings
- **RAM Buffer Size**: Low (1s), Medium (3s), High (5s)
- **Maximum Buffer Length**: 20/30/40 minutes

### Smart Pause
- **Lookback Window**: 1-5 seconds
- **Auto-OCR**: Enable/disable automatic OCR on smart pause

### OCR Settings
- **Recognition Level**: Fast or Accurate
- **Language**: Language code (e.g., en-US, fr-FR)

### Focus Algorithm
- **Laplacian**: Standard variance-based scoring
- **Tenengrad**: Alternative gradient-based method
- **Sobel**: Edge detection-based scoring

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed system architecture and design decisions.

```
SharpStream/
├── App/              # App entry point
├── Views/            # SwiftUI views
├── Core/             # Business logic
│   ├── StreamManager      # Stream connection & reconnect
│   ├── MPVPlayerWrapper   # MPVKit/libmpv wrapper
│   ├── BufferManager      # Hybrid RAM/disk buffer
│   ├── FocusScorer        # Frame sharpness scoring
│   ├── OCREngine          # Vision OCR wrapper
│   └── ExportManager      # Frame/image export
├── Models/           # Data models
├── Utils/            # Utilities & extensions
└── Resources/        # Assets, Info.plist, entitlements
```

## Crash Recovery

SharpStream automatically saves buffer state every 30 seconds. If the app crashes or is force-quit, you'll be prompted to resume the last stream on next launch.

## Performance

### Memory Usage
- **Low Buffer**: ~70 MB RAM (1 second @ 1080p30)
- **Medium Buffer**: ~200 MB RAM (3 seconds @ 1080p30, default)
- **High Buffer**: ~350 MB RAM (5 seconds @ 1080p30)

### Focus Scoring
- **OpenCV**: Hardware-accelerated, faster
- **Swift-Native**: No dependencies, good performance
- **Smart Pause sampling budget**:
  - Normal: 4 FPS
  - Degrade: 2 FPS when CPU > 8% for 3 samples or memory pressure warning
  - Degrade: 1 FPS when CPU > 12% for 3 samples or memory pressure critical
  - Recover: one tier after 10 stable samples with CPU < 6% and normal memory pressure

## Distribution

### DMG Distribution
- Code-signed with Apple Developer certificate
- Auto-updates via Sparkle framework
- Notarized for Gatekeeper compatibility

### Homebrew Cask
- Formula available in homebrew-cask
- Updates via `brew upgrade sharp-stream`

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

[Add your license here]

## Documentation

- **[docs/README.md](docs/README.md)** - Documentation index
- **[docs/USER_GUIDE.md](docs/USER_GUIDE.md)** - Complete user guide
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** - System architecture and design
- **[docs/API_REFERENCE.md](docs/API_REFERENCE.md)** - API documentation
- **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** - Development guide
- **[MPVKIT_INTEGRATION.md](MPVKIT_INTEGRATION.md)** - MPVKit integration guide
- **[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)** - Current implementation status
- **[BUILD.md](BUILD.md)** - Build instructions
- **[CHANGELOG.md](CHANGELOG.md)** - Version history

## Acknowledgments

- MPVKit for multi-protocol stream support
- OpenCV for focus scoring algorithms
- Apple Vision framework for OCR
