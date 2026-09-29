# SharpStream Architecture

## Overview

SharpStream is a SwiftUI macOS app. libmpv (via MPVKit) does networking, demuxing, decoding and rendering. The app adds a sampling pipeline that scores frames for sharpness, a Smart Pause action that returns to the sharpest recent frame, and Apple Vision OCR on that frame.

```
                  ┌───────────────────────────── AppState (@MainActor) ─────────────────────────────┐
 Menus / toolbar  │  actions: connect, seek, smartPause, recognizeText, copy/export, key monitor    │
 controls / keys ─┤  owns: StreamManager, FocusScorer, OCREngine, ExportManager, StreamDatabase,    │
                  │        SessionRecoveryStore, FileAccessStore, PerformanceMonitor,               │
                  │        SmartPauseCoordinator                                                    │
                  └───────┬───────────────────────────────┬──────────────────────────┬──────────────┘
                          │                               │                          │
                   StreamManager                  SmartPauseCoordinator          OCREngine
             (lifecycle, reconnect, seek         (select → pause → exact seek)   (Vision, OCR queue)
              mode, live DVR, sampling QoS)               │
                          │                               ▼
                   MPVPlayerWrapper ──frame callback──► FocusScorer ──► SharpnessMetrics (vImage/vDSP)
        (libmpv handle, event thread, capture queue)   (bounded candidate store)
                          │
                   MPVVideoView / MPVOpenGLLayer
            (render API, OpenGL, CAOpenGLLayer)
```

## Components

### App layer

- **SharpStreamApp** declares three scenes: the main `WindowGroup` (`MainWindow`), a `Window` with id `statistics` (`StatisticsWindowView`), and `Settings` (`PreferencesView`). `AppMenu` is installed as the command set.
- **AppState** is the single place user actions live. Menus, toolbar buttons, the control bar, context menus and keyboard shortcuts all call its methods directly (`connect`, `openFile`, `pasteStreamURL`, `disconnect`, `togglePlayPause`, `seek(by:)`, `seek(toTimelinePosition:exact:)`, `stepFrame`, `jumpToLive`, `smartPause`, `recognizeText`, `copyOCRText`, `copyFrame`, `saveFrameAs`, `quickSaveFrame`, `exportOCRText`, `exportFrameWithOCR`, `dismissAnalysis`). It also:
  - holds the frozen `AnalyzedFrame` (pixel buffer, `CGImage`, playback time, OCR result) shown while paused after Smart Pause / Recognize Text; resuming playback clears it;
  - applies Settings: it observes `UserDefaults.didChangeNotification` and pushes values into `FocusScorer` and `OCREngine`;
  - runs a 1 s timer that refreshes `StreamStats` (CPU, memory pressure, focus score, retained candidate memory) and feeds `StreamManager.updateSmartPauseQoS`;
  - installs a local `keyDown` monitor for Space, arrows, `,`, `.`, ⌘←/⌘→ and Esc on registered player windows. It returns early if a sheet is attached or the first responder is a text view/field;
  - exposes `isUITesting`, which switches the database and recovery store to a throwaway temp directory and suppresses the resume prompt.
- **AppMenu** extends the standard File, Edit and View menus (`CommandGroup(replacing: .newItem)`, `.saveItem`, `after: .pasteboard`, `after: .sidebar`) and adds a **Playback** menu. Only modifier shortcuts are registered as menu key equivalents.

### Core

