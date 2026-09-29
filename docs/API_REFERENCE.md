# API Reference

A short overview of the main internal types and their key members. The source files are the authoritative reference; this page is meant to help you find your way around. Most types run on the main actor (the app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) unless noted.

## AppState (`App/AppState.swift`)

`@MainActor final class AppState: ObservableObject`. It owns the engines and holds every user action.

Owned objects: `streamManager`, `focusScorer`, `ocrEngine`, `exportManager`, `streamDatabase`, `performanceMonitor`, `recoveryStore`, `fileAccess`, `smartPauseCoordinator` (lazy).

Published state:
- `analyzedFrame: AnalyzedFrame?`: the frozen frame (pixel buffer, `CGImage`, playback time, OCR result).
- `currentOCRResult: OCRResult?`, `smartPauseSelection: SmartPauseSelection?`, `lastSmartPauseDiagnostics`.
- `statusMessage: StatusMessage?`, `isRecognizingText`, `isPerformingSmartPause`.
- `hasPlayer`, `currentSeekMode`, `hasCurrentStream`: coarse mirrors used by the menus.
- `showOCRInspector` (persisted).

Actions:

| Area | Methods |
|---|---|
| Connecting | `connect(to:)`, `connect(urlString:name:)`, `openFile(url:)`, `presentOpenFilePanel()`, `pasteStreamURL()`, `disconnect()`, `checkForRecoverableSession()` |
| Playback | `togglePlayPause()`, `seek(by:)`, `seek(toTimelinePosition:exact:)`, `stepFrame(backward:)`, `jumpToLive()`, `setSpeed(_:)`, `setVolume(_:)` |
| Analysis | `smartPause()`, `recognizeText()`, `dismissAnalysis()` |
| Copy / export | `copyOCRText()`, `copyText(_:)`, `copyFrame()`, `saveFrameAs()`, `quickSaveFrame()`, `exportOCRText()`, `exportFrameWithOCR()` |
| Misc | `showStatus(_:isError:duration:)`, `applyPreferences()`, `registerPlayerWindow(_:)` |

Statics: `isUITesting` (true under XCTest or with `SHARPSTREAM_UI_TESTING=1`), `normalizeStreamInput(_:)` (trims input, expands `~`, turns absolute paths into `file://` URLs), `defaultName(for:)`.

`UserDefaultsKey` lists the settings keys and registers their defaults.

## StreamManager (`Core/StreamManager.swift`)

`final class StreamManager: ObservableObject`

Published: `connectionState: ConnectionState`, `streamStats: StreamStats`, `currentStream: SavedStream?`, `seekMode: SeekMode`, `connectionLifecycle`, `reconnectAttempt`, `smartPauseSamplingTier`, `player: MPVPlayerWrapper?` (read-only).
`liveStore: LiveDVRStore` publishes `LiveDVRState` (window seconds, lag seconds, DVR start date) separately. `liveDVRState` reads and writes it.

Methods:
- `connect(to:)`, `disconnect()`, `startReconnect(reason:)`
- `seekToLiveEdge() -> Bool`, `seekLive(toWindowPosition:) -> Bool` (0 = oldest cached, window = live edge)
- `updateSmartPauseQoS(pipelineLoad:memoryPressure:)`
- `updateLiveBufferSettingsFromPreferences()`
- Pure helpers used by tests: `classifySeekMode(protocolType:duration:)`, `shouldAutoReconnect(protocolType:userInitiatedDisconnect:)`, `resolveLiveBufferSettings(...)`, `computeLiveDVRState(...)`, `resolveLiveWindowSeconds(...)`, `clampLiveSeekOffset(_:lagSeconds:)`, `maxBufferWindowSecondsFromDefaults()`

`SmartPauseSamplingTier`: `.normal` (4 FPS), `.reduced` (2 FPS), `.minimal` (1 FPS).

## MPVPlayerWrapper (`Core/MPVPlayerWrapper.swift`, `+Metrics.swift`)

`final class MPVPlayerWrapper: ObservableObject`, conforms to `SmartPausePlayer`.

- Init: `init(headless: Bool = false)`. Headless uses `vo=null` and no audio.
- Published: `isPlaying`, `duration`, `playbackSpeed`, `volume` (0–1), `isBuffering`, `videoSize`. The position lives in `clock: PlaybackClock` (`currentTime`); `precisePlaybackTime` is the unthrottled value.
- Loading: `loadStream(url:)`. It is deferred until `renderContextDidAttach()` is called by the video layer.
- Playback: `play()`, `pause()`, `togglePlayPause()`, `seek(to:exact:)`, `seek(offset:exact:)`, `setSpeed(_:)`, `setVolume(_:)`, `stepFrame(backward:)`.
- Capture: `setFrameCallback(_:)` (called on the capture queue with `(CVPixelBuffer, Date, TimeInterval?)`), `setFrameExtractionInterval(_:)`, `captureFrame() async -> CVPixelBuffer?`, `capturePipelineLoad() -> Double`.
- Live buffer: `applyLiveBufferSettings(maxWindowSeconds:backBufferBytes:)`.
- Metrics: `liveCacheMetrics() -> LiveCacheMetrics?` (window, window start, live edge, cache duration, input rate), `getTransportMetricsSnapshot()`, `getMetadata()`.
- Lifecycle: `eventHandler: ((MPVPlayerEvent) -> Void)?` (`fileLoaded`, `endFile(reason:message:)`, `shutdown`, `loadFailed`), `willDestroyHandle`, `cleanup()` (idempotent).

## FocusScorer (`Core/FocusScorer.swift`)

`nonisolated final class FocusScorer: ObservableObject`. Thread-safe.

