---
name: SharpStream - macOS RTSP OCR Viewer
overview: Build a native macOS SwiftUI app for RTSP stream viewing with smart frame selection, OCR, and VLC-style playback controls. Uses MPVKit (via SPM) for stream playback, Vision framework for OCR, OpenCV (via SPM) for focus scoring, and hybrid RAM/disk buffering.
todos:
  - id: todo-1768897927047-62juquq78
    content: ""
    status: pending
---

# SharpStream - macOS RTSP OCR Viewer - Implementation Plan

## Architecture Overview

The app will be built as a native macOS SwiftUI application targeting macOS 14 Sonoma. Core components:

- **Stream Management**: Multi-protocol stream handling with auto-reconnect (using MPVKit via SPM for RTSP/SRT/UDP/TS/HLS/MP4/MKV support)
- **Hybrid Buffer**: RAM cache for recent frames + disk storage for extended buffer
- **Focus Scoring**: OpenCV implementation (primary) + Swift-native Laplacian (fallback)
- **OCR Engine**: Vision framework for text recognition
- **UI**: SwiftUI with MPVKit player integration for video playback

## Project Structure

```
SharpStream/
├── SharpStream.xcodeproj
├── SharpStream/
│   ├── App/
│   │   └── SharpStreamApp.swift        # Main app entry point
│   │
│   ├── Views/
│   │   ├── MainWindow.swift            # Primary video player window
│   │   ├── StreamListView.swift        # Sidebar with saved streams
│   │   ├── ControlsView.swift          # Play/pause/scrub/speed controls
│   │   ├── OCROverlayView.swift        # Text overlay on video frame
│   │   ├── StatsPanel.swift            # Connection & buffer statistics
│   │   ├── PreferencesView.swift       # Settings window
│   │   └── ExportView.swift            # Export/save options UI
│   │
│   ├── Core/
│   │   ├── StreamManager.swift         # Multi-protocol connection & reconnect logic
│   │   ├── BufferManager.swift         # Hybrid RAM/disk frame buffer with crash recovery
│   │   ├── FocusScorer.swift           # Frame sharpness scoring coordinator
│   │   ├── OCREngine.swift             # Vision framework OCR wrapper
│   │   ├── StreamDatabase.swift        # SQLite storage for saved streams
│   │   └── ExportManager.swift         # Frame/image export functionality
│   │
│   ├── Models/
│   │   ├── SavedStream.swift           # Stream configuration (name, URL, protocol)
│   │   ├── FrameScore.swift            # Timestamp + focus score + frame data
│   │   ├── OCRResult.swift             # Recognized text with bounding boxes
│   │   ├── StreamStats.swift           # Connection metrics (bitrate, FPS, etc.)
│   │   └── RecentStream.swift          # Recently used stream URLs
│   │
│   ├── Utils/
│   │   ├── FocusMetrics/
│   │   │   ├── OpenCVFocusScorer.swift # OpenCV-based scoring
│   │   │   └── SwiftFocusScorer.swift  # Native Laplacian implementation
│   │   ├── KeyboardShortcuts.swift     # Global hotkey handling
│   │   ├── StreamURLValidator.swift   # URL validation with helpful errors
│   │   └── Extensions/
│   │       ├── CVPixelBuffer+Extensions.swift
│   │       └── CMSampleBuffer+Extensions.swift
│   │
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   ├── Info.plist
│   │   └── SharpStream.entitlements
│   │
│   └── Supporting Files/
│       └── Package.swift               # SPM dependencies (OpenCV, MPVKit)
│
└── README.md
```

## Implementation Phases

### Phase 1: Project Setup & Core Infrastructure

**1.1 Xcode Project Creation**

- Create new macOS App project (SwiftUI, minimum deployment: macOS 14.0)
- Configure app bundle identifier, display name, and entitlements
- Set up SPM dependencies:
  - OpenCV (via `opencv-swift` or similar SPM package)
  - MPVKit (via SPM for RTSP/SRT/UDP/TS/HLS/MP4/MKV support)

**1.2 Core Models** ([Models/SavedStream.swift](SharpStream/Models/SavedStream.swift), [Models/FrameScore.swift](SharpStream/Models/FrameScore.swift), [Models/OCRResult.swift](SharpStream/Models/OCRResult.swift), [Models/RecentStream.swift](SharpStream/Models/RecentStream.swift))

