# API Reference

## Core Components

### StreamManager

Manages stream connections and coordinates video playback.

#### Methods

```swift
func connect(to stream: SavedStream)
```
Connect to a video stream (RTSP, SRT, UDP, HLS, or local file).

**Parameters:**
- `stream`: SavedStream configuration with URL and protocol

---

```swift
func disconnect()
```
Disconnect from current stream and cleanup resources.

---

```swift
func startReconnect(reason: String)
```
Start automatic reconnection with exponential backoff.

---

```swift
func updateStats(bitrate: Int?, resolution: CGSize?, frameRate: Double?)
```
Update stream statistics metadata.

---

```swift
func updateSmartPauseQoS(cpuUsage: Double?, memoryPressure: MemoryPressureLevel)
```
Apply adaptive Smart Pause sampling tier based on CPU and memory pressure.

---

#### Properties

- `@Published var connectionState: ConnectionState` - Current connection state
- `@Published var streamStats: StreamStats` - Stream statistics
- `@Published var currentStream: SavedStream?` - Currently active stream
- `@Published var smartPauseSamplingTier: SmartPauseSamplingTier` - Smart Pause sampling tier (Normal/Reduced/Minimal)
- `var player: MPVPlayerWrapper?` - MPVKit player instance

---

### MPVPlayerWrapper

Swift wrapper around MPVKit/libmpv for video playback.

#### Methods

```swift
func loadStream(url: String)
```
Load a video stream URL (supports all MPVKit protocols).