- **MPVPlayerWrapper** owns one libmpv handle. It sets options, observes properties (`time-pos`, `duration`, `pause`, `speed`, `volume`, `paused-for-cache`, `video-params/aspect`), publishes playback state on main, and captures frames with `screenshot-raw video bgra` into pooled BGRA `CVPixelBuffer`s. The playback position is published through a separate `PlaybackClock` object at ~10 Hz granularity, so only time displays re-render on every tick. `MPVPlayerWrapper+Metrics` reads demuxer-cache state (seekable ranges, cache duration, input rate), track/codec info and frame type.
- **StreamManager** handles the connection lifecycle. Every connect creates a fresh `MPVPlayerWrapper` (the old one is cleaned up), installs the frame callback that forwards to `FocusScorer`, and starts a 15 s connection timeout. Network protocols auto-reconnect up to 10 times with backoff doubling from 1 s to 30 s; files do not. It classifies the `SeekMode` (`absolute` for files / VOD with a duration, `liveBuffered` for RTSP/SRT/UDP and live HLS/HTTP, `disabled` otherwise), applies live-buffer settings, samples transport metrics every 1 s and live DVR state every 0.25 s, and adapts the Smart Pause sampling tier. Live DVR state is published through its own `LiveDVRStore`.
- **FocusScorer** scores frames (`scoreFrame`) and stores Smart Pause candidates. It is thread-safe (one `NSLock`; scoring runs outside the lock).
- **SharpnessMetrics** (`Utils/FocusMetrics`) converts BGRA to a luma plane downscaled to a longest edge of 960 px and computes Laplacian variance, Tenengrad (mean squared Sobel gradients) or Sobel magnitude variance with vImage/vDSP.
- **SmartPauseCoordinator** implements Smart Pause (see below) and returns a `SmartPauseResult` with `SmartPauseDiagnostics`.
- **OCREngine** wraps `VNRecognizeTextRequest` and returns an `OCRResult` with per-line text, confidence and normalized bounding boxes.
- **ExportManager** converts pixel buffers to `CGImage` (Core Image), writes PNG/JPEG, copies images/text to the pasteboard, and draws OCR boxes and labels for "Export Frame with Text Boxes".
- **SessionRecoveryStore** writes `session_recovery.json` (URL, name, timestamp) when a stream loads and deletes it on disconnect or clean quit. Entries older than 6 hours are ignored.
- **FileAccessStore** keeps sandbox access to local files across launches. When a file is opened through the Open panel or drag and drop, `AppState.openFile` stores an app-scoped, read-only security bookmark for it in `UserDefaults` (`securityScopedFileBookmarks`). Whenever a `file://` source is connected later (from Recent, Saved, the clipboard or recovery), `AppState` resolves the bookmark and starts security-scoped access before URL validation; access ends on disconnect or when switching to a network source. Test runs do not persist bookmarks.
- **StreamDatabase** is a small SQLite store (`streams.db` in Application Support/SharpStream) with `saved_streams` and `recent_streams` tables.
- **TransportMetricsSampler** derives stream health, jitter and packet-loss proxies and keyframe interval from the per-second samples.
- **PerformanceMonitor** samples process CPU usage and memory pressure.

### Views

- **MainWindow**: `NavigationSplitView` with `StreamListView` (sidebar) and `PlayerDetailView` (video + controls), plus an `.inspector` with `OCRInspectorView` ("Recognized Text"). Toolbar: Open URL from Clipboard, Open File, Statistics, Text Panel.
- **VideoPlayerView**: layers the `MPVVideoView`, the `AnalyzedFrameOverlay` (frozen frame + OCR boxes), connection cards (connecting/reconnecting/error with Retry/Close), the empty state, progress/buffering badges and status toasts. Accepts dropped files/URLs and has a context menu.
- **MPVVideoView / MPVOpenGLLayer**: the video surface (see decisions below). The view is keyed on the player's identity, so each player gets its own view and GL context.
- **ControlsView**: timeline row plus a control row rendered with `ViewThatFits` in three layouts: full (icons + labels, inline volume slider), compact (icon-only, volume popover) and minimal (frame-step buttons, speed and volume move into the More menu).
- **ExportMenu** (`ExportView.swift`): the "More" menu with copy/save/export items.
- **StreamConfigurationView**: add/edit stream sheet with validation and Test Connection.
- **PreferencesView**: Settings tabs General, Text, Export, Shortcuts.
- **StatsPanel / StatisticsWindowView**: statistics.

## Threading model

| Context | What runs there |
|---|---|
| Main thread (`@MainActor`) | SwiftUI, `AppState`, `StreamManager` and its timers, playback commands, all `@Published` state, Smart Pause orchestration |
| mpv event thread (`com.sharpstream.mpv-events`) | `mpv_wait_event` loop. Event payloads are copied, then forwarded to main with `DispatchQueue.main.async` |
| Capture queue (`com.sharpstream.frame-capture`) | Sampling timer, `screenshot-raw`, pixel-buffer copy, blank-frame check, and the frame callback into `FocusScorer.scoreFrame`. On-demand captures (`captureFrame()`) also run here, never on main |
| OCR queue (`com.sharpstream.ocr`) | Vision requests. Results are delivered back on main |
| Core Animation render thread | `MPVOpenGLLayer.canDraw` / `draw`: `mpv_render_context_render` into the layer's FBO. The CGL context lock serializes drawing with render-context teardown |
| Global utility queue | `mpv_terminate_destroy` during player teardown |

libmpv's client API is thread-safe, so the handle is used from main, the event thread and the capture queue. Only `cleanup()` clears it, after it has stopped the capture timer (synchronously on the capture queue) and waited up to 2 s for the event thread to exit. It then frees the render context via `willDestroyHandle` and destroys the handle off the main thread. If the event thread does not exit in time, the handle is deliberately leaked instead of being destroyed underneath it.

## Data flow