- `SavedStream`: Codable struct with `id`, `name`, `url`, `protocol` (rtsp/srt/udp/hls/etc), `createdAt`, `lastUsed`
- `FrameScore`: Contains `timestamp: Date`, `score: Double`, `pixelBuffer: CVPixelBuffer?`
- `OCRResult`: Contains `text: String`, `confidence: Double`, `boundingBoxes: [CGRect]`, `timestamp: Date`
- `RecentStream`: Contains `url`, `lastUsed`, `useCount` for quick access to last 5 streams

**1.3 Database Layer** ([Core/StreamDatabase.swift](SharpStream/Core/StreamDatabase.swift))

- SQLite database in `~/Library/Application Support/SharpStream/streams.db`
- CRUD operations for `SavedStream` entities
- Recent streams tracking (last 5 used URLs)
- Migration support for future schema changes

### Phase 2: Stream Management & Buffering

**2.1 Stream Manager** ([Core/StreamManager.swift](SharpStream/Core/StreamManager.swift))

- Multi-protocol connection handling using MPVKit (RTSP, SRT, UDP, TS, HLS, MP4, MKV)
- Auto-reconnect logic with exponential backoff
- Connection state management (connecting, connected, reconnecting, error)
- Stream metadata extraction (resolution, bitrate, codec, protocol)
- KVO observation for connection health
- Protocol detection from URL scheme

**2.2 Hybrid Buffer Manager** ([Core/BufferManager.swift](SharpStream/Core/BufferManager.swift))

- **RAM Buffer**: Circular buffer of `CVPixelBuffer` objects with configurable size:
  - Low: 1 second (~50-70 MB for 1080p30)
  - Medium: 3 seconds (~150-200 MB for 1080p30, default)
  - High: 5 seconds (~250-350 MB for 1080p30)
- **Disk Buffer**: Temporary files in `NSTemporaryDirectory()` for extended buffer (up to 40 minutes)
- Frame indexing by timestamp for efficient lookup
- Automatic cleanup of old disk buffers
- Thread-safe access using `actor` or `DispatchQueue`
- **Crash Recovery**: Save buffer index to disk every 30 seconds; on app restart, offer "Resume last stream" option

**2.3 Frame Extraction Pipeline**

- Extract frames from RTSP stream at regular intervals
- Convert to `CVPixelBuffer` format
- Store in both RAM and disk buffers
- Maintain frame metadata (timestamp, sequence number)

### Phase 3: Focus Scoring Implementation

**3.1 Focus Scorer Coordinator** ([Core/FocusScorer.swift](SharpStream/Core/FocusScorer.swift))

- Manages scoring algorithm selection (OpenCV vs Swift-native)
- Maintains score history for lookback window
- Provides API: `findBestFrame(in: TimeInterval) -> FrameScore?`

**3.2 OpenCV Implementation** ([Utils/FocusMetrics/OpenCVFocusScorer.swift](SharpStream/Utils/FocusMetrics/OpenCVFocusScorer.swift))

- Laplacian variance calculation using OpenCV
- Optional: Tenengrad and Sobel algorithms
- Performance optimization (downscale for speed if needed)

**3.3 Swift-Native Implementation** ([Utils/FocusMetrics/SwiftFocusScorer.swift](SharpStream/Utils/FocusMetrics/SwiftFocusScorer.swift))

- Laplacian kernel convolution using Accelerate framework
- Fallback when OpenCV unavailable
- Comparable accuracy for most use cases

### Phase 4: OCR Integration

**4.1 OCR Engine** ([Core/OCREngine.swift](SharpStream/Core/OCREngine.swift))

- Vision framework wrapper using `VNRecognizeTextRequest`
- Process `CVPixelBuffer` → `OCRResult`
- Support for multiple languages (configurable)
- Recognition level selection (`.fast` vs `.accurate`)

**4.2 OCR Overlay** ([Views/OCROverlayView.swift](SharpStream/Views/OCROverlayView.swift))

- Overlay recognized text on video frame
- Selectable text with copy-to-clipboard
- Bounding box visualization (optional toggle)
- Export to file functionality

**4.3 Export Manager** ([Core/ExportManager.swift](SharpStream/Core/ExportManager.swift))

- Save current frame as image (PNG/JPEG with quality selection)
- Export OCR text to .txt file
- Copy text to clipboard
- Copy image to clipboard
- Export frame + OCR overlay as composite image
- Batch export multiple frames with OCR results

**4.4 Export UI** ([Views/ExportView.swift](SharpStream/Views/ExportView.swift))

