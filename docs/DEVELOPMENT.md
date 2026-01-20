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

### Manual Testing Checklist
- [ ] Connect to RTSP stream
- [ ] Test playback controls
- [ ] Test smart pause and OCR
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
