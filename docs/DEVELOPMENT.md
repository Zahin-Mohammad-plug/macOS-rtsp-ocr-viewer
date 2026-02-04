# Development Guide

## Getting Started

1. Clone the repository
2. Open `SharpStream.xcodeproj` in Xcode
3. Build and run (⌘R)

## Project Structure

```
SharpStream/
├── App/                    # Application entry point
│   ├── SharpStreamApp.swift
│   └── AppMenu.swift
├── Core/                   # Core business logic
│   ├── StreamManager.swift       # Stream connection management
│   ├── MPVPlayerWrapper.swift    # MPVKit/libmpv wrapper
│   ├── BufferManager.swift       # Frame buffering (RAM + disk)
│   ├── FocusScorer.swift         # Frame sharpness detection
│   ├── OCREngine.swift           # Text recognition
│   ├── ExportManager.swift       # Export functionality
│   └── StreamDatabase.swift      # SQLite database
├── Views/                  # SwiftUI views
│   ├── MainWindow.swift
│   ├── ControlsView.swift
│   ├── MPVVideoView.swift
│   └── ...
├── Models/                 # Data models
├── Utils/                  # Utilities and extensions
└── Resources/              # Assets and configuration
```

## Key Components

### StreamManager
Orchestrates stream playback and frame extraction. Connects MPVPlayerWrapper, BufferManager, and FocusScorer.

### MPVPlayerWrapper
Swift wrapper around libmpv C API. Handles playback control and frame extraction callbacks.

### BufferManager (Actor)
Thread-safe frame storage with RAM and disk buffers. Handles crash recovery.

### FocusScorer
Evaluates frame sharpness using Laplacian variance. Maintains score history for smart pause.

### OCREngine
Vision framework wrapper for text recognition. Processes frames asynchronously.

## Adding New Features

### Adding a New Protocol

1. Add to `StreamProtocol` enum in `SavedStream.swift`
2. Add validation in `StreamURLValidator.swift`
3. MPVKit handles protocol-specific details automatically

### Adding a New Focus Algorithm

1. Create scorer class (e.g., `TenengradFocusScorer.swift`)
2. Implement `calculateScore(_: CVPixelBuffer) -> Double`
3. Add to `FocusAlgorithm` enum
4. Update `FocusScorer` to use new algorithm

### Adding a New Export Format

1. Add case to `ExportFormat` enum in `ExportManager.swift`
2. Implement conversion in `ExportManager.saveFrame()`
3. Update `ExportView` UI if needed

## Testing

### Unit Tests
- Focus scoring algorithms
- Buffer operations
- Frame serialization

### Integration Tests
- Stream connection flow
- Frame extraction pipeline

### Local QA Stream Setup (Private)

For private RTSP/LAN streams, use local environment variables (never commit real endpoints):

1. Copy `.env.example` to `.env`
2. Set your stream values:
   - `SHARPSTREAM_TEST_RTSP_URL=rtsp://<private-host>:554/live`
   - `SHARPSTREAM_TEST_VIDEO_FILE=/absolute/path/to/test.mp4`
   - `SHARPSTREAM_TEST_STREAMS=<optional,comma,separated,list>`
3. Run checks through `scripts/full_check.sh` (it auto-loads `.env` when present)

If no env stream/file is configured, stream-dependent smoke tests are skipped explicitly.

### Full Pre-Release Check

Run the local pre-release validation:

```bash
scripts/full_check.sh
```

This runs:
- Build (`xcodebuild build`)
- Tests (`xcodebuild test`) including UI smoke checks

### Targeted Stability Bug Pass

Run the focused RTSP/file hardening workflow with test artifacts:

```bash
scripts/targeted_bug_pass.sh
```

This writes logs and `.xcresult` bundles under:
- `DerivedData/bug-pass/<timestamp>/build.log`
- `DerivedData/bug-pass/<timestamp>/unit-tests.xcresult`
- `DerivedData/bug-pass/<timestamp>/ui-smoke.xcresult`

### Smart Pause Validation (test.MOV)

Use the moving-document sample to validate sharp-frame selection quality:

1. Set env vars in a local `.env` file (gitignored). Copy from `.env.example` and fill in your paths:
   - `SHARPSTREAM_TEST_VIDEO_FILE` — path to a local test video (e.g. `test.MOV` in project root)
   - `SHARPSTREAM_TEST_RTSP_URL` — optional RTSP URL for live-stream tests
   - `SHARPSTREAM_DEBUG_LOG_PATH` - Optional Log path
2. Run reliability matrix (default: 10 iterations per MP4/live scenario):
   - `SMART_PAUSE_REPEATS=10 scripts/smart_pause_test_matrix.sh`
3. Verify Smart Pause feedback and diagnostics:
   - control status shows selected frame age/score
   - timeline marker appears for file/timeline mode
   - live badge appears for live-buffered streams
   - failed iterations include `smartPauseDiagnosticsLabel` payload in trace attachments

### Smart Pause Failure Triage

Use `failureReason` from Smart Pause diagnostics to quickly isolate likely causes:

| failureReason | Likely subsystem |
| --- | --- |
| `noRecentFrames` | frame extraction cadence, frame callback timing, lookback window |
| `staleSelection` | stale history windowing or delayed selection trigger |
| `seekRejected` | player seek path (`seek(to:)` / `seek(offset:)`) |
| `seekDisabled` | seek mode classification (`StreamManager.classifySeekMode`) |
| `ocrFrameMissing` | frame retention / focus scorer history for selected sequence |

### Smart Pause Performance Budget

- Baseline sampling: 4 FPS (`0.25s` frame extraction interval)
- Degrade to 2 FPS when CPU > 8% for 3 consecutive samples or memory pressure warning
- Degrade to 1 FPS when CPU > 12% for 3 consecutive samples or memory pressure critical
- Recover one tier after 10 stable samples at CPU < 6% and normal memory pressure
- Target envelope: keep Smart Pause scoring overhead under an effective `<8%` app CPU budget in normal playback

### Manual Testing Checklist
- [ ] Connect to RTSP stream
- [ ] Test playback controls
- [ ] Test Smart Pause repeatedly on `test.MOV` and verify selected frame feedback (status + marker)
- [ ] Test Smart Pause on RTSP and verify live buffer feedback path
- [ ] Test smart pause + OCR gating (`autoOCROnSmartPause` on/off)
- [ ] Test frame export
- [ ] Test buffer recovery
- [ ] Test reconnection after stream drop

## Code Style

- Use Swift naming conventions
- Document public APIs with comments
- Use `actor` for thread-safe types (e.g., BufferManager)
- Use `@Published` for ObservableObject properties
- Handle errors gracefully with user-friendly messages

## Performance Considerations

- Frame extraction adds overhead - consider reducing FPS for OCR
- Use hardware acceleration when available (MPVKit handles this)
- Monitor memory usage with BufferManager stats
- Disk I/O is async - don't block main thread

## Debugging

### Enable Logging
Add print statements or use OSLog:

```swift
import os.log
let logger = Logger(subsystem: "com.sharpstream", category: "StreamManager")
logger.debug("Connecting to stream: \(url)")
```

### Common Issues

**Stream won't connect:**
- Check URL format
- Verify network connectivity
- Check RTSP credentials

**Frames not extracting:**
- Verify frame callback is set
- Check MPVKit is properly initialized
- Ensure render context is set up

**Memory issues:**
- Reduce RAM buffer size
- Check disk buffer cleanup
- Monitor with StatsPanel

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

See [ARCHITECTURE.md](ARCHITECTURE.md) for more details on system design.
