# SharpStream Architecture

## System Overview

SharpStream is a native macOS application built with SwiftUI that provides RTSP stream viewing with smart frame selection, OCR, and VLC-style playback controls.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    SharpStreamApp                            │
│                   (App Entry Point)                          │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                      AppState                                │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐           │
│  │StreamManager│ │BufferManager│ │FocusScorer  │           │
│  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘           │
│         │               │               │                   │
│  ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐           │
│  │OCREngine    │ │ExportManager│ │StreamDB     │           │
│  └─────────────┘ └─────────────┘ └─────────────┘           │
└─────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────┐  ┌──────────────┐  ┌──────────────────┐
│  MPVKit/libmpv  │  │ Vision OCR   │  │  SQLite Database │
│  (Video Playback)│  │  (Text Rec.) │  │  (Stream Storage)│
└─────────────────┘  └──────────────┘  └──────────────────┘
```

## Core Components

### 1. StreamManager
**Purpose**: Manages stream connections, reconnection logic, and coordinates video playback.

**Responsibilities**:
- Connect/disconnect to streams (RTSP, SRT, UDP, HLS, etc.)
- Auto-reconnect with exponential backoff
- Extract stream metadata (resolution, bitrate, FPS)
- Coordinate frame extraction pipeline
- Update connection state

**Dependencies**: MPVPlayerWrapper, BufferManager, FocusScorer, StreamDatabase

### 2. MPVPlayerWrapper
**Purpose**: Swift wrapper around MPVKit/libmpv C API for video playback.

**Responsibilities**:
- Initialize and manage libmpv instance
- Load and play video streams
- Playback control (play, pause, seek, speed, volume)
- Frame extraction via callback mechanism
- Event handling (connection state, metadata, errors)
- Stream metadata extraction

**Key Methods**:
- `loadStream(url:)` - Load stream URL
- `play()`, `pause()`, `seek(to:)` - Playback control
- `setFrameCallback(_:)` - Register frame extraction callback
- `getMetadata()` - Extract stream metadata

### 3. BufferManager
**Purpose**: Hybrid RAM/disk frame buffer for playback history.

**Responsibilities**:
- Store frames in RAM buffer (configurable: 1s/3s/5s)
- Write frames to disk buffer (up to 40 minutes)
- Frame retrieval by timestamp
- Crash recovery (save index every 30s)
- Memory management and cleanup

**Key Features**:
- Circular RAM buffer
- Disk buffer segments (1-minute chunks)
- Timestamp-based frame lookup
- Automatic cleanup of old buffers

### 4. FocusScorer
**Purpose**: Evaluate frame sharpness for smart pause feature.

**Responsibilities**:
- Score frames using Laplacian variance algorithm
- Maintain score history
- Find best frame in lookback window
- Support multiple algorithms (OpenCV, Swift-native)

**Algorithm Options**:
- **OpenCV Laplacian**: Hardware-accelerated, faster (primary)
- **Swift Laplacian**: Native implementation using Accelerate (fallback)

### 5. OCREngine
**Purpose**: Extract text from video frames using Vision framework.

**Responsibilities**:
- Process CVPixelBuffer frames
- Recognize text with bounding boxes
- Support multiple languages
- Configurable recognition level (fast/accurate)
- Async processing on background queue

**Output**: OCRResult with text, confidence, bounding boxes, timestamp

### 6. ExportManager
**Purpose**: Export frames and OCR results to various formats.

**Responsibilities**:
- Save frames as PNG/JPEG
- Export OCR text to .txt files
- Copy to clipboard (frames and text)
- Export composite images (frame + OCR overlay)
- Batch export multiple frames

## Data Flow

### Stream Playback Flow
```
Stream URL → StreamManager.connect()
              ↓
          MPVPlayerWrapper.loadStream()
              ↓
          MPVKit/libmpv (decode stream)
              ↓
          Frame Callback (each frame)
              ↓
          ┌─────────────────┐
          │                 │
          ▼                 ▼
    BufferManager     FocusScorer
    (store frame)     (score frame)
          │                 │
          └────────┬────────┘
                   ▼
            Update Stats
