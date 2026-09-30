# Changelog

## [Unreleased] - stream testing round

### Fixed
- Smart Pause while already paused now looks back from the moment playback paused (it used to pick the frame on screen).
- Jump to Live and live rewind use exact seeks; on streams with long keyframe intervals they landed up to ~7 s off.
- Live HLS is detected as live (playlist probe), with LIVE badge, rewind and Jump to Live; it was treated as a file.
- SRT is rejected up front with guidance: the bundled FFmpeg has no libsrt, so it could never connect.
- Smart Pause sampling no longer drops to 2 FPS because of the capture spike right after connecting.
- Statistics no longer rate HLS / HTTP streams "Degraded": segment downloads are bursty by design and were read as jitter and loss.
- Capture timer leeway 20 ms -> 5 ms, so the sampling interval really bounds the gap between samples.

### Added
- Live timeline shows how much is buffered ("4:32 buffered"); hover for the maximum and memory used.
- Rewind buffer capped at 1/8 of physical RAM (max 2 GB) instead of a flat 2 GB.
- `scripts/stream_matrix.sh` + DEBUG self test: end-to-end checks per source (connect, playback, rewind, Jump to Live, Smart Pause playing and paused, OCR with `EXPECT_TEXT`).
- `scripts/local_streams.sh`, `scripts/make_demo_clip.sh`, `scripts/range_http_server.py`, `scripts/run.sh`.
- Settings › Smart Pause › **Sampling rate**: Standard (4/s, default) or High (8/s) for sources that are sharp only for a split second (focus hunting). QoS halves it under load.
- Smart Pause candidate store capped at 32 frames (the old 4 FPS worst case), so higher sampling can't multiply memory.
- Self-test modes `soak`, `switch`, `ocrsweep` and `APP_ARGS` overrides in `stream_matrix.sh`; `make_ocr_ladder.sh` difficulty ladder and difficulty knobs on `make_demo_clip.sh`.

## [Unreleased] - player and pipeline rework

### Fixed
- **Video follows resizes.** Video is drawn through libmpv's render API (OpenGL, `CAOpenGLLayer`) instead of `wid` + Vulkan/MoltenVK. With `wid`, window resizes, sidebar/inspector toggles and fullscreen left a stale, cropped picture. Each player instance now has its own video view.
- **Window size.** Removed the code that called `setFrame` on every SwiftUI update. It snapped windows back, overwrote saved sizes and fought fullscreen.
- **Control bar.** The two-row control bar adapts to the window width (labels, icons only, overflow menu) instead of overflowing and squashing buttons. Timeline scrubbing shows keyframe previews and does an exact seek on release.
- **Menus and keyboard.** Commands extend the standard File/Edit/View menus instead of adding duplicate menus. ⌘C is no longer taken over. Space, arrows, `,` and `.` are handled by a key monitor that skips text fields, so typing works in sheets and fields. Menus and controls call `AppState` actions directly (no NotificationCenter bus). The ⌘Space shortcut was removed. Recognize Text is ⌘R.
- **OCR.** Enabled by default, per-line results, recognition level persisted. The rotated retries that put boxes in the wrong coordinate space were removed. Boxes are drawn over the frozen analyzed frame, so they always line up; click a box to copy its line. "Export Frame with Text Boxes" now actually draws the boxes. PNG exports keep correct alpha.
- **Smart Pause.** Sampling QoS is driven by capture cost, not total process CPU, which had pinned sampling at 1 FPS. Smart Pause exact-seeks to the chosen frame and freezes that exact frame on screen.
- **Memory.** `FocusScorer` keeps pixel buffers only for frames that can still win a lookback window (previously up to 1000 full-resolution frames), scores a downscaled luma plane with vImage/vDSP, and is thread-safe.
- **Live-stream hardware decode.** Joining a live H.264 stream mid-GOP made VideoToolbox reject frames and mpv switched to software decode for the whole session. Hardware decode now has ~2 s to get the first keyframe (`hwdec-software-fallback=60`). Copy-back decode (`videotoolbox-copy`) keeps frame capture working with the render API even when the window is hidden. Capture uses `sws-fast`.
- **Release crash.** Release (hardened runtime) builds were SIGKILLed at launch ("Code Signature Invalid") because mpv's built-in Lua scripts run on LuaJIT. All built-in scripts are disabled.
- **Live DVR window.** It comes from mpv's actual cache ranges instead of growing with session time. Live DVR state and the playback clock have their own observables, so 4–10 Hz updates no longer re-render the whole window.
- **Resume prompt.** Shown only after an unclean exit; cleared on clean quit or disconnect. URLs are redacted in the sidebar, menus and prompts.
- **Files at EOF.** Finished files stay loaded and seekable (`keep-open`).
- **Reopening files.** Files opened through the Open panel or drag and drop were readable only for that session, so Recent/Saved entries for them failed after a relaunch. A security-scoped bookmark is now stored per file and resolved before validation. Test runs do not store bookmarks.
- **Test isolation.** UI tests and the unit-test host use throwaway storage and never show the resume prompt. A stale crash marker used to block the unit-test host with a modal alert and hang the run.