### Playback
1. `AppState.connect(urlString:)` normalizes the input, resolves a stored security bookmark for local files, validates it, builds a `SavedStream` and calls `StreamManager.connect(to:)`.
2. `StreamManager` creates a `MPVPlayerWrapper`, applies live-buffer settings, sets the frame callback and calls `loadStream`. The `loadfile` command is deferred until the video layer has created its render context (`renderContextDidAttach`), because without one mpv would disable the video track.
3. `MPVVideoView` appears for the new player; `MPVOpenGLLayer` creates the render context and mpv starts drawing.
4. On `MPV_EVENT_FILE_LOADED`, `StreamManager` marks the stream connected, re-classifies the seek mode with the real duration, starts playback, starts periodic sampling, records the recent stream and writes the recovery marker.
5. End-of-file / errors either reconnect (network sources) or show an error card. Because of `keep-open=yes`, a file that reaches its end stays loaded.

### Frame capture and scoring
1. The capture timer fires every 0.25 s / 0.5 s / 1 s depending on the sampling tier. Capture is skipped while paused, since a paused picture would only add duplicates with fresh timestamps.
2. `screenshot-raw video bgra` returns the decoded frame at video resolution (no OSD or letterboxing). It is copied into a pooled BGRA buffer; `bgr0` padding is forced opaque; near-black frames are dropped.
3. The callback calls `FocusScorer.scoreFrame` on the capture queue with the wall-clock timestamp and mpv `time-pos`.
4. The capture cost (EWMA) divided by the interval is the pipeline load. Once a second `StreamManager.updateSmartPauseQoS` uses it with memory pressure: load > 35% for 3 samples drops normal → reduced (2 FPS), load > 70% for 3 samples → minimal (1 FPS), critical memory pressure → minimal right away, warning → reduced. After 10 stable samples (load < 20%, normal memory) it moves up one tier.

### Smart Pause
1. `AppState.smartPause()` passes the lookback window (clamped to 1–5 s), seek mode, precise playback time and the auto-OCR setting to `SmartPauseCoordinator.perform`.
2. The coordinator asks `FocusScorer` for the best candidate in the window. If none exists, it captures and scores the current frame on demand (up to 3 attempts, 0.15 s apart), then waits 0.35 s once more.
3. It rejects selections older than max(lookback + 1 s, 8 s), and sources whose seek mode is `disabled`.
4. It pauses and performs an **exact** seek: to the frame's `time-pos` for files, and for live streams to the frame's stream timestamp inside mpv's cache (relative seek by frame age as a fallback).
5. `AppState` shows the candidate's retained pixel buffer as the frozen `AnalyzedFrame`, so the picture on screen is exactly the frame that was scored. On a file, an orange marker on the timeline shows the selected position.
6. If auto-OCR is on and OCR is enabled, the same pixel buffer is sent to `OCREngine`.

Failures are reported as `SmartPauseFailureReason` (`noRecentFrames`, `staleSelection`, `seekRejected`, `seekDisabled`, `ocrFrameMissing`) together with diagnostics.

### OCR
1. `recognizeText()` uses the frozen frame if there is one; otherwise it pauses, captures the current frame on the capture queue and freezes it.
2. `OCREngine` runs `VNRecognizeTextRequest` on the OCR queue with the configured level, languages (or automatic detection), language correction and `minimumTextHeight = 0.01`, orientation `.up`. If a language list yields nothing, it retries once with automatic detection.
3. Observations are sorted into reading order and turned into `OCRLine`s.
4. The result is attached to the `AnalyzedFrame` only if that frame is still displayed. `AnalyzedFrameOverlay` maps the Vision boxes into the aspect-fit rect of that image (`VideoLayoutMapper`), so the boxes line up at any window size. The inspector lists the lines.

### Export
Copy/save actions use the frozen frame if present, otherwise a fresh capture. `ExportManager.exportFrameWithOCR` draws each line's box and label into a copy of the frame before writing PNG/JPEG. Save panels start in the last-used export folder (Pictures by default).

## Buffering and memory

- **No app-side frame buffer.** The earlier `BufferManager` (RAM ring buffer, JPEG re-encoding, disk dump, its own recovery index) is gone. On launch `AppState` deletes its leftover tmp directory and `buffer_index.json`.
- **Live DVR = mpv's seekable demuxer cache.** For `liveBuffered` sources the player sets `cache=yes`, `demuxer-seekable-cache=yes`, `cache-secs` = rewind window and `demuxer-max-back-bytes` = bitrate / 8 × window × 1.2, at least 512 MB and at most 2 GB (512 MB when the bitrate is not known yet). The value is kept stable for the session unless the Settings value changes. The timeline window comes from the cache's real seekable ranges, not from elapsed session time.
- **Bounded Smart Pause candidates.** Every scored frame is stored as a lightweight sample (timestamp + score) for 30 s for statistics. A pixel buffer is only kept while its frame could still be the sharpest frame of some lookback window ending now, i.e. no newer frame is at least as sharp. That set is kept with timestamps ascending and scores strictly decreasing, and anything older than 8 s is dropped, so memory is independent of session length and usually a handful of frames. The Statistics window shows the retained size as "Smart Pause Frames".