**Parameters:**
- `url`: Stream URL (RTSP, SRT, UDP, HLS, file://, etc.)

---

```swift
func play()
func pause()
func togglePlayPause()
```
Control playback state.

---

```swift
func seek(to time: TimeInterval)
func seek(offset: TimeInterval)
```
Seek to absolute time or relative offset.

**Parameters:**
- `to`: Absolute time in seconds
- `offset`: Relative time offset in seconds

---

```swift
func setSpeed(_ speed: Double)
func setVolume(_ volume: Double)
```
Set playback speed (0.25x - 2x) or volume (0.0 - 1.0).

---

```swift
func stepFrame(backward: Bool)
```
Step one frame forward or backward.

---

```swift
func setFrameCallback(_ callback: @escaping (CVPixelBuffer, Date, TimeInterval?) -> Void)
```
Register callback for frame extraction.

**Parameters:**
- `callback`: Called with each extracted frame (pixel buffer, wall-clock timestamp, playbackTime)

---

```swift
func setFrameExtractionInterval(_ seconds: TimeInterval)
```
Control runtime frame extraction cadence (used by Smart Pause adaptive QoS).

---

```swift
func getMetadata() -> (resolution: CGSize?, bitrate: Int?, frameRate: Double?)
```
Get current stream metadata.

**Returns:** Tuple with resolution, bitrate, and frame rate.

---

```swift
func cleanup()
```
Clean up player resources and terminate connection.

---

#### Published Properties

- `@Published var isPlaying: Bool` - Playback state
- `@Published var currentTime: TimeInterval` - Current playback position
- `@Published var duration: TimeInterval` - Total duration
- `@Published var playbackSpeed: Double` - Current speed
- `@Published var volume: Double` - Current volume (0.0-1.0)

---

### BufferManager (Actor)

Thread-safe frame buffer with RAM and disk storage.

#### Methods

```swift
func addFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date)
```
Add a frame to the buffer.

**Parameters:**
- `pixelBuffer`: Frame pixel data
- `timestamp`: Frame timestamp

---

```swift
func getFrame(at timestamp: Date, tolerance: TimeInterval = 0.1) -> CVPixelBuffer?
```
Get frame closest to specified timestamp.

**Parameters:**
- `timestamp`: Target timestamp
- `tolerance`: Acceptable time difference (default: 0.1s)

**Returns:** CVPixelBuffer or nil if not found

---

```swift
func getFrames(in timeRange: TimeInterval) -> [FrameData]
```
Get all frames within time range from current time.

---

```swift
func getCurrentSequenceNumber() -> Int
```
Get current frame sequence number.

---

```swift
func setBufferSizePreset(_ preset: BufferSizePreset)
```
Set RAM buffer size preset (Low/Medium/High).

---

```swift
func setMaxBufferDuration(_ duration: TimeInterval)
```
Set maximum disk buffer duration in seconds.

---

```swift
func getBufferDuration() -> TimeInterval
```
Get total buffer duration.

---

```swift
func getRAMBufferUsage() -> Int
```
Get RAM buffer usage in MB.

---

```swift
func getDiskBufferUsage() -> Int
```
Get disk buffer usage in MB.

---

```swift
func startIndexSaveTimer(streamURL: String?)
```
Start automatic buffer index saving (every 30s) for crash recovery.

---

```swift
func getRecoveryData() -> BufferRecoveryData?
```
Get crash recovery data if available.

---

```swift
func clearRecoveryData()
```
Clear saved recovery data.

---

### FocusScorer

Evaluates frame sharpness using focus scoring algorithms.

#### Methods

```swift
func scoreFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date, playbackTime: TimeInterval? = nil, sequenceNumber: Int) -> FrameScore
```
Score a frame for sharpness/focus quality.

**Parameters:**
- `pixelBuffer`: Frame to score
- `timestamp`: Frame wall-clock timestamp
- `playbackTime`: Playback timeline position for deterministic Smart Pause seek targets
- `sequenceNumber`: Frame sequence number

**Returns:** FrameScore with score value

---

```swift
func findBestFrame(in timeRange: TimeInterval) -> FrameScore?
```
Find frame with highest score in time range.

**Parameters:**
- `timeRange`: Lookback window in seconds (e.g., 3.0)

**Returns:** FrameScore with highest score, or nil

---

```swift
func selectBestFrame(in timeRange: TimeInterval, now: Date = Date(), currentPlaybackTime: TimeInterval?, seekMode: SeekMode) -> SmartPauseSelection?
```
Return deterministic Smart Pause selection metadata used for seek + UX feedback.

---

```swift
func getCurrentScore() -> Double?
```
Get focus score of most recently scored frame.

---

```swift
func getScoringFPS() -> Double
```
Get focus scoring rate (frames per second).

---

```swift
func setAlgorithm(_ algorithm: FocusAlgorithm)
```
Set focus scoring algorithm (Laplacian/Tenengrad/Sobel).

---

### OCREngine

Vision framework wrapper for text recognition.

#### Methods

```swift
func recognizeText(in pixelBuffer: CVPixelBuffer, completion: @escaping (OCRResult?) -> Void)
```
Recognize text in frame asynchronously.

**Parameters:**
- `pixelBuffer`: Frame containing text
- `completion`: Callback with OCR result

---

```swift
func recognizeTextSync(in pixelBuffer: CVPixelBuffer) -> OCRResult?
```
Recognize text synchronously (blocks until complete).

**Returns:** OCRResult or nil

---

#### Published Properties

- `@Published var isEnabled: Bool` - OCR enabled state
- `@Published var recognitionLevel: OCRRecognitionLevel` - Fast or Accurate
- `@Published var languages: [String]` - Language codes (e.g., ["en-US"])

---

### ExportManager

Handles export of frames and OCR results.

#### Methods

```swift
func saveFrame(_ pixelBuffer: CVPixelBuffer, to url: URL, format: ExportFormat = .png) throws
```
Save frame as image file.

**Parameters:**
- `pixelBuffer`: Frame to export
- `url`: Destination file URL
- `format`: PNG or JPEG with quality

**Throws:** ExportError

---

```swift
func copyFrameToClipboard(_ pixelBuffer: CVPixelBuffer)
```
Copy frame image to clipboard.

---

```swift
func copyTextToClipboard(_ text: String)
```
Copy text to clipboard.

---

```swift
func exportOCRText(_ text: String, to url: URL) throws
```
Export OCR text to .txt file.

**Throws:** ExportError

---

```swift
func exportFrameWithOCR(_ pixelBuffer: CVPixelBuffer, ocrResult: OCRResult, to url: URL, format: ExportFormat = .png) throws
```
Export frame with OCR overlay as composite image.

---

```swift
func batchExport(frames: [CVPixelBuffer], ocrResults: [OCRResult?], to directory: URL, format: ExportFormat = .png) throws
```
Export multiple frames and OCR results to directory.

---

## Models

### SavedStream

Stream configuration model.

```swift
struct SavedStream: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var protocolType: StreamProtocol
    var createdAt: Date
    var lastUsed: Date?
}
```

### FrameScore

Frame with focus score.

```swift
struct FrameScore: Identifiable, Comparable {
    let id: UUID
    let timestamp: Date
    let score: Double
    var pixelBuffer: CVPixelBuffer?
    let sequenceNumber: Int
}
```

### OCRResult

OCR recognition result.

```swift
struct OCRResult: Identifiable, Equatable {
    let id: UUID
    let text: String
    let confidence: Double
    let boundingBoxes: [CGRect]
    let timestamp: Date
    let frameID: UUID?
}
```

### StreamStats

Stream statistics and performance metrics.

```swift
struct StreamStats: Equatable {
    var connectionStatus: ConnectionState
    var bitrate: Int?
    var resolution: CGSize?
    var frameRate: Double?
    var bufferDuration: TimeInterval
    var ramBufferUsage: Int
    var diskBufferUsage: Int
    var currentFocusScore: Double?
    var cpuUsage: Double?
    var gpuUsage: Double?
    var focusScoringFPS: Double?
    var memoryPressure: MemoryPressureLevel
}
```

## Enums

### ConnectionState

```swift
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)
}
```

### StreamProtocol

```swift
enum StreamProtocol: String, Codable, CaseIterable {
    case rtsp, srt, udp, hls, http, https, file, unknown
}
```

### BufferSizePreset

```swift
enum BufferSizePreset: String, CaseIterable {
    case low      // 1 second
    case medium   // 3 seconds (default)
    case high     // 5 seconds
}
```

### FocusAlgorithm

```swift
enum FocusAlgorithm: String, CaseIterable {
    case laplacian, tenengrad, sobel
}
```

### ExportFormat

```swift
enum ExportFormat {
    case png
    case jpeg(quality: CGFloat)
}
```

## Thread Safety

- **BufferManager**: Actor-isolated - all methods are async
- **StreamManager**: Main actor - use from main thread
- **MPVPlayerWrapper**: Not thread-safe - use from main thread
- **FocusScorer**: Not thread-safe - use from main thread
- **OCREngine**: Thread-safe - uses internal queue

## Usage Examples

### Connecting to a Stream

```swift
let stream = SavedStream(
    name: "Camera Feed",
    url: "rtsp://example.com/stream",
    protocolType: .rtsp
)
streamManager.connect(to: stream)
```

### Setting Up Frame Callback

```swift
player.setFrameCallback { pixelBuffer, timestamp, playbackTime in
    Task {
        await bufferManager.addFrame(pixelBuffer, timestamp: timestamp)
        let score = focusScorer.scoreFrame(
            pixelBuffer,
            timestamp: timestamp,
            playbackTime: playbackTime,
            sequenceNumber: 0
        )
    }
}
```

### Finding Best Frame

```swift
if let bestFrame = focusScorer.findBestFrame(in: 3.0) {
    // Use bestFrame.pixelBuffer for OCR or export
}
```

### Smart Pause Selection

```swift
if let selection = focusScorer.selectBestFrame(
    in: 3.0,
    currentPlaybackTime: player.currentTime,
    seekMode: .absolute
) {
    _ = player.seek(to: selection.playbackTime ?? 0)
}
```

### Exporting Frame

```swift
let url = URL(fileURLWithPath: "/path/to/frame.png")
try exportManager.saveFrame(pixelBuffer, to: url, format: .png)
```