- Context menu on video frame: "Save Frame", "Copy Frame", "Export with OCR"
- Toolbar button for quick export access
- Export dialog with format selection (PNG/JPEG) and quality slider
- Save location picker with default to Downloads folder
- Progress indicator for batch exports

### Phase 5: Video Playback & Controls

**5.1 Main Window** ([Views/MainWindow.swift](SharpStream/Views/MainWindow.swift))

- MPVKit player integration for video display
- Split view: video player + sidebar (stream list)
- Fullscreen support
- Window state persistence
- Menu bar "Paste Stream URL" quick action

**5.2 Playback Controls** ([Views/ControlsView.swift](SharpStream/Views/ControlsView.swift))

- Play/Pause button
- Timeline scrubber (seekable to any point in buffer)
- Rewind 10s / Forward 10s buttons
- Speed control slider (0.25x - 2x)
- Volume control slider
- Smart Pause button (triggers focus scoring + OCR)

**5.3 Manual Frame Control**

- Left/Right arrow buttons for frame-by-frame navigation
- Visual indicator showing selected frame timestamp
- Frame counter display

### Phase 6: Stream Management UI

**6.1 Stream List View** ([Views/StreamListView.swift](SharpStream/Views/StreamListView.swift))

- Sidebar showing all saved streams
- Add/Edit/Delete stream functionality
- Quick switch between streams
- Connection status indicator per stream
- Recent streams section (last 5 used URLs)
- "Paste Stream URL" button in toolbar

**6.2 Stream Configuration**