## Key design decisions

- **libmpv render API instead of `wid`.** With `wid` + Vulkan/MoltenVK (gpu-next), mpv sized its swapchain once and never followed the embedding view, so resizing, sidebar/inspector toggles and fullscreen left a stale or cropped picture. With `vo=libmpv` and the OpenGL render API in a `CAOpenGLLayer`, the app passes the framebuffer size on every draw.
- **One video view per player.** `MPVVideoView` is keyed on the player's `ObjectIdentifier`. A reconnect gets a fresh GL context, and teardown order is always render context first, then the mpv handle.
- **Copy-back hardware decode (`hwdec=videotoolbox-copy`).** Zero-copy VideoToolbox frames could not be read back by `screenshot-raw` with the render API, which silently broke Smart Pause and OCR capture. Copy-back costs one GPU→RAM copy per frame (cheap on unified memory) and capture keeps working when the window is hidden or occluded.
- **`hwdec-software-fallback=60`.** Joining a live H.264 stream mid-GOP produces frames VideoToolbox rejects until the next keyframe. mpv's default gives up on hardware decode after 3 failures and stays on software for the whole session. 60 frames is about 2 s.
- **`sws-fast=yes`.** swscale's full-chroma path dominated CPU converting 1080p NV12 → BGRA for capture. Chroma precision does not matter for sharpness or OCR.
- **All built-in mpv Lua scripts disabled.** They run on LuaJIT, whose JIT pages violate the hardened runtime, and signed Release builds were SIGKILLed ("Code Signature Invalid") at launch. `load-scripts=no` only covers user scripts, so each built-in (`ytdl`, stats, console, OSD console, auto-profiles, select, commands, context menu, positioning) is switched off. The OSC and default input bindings are off too; the app provides its own controls.
- **Smart Pause QoS driven by capture cost, not total CPU.** Video decode alone exceeds any fixed process-CPU threshold, which pinned sampling at 1 FPS before.
- **Frozen analyzed frame.** OCR boxes are drawn over the exact pixels that were recognized instead of over the live player, so they line up regardless of where the player landed after a seek.
- **AppState action hub instead of a NotificationCenter bus.** Previously menus broadcast notifications that only worked if the right view was on screen. Actions are now direct method calls. A few notifications remain for sidebar/sheet refresh (`showNewStreamSheet`, `saveCurrentStreamRequested`, `savedStreamsUpdated`, `recentStreamsUpdated`).
- **Key monitor instead of plain-key menu equivalents.** Menu key equivalents fire before text fields see the key, which made it impossible to type a space or move the caret. Unmodified keys are handled by the monitor, which skips text fields and sheets.
- **Coarse state mirrors in AppState.** `AppState` mirrors only `hasPlayer`, `currentSeekMode` and `hasCurrentStream` for the menus. Forwarding every `StreamManager` change would re-render the whole window several times a second on live streams. Views that need fine-grained state observe `StreamManager`, `PlaybackClock` or `LiveDVRStore` directly.
- **No window-frame management.** Window size and position are left to AppKit state restoration. The old code that called `setFrame` on every SwiftUI update was removed.

## Storage

| Data | Location |
|---|---|
| Saved and recent streams | `~/Library/Containers/com.sharpstream.SharpStream/Data/Library/Application Support/SharpStream/streams.db` |
| Session recovery marker | same folder, `session_recovery.json` |
| Settings and file bookmarks | `UserDefaults` (`com.sharpstream.SharpStream`) |
| Test runs | a `SharpStreamUITest-<UUID>` folder in the temp directory |

## Testing

- **SharpStreamTests** (unit): `FocusScorerTests`, `SmartPauseCoordinatorTests`, `SmartPauseQoSTests`, `LiveDVRTests`, `MPVCacheRangeTests`, `StreamURLValidatorTests`, `StreamDatabaseTests`, `OCREngineTests`, `VideoLayoutMapperTests`, `FileAccessStoreTests`.
- **SharpStreamUITests**: empty state without a resume prompt, controls disabled without a stream, text fields receive spaces in the New Stream sheet, and opt-in stream tests (file playback + Smart Pause + OCR; live RTSP + Smart Pause + Jump to Live).

See [DEVELOPMENT.md](DEVELOPMENT.md) for how to run them.