### Changed
- Removed the app-side frame buffer (`BufferManager`: RAM ring buffer, JPEG re-encoding, disk frame dump, recovery index). mpv's seekable demuxer cache is the live rewind buffer, sized from bitrate and the "Rewind window" setting (10/20/30/40 min, max 2 GB). Leftover buffer files are deleted on launch.
- New layout: `NavigationSplitView` sidebar, inspector with recognized text, separate Statistics window.
- Settings reorganized into General, Text, Export and Shortcuts tabs.
- UI tests rewritten for the new UI. They launch via `SHARPSTREAM_OPEN_URL`, include regression tests for text-field keystrokes, clipped controls, Smart Pause, OCR and live Jump to Live, and stream tests are opt-in. `SmartPauseQoSTests` was never part of the test target and now runs; `FileAccessStoreTests` added.

### Removed
- The OpenCV package (`opencv-spm`). It was never linked to a target, so the "OpenCV" code paths never ran. Sharpness metrics use vImage/vDSP.
- `DebugLogger`, `CMSampleBuffer`/`CVPixelBuffer` extensions, `ExportManager.batchExport`, `KeyboardShortcuts`, `CopyCommandMode`, `WindowAccessor`, the Swift/OpenCV focus scorer classes.

### Documentation
- Rewrote the README and all docs to match the current design. Sparkle auto-update is documented as not implemented.

## [Earlier unreleased work]

The entries below were written before the rework. Several no longer apply: the disk buffer, JPEG frame compression, the buffer-based crash recovery, batch export and window-size persistence code were all removed.

### Added
- ✅ MPVKit integration with full video playback support
- ✅ Frame extraction pipeline for buffering and OCR
- ✅ Disk buffer implementation for extended buffering (up to 40 minutes)
- ✅ Complete export functionality (frames, OCR text, composite images)
- ✅ Frame compression (JPEG) for memory efficiency
- ✅ Crash recovery with resume dialog
- ✅ Connection testing for stream URLs
- ✅ OCR bounding box visualization toggle
- ✅ Fullscreen support
- ✅ Window state persistence (size)
- ✅ Preferences integration (all settings wired up)

### Changed
- Updated implementation status to ~95% complete
- Reorganized documentation structure
- Improved error handling throughout

### Documentation
- Added comprehensive architecture documentation
- Created MPVKit integration guide
- Added development guide
- Updated README with documentation links

## Implementation Status

**Current Progress: ~95% Complete**

All core features from the original plan have been implemented:
- ✅ Video playback (all protocols)
- ✅ Frame buffering (RAM + disk)
- ✅ Focus scoring
- ✅ OCR text recognition
- ✅ Export functionality
- ✅ Crash recovery
- ✅ Preferences management
- ✅ Performance monitoring

### Remaining Items (Optional Enhancements)
- Tenengrad/Sobel focus algorithms (UI ready, implementation pending)
- Advanced render context optimization
- Additional export formats