```

### Smart Pause Flow
```
User clicks "Smart Pause"
    ↓
FocusScorer.findBestFrame(lookbackWindow)
    ↓
Find frame with highest score in last N seconds
    ↓
If auto-OCR enabled:
    ↓
OCREngine.recognizeText(bestFrame)
    ↓
Display OCR result in overlay
```

### Frame Export Flow
```
User clicks "Export Frame"
    ↓
Get current frame from BufferManager
    ↓
ExportManager.saveFrame(pixelBuffer, format, quality)
    ↓
Convert CVPixelBuffer → CGImage → File
    ↓
Save to user-selected location
```

## Threading Model

### Main Thread
- UI updates (SwiftUI views)
- Player control operations (play, pause, seek)
- State property updates (@Published)

### Background Threads
- Frame extraction (frameExtractionQueue)
- OCR processing (OCRQueue in OCREngine)
- Buffer disk I/O (async/await in BufferManager actor)
- MPVKit event loop (global queue)

### Actor Isolation
- `BufferManager` is an actor for thread-safe frame storage
- All buffer operations are isolated and async

## Memory Management

### RAM Buffer
- Configurable size: Low (1s), Medium (3s), High (5s)
- Stores CVPixelBuffer references
- Circular buffer with automatic trimming
- Estimated memory: 70-350 MB for 1080p30

### Disk Buffer
- Temporary files in `NSTemporaryDirectory()`
- Segmented storage (1-minute chunks)
- Automatic cleanup of old segments (> 40 minutes)
- Frame serialization as JPEG for efficiency

### Crash Recovery
- Buffer index saved every 30 seconds
- Contains: stream URL, last timestamp, sequence number
- On app restart: offer to resume last stream

## State Management

### AppState (ObservableObject)
- Central state container
- Contains all managers (StreamManager, BufferManager, etc.)
- Published properties for UI binding

### StreamManager State
- `connectionState`: disconnected, connecting, connected, reconnecting, error
- `streamStats`: metadata, performance metrics
- `currentStream`: active stream configuration

### Published Properties
- SwiftUI automatically updates views when @Published properties change
- Combine used for reactive programming patterns

## Error Handling

### Connection Errors
- Automatic reconnection with exponential backoff
- Maximum 10 reconnection attempts
- Error state with user-visible message

### Stream Errors
- MPVKit events captured via event loop
- Error messages logged and displayed
- Graceful degradation (fallback to Swift-native algorithms)

### Resource Errors
- Disk space checks before writing
- Memory pressure monitoring
- Automatic buffer size reduction on warnings

## Performance Optimizations

1. **Frame Extraction**: Configurable FPS (default 30, can reduce for OCR)
2. **Hardware Acceleration**: MPVKit uses hardware decoding when available
3. **Lazy Loading**: Disk buffers only loaded when seeking
4. **Memory Efficiency**: JPEG compression for RAM buffer (optional)
5. **Background Processing**: OCR and frame scoring on background queues

## Extension Points

### Adding New Protocols
1. Update `StreamProtocol` enum
2. Add validation in `StreamURLValidator`
3. MPVKit handles protocol-specific details

### Adding New Focus Algorithms
1. Create new scorer class (e.g., `TenengradFocusScorer`)
2. Implement `calculateScore(_:CVPixelBuffer) -> Double`
3. Add to `FocusScorer` algorithm selection

### Adding Export Formats
1. Add format enum case to `ExportFormat`
2. Implement conversion in `ExportManager`
3. Update `ExportView` UI

## Testing Strategy

### Unit Tests
- Focus scoring algorithms
- Buffer management operations
- Frame data serialization

### Integration Tests
- Stream connection flow
- Frame extraction pipeline
- OCR processing

### UI Tests
- User workflows (add stream, play, export)
- Keyboard shortcuts
- Preferences

## Future Enhancements

1. **Subtitle Support**: Extract and display subtitles from streams
2. **Multi-Stream**: Play multiple streams simultaneously
3. **Recording**: Save stream segments to disk
4. **Streaming**: Broadcast processed streams
5. **AI Integration**: Advanced scene detection, object recognition