- Modal sheet for adding/editing streams
- URL validation with helpful error messages ([Utils/StreamURLValidator.swift](SharpStream/Utils/StreamURLValidator.swift))
  - Protocol detection (rtsp://, srt://, udp://, http://, file://)
  - Format-specific validation
  - Connection test with detailed error reporting
  - Clear error messages: "Invalid RTSP URL format", "Connection timeout", "Authentication required", etc.
- Friendly name input
- Test connection button
- Recent streams quick-select dropdown

**6.3 Quick Stream Entry**

- Menu bar item: "Paste Stream URL" (⌘V when URL in clipboard)
- Recent streams list (last 5 used URLs) in sidebar
- Quick-add button in toolbar that opens URL entry field
- Auto-detect URL from clipboard on app launch (optional, configurable)
- Keyboard shortcut: ⌘N for new stream, ⌘⇧N for quick paste

### Phase 7: Statistics & Preferences

**7.1 Stats Panel** ([Views/StatsPanel.swift](SharpStream/Views/StatsPanel.swift))

- Connection status (connected/reconnecting/dropped)
- Current bitrate & resolution
- Frame rate (actual vs expected)
- Buffer health (RAM usage, disk usage, total duration)
- Focus score of current frame
- Total recording time / buffer length
- **Performance Monitoring**:
  - CPU usage (percentage)
  - GPU usage (for video decode)
  - Focus scoring FPS (frames scored per second)
  - Memory pressure indicator

**7.2 Preferences Window** ([Views/PreferencesView.swift](SharpStream/Views/PreferencesView.swift))

- Lookback window duration (1-5 seconds, default 3)
- Maximum buffer length (20/30/40 minutes)
- **RAM Buffer Size**: Low (1s) / Medium (3s) / High (5s) - default Medium
- Focus algorithm selection (Laplacian/Tenengrad/Sobel)
- Auto-OCR on smart pause toggle
- OCR language selection
- Keyboard shortcuts customization
- Storage location preference
- Export format preferences (PNG/JPEG quality settings)

### Phase 8: Keyboard Shortcuts & Polish

**8.1 Keyboard Shortcuts** ([Utils/KeyboardShortcuts.swift](SharpStream/Utils/KeyboardShortcuts.swift))

- Global hotkey support (optional, requires accessibility permission)
- Standard shortcuts: Space (play/pause), ←/→ (seek), +/- (speed)
- Customizable via Preferences

**8.2 UI Polish**

- Dark mode support
- Smooth animations for state transitions
- Loading indicators
- Error messages with recovery suggestions
- Tooltips for controls

### Phase 9: Testing & Distribution Prep

**9.1 Testing**

- Unit tests for focus scoring algorithms
- Integration tests for buffer management
- UI tests for critical user flows

**9.2 Code Signing Setup**

- Configure signing certificate in Xcode
- Add entitlements for network access
- Test notarization process

**9.3 Distribution Assets**

- App icon design
- DMG creation script
- **Auto-Update Mechanism**:
  - **For DMG distribution**: Integrate Sparkle framework
    - App checks for updates on launch (configurable interval)
    - Downloads and installs updates automatically
    - Requires code signing and appcast.xml feed
  - **For Homebrew Cask**: Use `brew upgrade sharp-stream`
    - Create Homebrew formula/cask
    - Updates via standard Homebrew update mechanism
    - Both distribution methods should be supported simultaneously
- README with installation instructions for both DMG and Homebrew

## Technical Considerations

### Multi-Protocol Stream Support

Using MPVKit via SPM for comprehensive protocol support:

- **RTSP**: Security cameras and IP cameras
- **SRT**: Secure Reliable Transport for broadcast feeds
- **UDP/TS**: Broadcast transport streams
- **HLS**: HTTP Live Streaming (streaming platforms)
- **Local files**: MP4, MKV, TS formats

MPVKit provides:

- Built-in auto-reconnect logic
- Hardware-accelerated decoding
- Low latency playback
- Excellent buffer management

### Buffer Management Strategy

- **RAM Buffer**: Configurable size (Low: 1s, Medium: 3s, High: 5s)
  - For 1080p30: ~50-70 MB (1s), ~150-200 MB (3s), ~250-350 MB (5s)
  - Stored as compressed JPEG in RAM for efficiency
  - Circular buffer implementation
- **Disk Buffer**: Write frames to temporary files in chunks (e.g., 1-minute segments)
- **Lookup**: Use timestamp-based indexing for O(log n) frame retrieval
- **Cleanup**: Auto-delete disk buffers older than max buffer length
- **Crash Recovery**: 
  - Save buffer index metadata to `~/Library/Application Support/SharpStream/buffer_index.json` every 30 seconds
  - On app launch, check for recovery data and prompt user to resume
  - Restore stream URL and buffer position from saved state

### Performance Optimization

- Downscale frames for focus scoring (e.g., 640x480) to improve speed
- Run OCR on background queue to avoid blocking UI
- Use `actor` isolation for thread-safe buffer access
- Lazy loading of disk buffers (only load when seeking)

### Memory Management

- Configurable RAM buffer size (Low/Medium/High presets)
- Release `CVPixelBuffer` objects when no longer needed
- Monitor memory pressure and reduce buffer size if needed
- Use compressed JPEG storage in RAM buffer to minimize memory footprint
- Automatic memory pressure response (reduce buffer on system warnings)

## Dependencies

**Swift Package Manager:**

- OpenCV (via `opencv-swift` or similar SPM package)
- MPVKit (via SPM - supports RTSP, SRT, UDP, TS, HLS, MP4, MKV)

**System Frameworks:**

- AVFoundation
- Vision
- Accelerate
- AppKit
- SwiftUI

## File Structure Details

Key files to create:

1. **[SharpStream/App/SharpStreamApp.swift](SharpStream/App/SharpStreamApp.swift)** - App entry point with window management
2. **[SharpStream/Core/StreamManager.swift](SharpStream/Core/StreamManager.swift)** - Multi-protocol connection and reconnect logic
3. **[SharpStream/Core/BufferManager.swift](SharpStream/Core/BufferManager.swift)** - Hybrid RAM/disk frame buffer with crash recovery
4. **[SharpStream/Core/FocusScorer.swift](SharpStream/Core/FocusScorer.swift)** - Focus scoring coordinator
5. **[SharpStream/Core/OCREngine.swift](SharpStream/Core/OCREngine.swift)** - Vision OCR wrapper
6. **[SharpStream/Core/ExportManager.swift](SharpStream/Core/ExportManager.swift)** - Frame/image export functionality
7. **[SharpStream/Views/MainWindow.swift](SharpStream/Views/MainWindow.swift)** - Main video player interface
8. **[SharpStream/Views/ControlsView.swift](SharpStream/Views/ControlsView.swift)** - Playback controls
9. **[SharpStream/Views/StatsPanel.swift](SharpStream/Views/StatsPanel.swift)** - Statistics with performance monitoring
10. **[SharpStream/Models/SavedStream.swift](SharpStream/Models/SavedStream.swift)** - Stream configuration model
11. **[SharpStream/Utils/StreamURLValidator.swift](SharpStream/Utils/StreamURLValidator.swift)** - URL validation with helpful errors

## Next Steps After Plan Approval

1. Create Xcode project structure
2. Set up SPM dependencies
3. Implement core models and database
4. Build stream manager with RTSP support
5. Implement buffer management
6. Add focus scoring (both implementations)
7. Integrate OCR engine
8. Build UI components progressively
9. Add preferences and statistics
10. Polish and test