- `scoreFrame(_:timestamp:playbackTime:sequenceNumber:) -> FrameScore`: scores the frame and records it as a sample and, if it can still win a window, as a candidate.
- `findBestFrame(in:now:)`, `selectBestFrame(in:now:currentPlaybackTime:seekMode:) -> SmartPauseSelection?`
- `frame(sequenceNumber:)`, `recentFrameCount(in:now:)`
- `getCurrentScore()`, `getScoringFPS(now:)`, `retainedFrameBytes()`
- `setAlgorithm(_:)`, `reset()`
- Tunables: `candidateRetention` (8 s), `sampleRetention` (30 s)

`SharpnessMetrics.score(_:algorithm:)` (`Utils/FocusMetrics/SharpnessMetrics.swift`) computes the metric for a BGRA buffer. `FocusAlgorithm`: `.laplacian`, `.tenengrad`, `.sobel`.

## SmartPauseCoordinator (`Core/SmartPauseCoordinator.swift`)

- `init(focusScorer:ocrEngine:configuration:)`. `Configuration` sets on-demand attempts (3), retry delay (0.15 s), warm-up delay (0.35 s), staleness padding/floor (1 s / 8 s) and an injectable `sleep`.
- `perform(request: SmartPauseRequest, player: SmartPausePlayer) async -> SmartPauseResult`
- `SmartPauseRequest`: `lookbackSeconds`, `seekMode`, `currentPlaybackTime`, `autoOCREnabled`
- `SmartPauseResult`: `selection`, `statusMessage`, `diagnostics`, `failureReason`, `selectedPixelBuffer`, `shouldRunOCR`, `isSuccess`
- `SmartPausePlayer` protocol: `currentTime`, `pause()`, `seek(to:exact:)`, `seek(offset:exact:)`, `captureFrame() async`. Tests use it for fakes.
- `SmartPauseFailureReason`: `noRecentFrames`, `staleSelection`, `seekRejected`, `seekDisabled`, `ocrFrameMissing`

## OCREngine (`Core/OCREngine.swift`)

`final class OCREngine: ObservableObject`

- Published settings: `isEnabled` (true), `recognitionLevel: OCRRecognitionLevel` (`.fast` / `.accurate`), `languages: [String]` (empty = automatic detection), `usesLanguageCorrection` (false).
- `recognizeText(in:) async -> OCRResult?` and `recognizeText(in:completion:)` (completion on main). Returns nil when disabled or when no text is found.

`OCRResult`: `text` (lines joined with newlines), `confidence` (average), `lines: [OCRLine]`, `boundingBoxes`, `timestamp`. `OCRLine`: `text`, `confidence`, `boundingBox` (Vision normalized, bottom-left origin).

## ExportManager (`Core/ExportManager.swift`)

- `cgImage(from:) -> CGImage?`
- `saveFrame(_:to:format:) throws`, `exportFrameWithOCR(_:ocrResult:to:format:) throws`, `annotate(_:with:) -> CGImage?`
- `exportOCRText(_:to:) throws`
- `copyFrameToClipboard(_:)`, `copyTextToClipboard(_:)`
- `ExportFormat`: `.png`, `.jpeg(quality:)`. `ExportError`: `.conversionFailed`, `.writeFailed`.

## SessionRecoveryStore (`Core/SessionRecoveryStore.swift`)

- `init(fileURL: URL? = nil)`. Defaults to `Application Support/SharpStream/session_recovery.json`.
- `markActive(streamURL:streamName:now:)`, `load(now:) -> SessionRecoveryData?` (ignores entries older than `maxAge`, 6 h), `clear()`

## FileAccessStore (`Core/FileAccessStore.swift`)

`@MainActor final class FileAccessStore`. Security-scoped bookmarks for local files.

- `remember(_ url: URL)`: store a read-only bookmark for a file the user just granted (Open panel, drop).
- `beginAccess(for urlString: String) -> String`: resolve a stored bookmark, start security-scoped access and return the URL string to use.
- `endAccess()`: stop access to the current file.
- `isPersistenceEnabled`: false in test runs.

## StreamDatabase (`Core/StreamDatabase.swift`)

- `init(baseDirectory: URL? = nil)`. Creates `SharpStream/streams.db` under the given directory (Application Support by default).
- Saved streams: `saveStream(_:)`, `getAllStreams()`, `getStream(byID:)`, `getStream(byURL:)`, `saveOrUpdateByURL(name:url:protocolType:lastUsed:)`, `deleteStream(byID:)`, `updateLastUsed(streamID:date:)`
- Recent streams: `addRecentStream(url:)`, `getRecentStreams(limit:)`, `clearRecentStreams()`

## Models and enums

- `SavedStream` (id, name, url, protocolType, dates), `RecentStream` (url, last used, use count)
- `StreamProtocol`: `rtsp`, `srt`, `udp`, `hls`, `http`, `https`, `file`, `unknown`. `detect(from:)` classifies a URL string.
- `ConnectionState`: `disconnected`, `connecting`, `connected`, `reconnecting`, `error(String)`
- `SeekMode`: `absolute`, `liveBuffered`, `disabled` (`allowsRelativeSeek`, `allowsTimelineScrubbing`)
- `FrameScore`, `SmartPauseSelection`, `SmartPauseDiagnostics`, `LiveDVRState`, `StreamStats`
- Utilities: `StreamURLValidator.validate(_:)` / `testConnection(to:timeout:)`, `StreamURLRedactor.redacted(_:)`, `VideoLayoutMapper.videoRect(container:source:)` / `mapVisionBox(_:in:)`, `TestStreamConfig`
