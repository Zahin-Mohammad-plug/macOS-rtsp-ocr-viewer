# Development Guide

## Setup

1. Clone the repository and open `SharpStream.xcodeproj`.
2. Xcode resolves MPVKit (0.41, Swift Package Manager) automatically. There are no other packages.
3. Select the **SharpStream** scheme and **My Mac**, then run (⌘R).

The project targets macOS 26.2 (`MACOSX_DEPLOYMENT_TARGET`). The app target uses Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are main-actor isolated unless marked `nonisolated` (for example `FocusScorer`, `SharpnessMetrics`, `OCRResult`).

See [BUILD.md](../BUILD.md) for command-line builds, signing and packaging, and [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together.

## Project layout

```
SharpStream/
├── App/        SharpStreamApp, AppState (actions + key monitor), AppMenu
├── Core/       MPVPlayerWrapper(+Metrics), StreamManager, FocusScorer, SmartPauseCoordinator,
│               OCREngine, ExportManager, SessionRecoveryStore, FileAccessStore, StreamDatabase,
│               TransportMetricsSampler
├── Views/      MainWindow, MPVVideoView, ControlsView, OCROverlayView, ExportView (More menu),
│               StreamListView, StreamConfigurationView, PreferencesView, StatsPanel
├── Models/     SavedStream, RecentStream, OCRResult, FrameScore, SmartPauseSelection,
│               SmartPauseDiagnostics, LiveDVRState, SeekMode, FocusAlgorithm, StreamStats
├── Utils/      FocusMetrics/SharpnessMetrics, StreamURLValidator, StreamURLRedactor,
│               VideoLayoutMapper, PerformanceMonitor, TestStreamConfig
└── Resources/  Info.plist, SharpStream.entitlements
SharpStreamTests/     unit tests
SharpStreamUITests/   UI tests
TestPlan.xctestplan   both targets (UI tests not parallelized)
scripts/              check / test scripts, DMG packaging
```

## Conventions

- **Add user actions to `AppState`** and call them from menus, buttons and shortcuts. Do not add NotificationCenter broadcasts for actions.
- **Unmodified key shortcuts** go in `AppState.handleKeyDown`, not in menu key equivalents, so text fields keep working. Menu items may show the key in their title (e.g. "Play / Pause   (Space)").
- **Keep work off the main thread**: frame capture belongs on the player's capture queue, OCR on the OCR queue.
- **High-frequency state** gets its own small observable (`PlaybackClock`, `LiveDVRStore`) instead of being forwarded through `AppState` or `StreamManager`.
- **Settings**: add a key to `UserDefaultsKey` (with a default in `registerDefaults()`), bind it with `@AppStorage` in `PreferencesView`, and apply it in `AppState.applyPreferences()` if an engine needs it.
- **Log URLs through `StreamURLRedactor`**; stream URLs often contain credentials.

## Environment variables

| Variable | Read by | Purpose |
|---|---|---|
| `SHARPSTREAM_OPEN_URL` | app | Connect to this URL / `file://` path at launch (dev hook; skips the resume check) |
| `SHARPSTREAM_UI_TESTING=1` | app | Throwaway storage and no resume prompt. Also enabled automatically when XCTest is loaded. |
| `SHARPSTREAM_DISABLE_BLOCKING_ALERTS=1` | app | Suppress the modal resume alert |
| `SHARPSTREAM_TEST_VIDEO_FILE` | UI tests | Local video for the file-playback test |
| `SHARPSTREAM_TEST_RTSP_URL` | UI tests | Live RTSP URL for the live test (e.g. a MediaMTX camera `rtsp://<host>:8554/cam`) |
| `SHARPSTREAM_TEST_STREAMS` | `TestStreamConfig`, scripts | Optional comma-separated list of extra sources |
| `SHARPSTREAM_SMOKE_ENV_FILE` | UI tests | Path of a `NAME=value` file to read the test variables from (default `/tmp/sharpstream_smoke.env`) |
| `SMART_PAUSE_REPEATS` | `smart_pause_test_matrix.sh` | Iterations per UI scenario (default 10) |

Put your values in `.env` (copy `.env.example`; `.env` is gitignored). The scripts source `.env` and write `/tmp/sharpstream_smoke.env` for the UI tests. Never commit real camera URLs or credentials.

### Sandbox and test videos

The app is sandboxed (network client/server, user-selected files, Downloads, Movies). Files the user picks or drops get a security-scoped bookmark (`FileAccessStore`) and reopen later from anywhere. A video opened through `SHARPSTREAM_OPEN_URL` or a test is not user-selected and has no bookmark, so it must be somewhere the app can read without a panel: `~/Downloads/…` or the app container's tmp directory, `~/Library/Containers/com.sharpstream.SharpStream/Data/tmp/`. If `SHARPSTREAM_TEST_VIDEO_FILE` is unset, the file test looks for `test_ocr.mp4` in that tmp directory.

## Tests

### Unit tests (`SharpStreamTests`)

`FocusScorerTests`, `SmartPauseCoordinatorTests`, `SmartPauseQoSTests`, `LiveDVRTests`, `MPVCacheRangeTests`, `StreamURLValidatorTests`, `StreamDatabaseTests`, `OCREngineTests`, `VideoLayoutMapperTests`, `FileAccessStoreTests`. They need no network or media.

```bash
xcodebuild test -project SharpStream.xcodeproj -scheme SharpStream \
  -destination 'platform=macOS' -only-testing:SharpStreamTests
```

The unit tests run inside the app as host. `AppState.isUITesting` detects XCTest, so the host uses throwaway storage and never shows the resume prompt. Previously a stale crash marker made the host show a modal alert that blocked the main thread and hung the run.

### UI tests (`SharpStreamUITests`)

Always run:
- `testLaunchShowsEmptyStateWithoutResumePrompt`
- `testControlsAreDisabledWithoutStream`
- `testTextFieldsReceiveSpacesInNewStreamSheet` (regression for keys swallowed by menu equivalents)

Opt-in (they skip when no source is configured):
- `testFilePlaybackSmartPauseAndTextRecognition`: file playback, controls fit in the window, Smart Pause, OCR on the Smart Pause frame
- `testLiveRTSPConnectsAndSmartPausesFromBuffer`: live connect, Smart Pause from the cache, Jump to Live

The tests launch the app with `SHARPSTREAM_UI_TESTING=1`, `SHARPSTREAM_DISABLE_BLOCKING_ALERTS=1`, `-ApplePersistenceIgnoreState YES` and `-showOCRInspector NO`, and pass stream sources through `SHARPSTREAM_OPEN_URL`.

Ways to provide the stream variables:
- in the scheme (Edit Scheme › Test › Arguments › Environment Variables);
- on the command line with the `TEST_RUNNER_` prefix, which xcodebuild forwards to the test runner:
  ```bash
  TEST_RUNNER_SHARPSTREAM_TEST_VIDEO_FILE=~/Downloads/sample.mp4 \
  TEST_RUNNER_SHARPSTREAM_TEST_RTSP_URL=rtsp://192.168.1.10:8554/cam \
  xcodebuild test -project SharpStream.xcodeproj -scheme SharpStream \
    -destination 'platform=macOS' -only-testing:SharpStreamUITests
  ```
- as `NAME=value` lines in `/tmp/sharpstream_smoke.env` (or the file named by `SHARPSTREAM_SMOKE_ENV_FILE`).

**UI automation must be enabled on the Mac.** When running from Xcode, approve the automation prompt. For command-line or unattended runs, enable it once:

```bash
sudo automationmodetool enable-automationmode-without-authentication
```

### Scripts

| Script | What it does | Artifacts |
|---|---|---|
| `scripts/full_check.sh` | Debug build, then all tests via `TestPlan` | console |
| `scripts/targeted_bug_pass.sh` | Build, unit tests, UI tests, each with logs and result bundles | `DerivedData/bug-pass/<timestamp>/` |
| `scripts/smart_pause_test_matrix.sh` | Smart Pause unit tests, then the file and RTSP UI tests `SMART_PAUSE_REPEATS` times each, with pass/fail counts; exports attachments for failed iterations | `DerivedData/smart-pause-tests/<timestamp>/` |
| `scripts/create_dmg.sh` | Builds Release and packages an unsigned local DMG (`SKIP_BUILD=1` to reuse a build) | `build/SharpStream-<version>.dmg` |

All test scripts load `.env` and write `/tmp/sharpstream_smoke.env`.

## Smart Pause diagnostics

`AppState.lastSmartPauseDiagnostics` holds the last run's `SmartPauseDiagnostics`: lookback, seek mode, frame counts before and after recovery, on-demand attempts, whether the warm-up wait was used, the selected sequence number / score / age / playback time, seek result and failure reason.

| `failureReason` | Where to look |
|---|---|
| `noRecentFrames` | Capture not running (paused, no frame callback, blank frames), or the lookback window is too short |
| `staleSelection` | Newest candidate is older than max(lookback + 1 s, 8 s): sampling stalled |
| `seekRejected` | `MPVPlayerWrapper.seek(to:exact:)` / `seek(offset:exact:)` failed |
| `seekDisabled` | `StreamManager.classifySeekMode` returned `.disabled` |
| `ocrFrameMissing` | The selected candidate's pixel buffer was evicted before OCR |

Sampling tiers (see `StreamManager.updateSmartPauseQoS`): 4 FPS normally; 2 FPS after 3 samples with capture load > 35% or on memory-pressure warning; 1 FPS after 3 samples with load > 70% or on critical memory pressure; up one tier after 10 samples with load < 20% and normal memory pressure. Load is capture + scoring time divided by the sampling interval, not process CPU.

## Manual checklist

- [ ] Resize the window, toggle sidebar and inspector, enter/leave fullscreen: the picture follows.
- [ ] Narrow the window: the control bar switches layouts without clipping buttons.
- [ ] Type spaces and use arrow keys in the New Stream sheet and the Settings language field.
- [ ] File: play, scrub, step frames, Smart Pause, text boxes line up, click-to-copy, export frame with boxes.
- [ ] Live RTSP: rewind, LIVE indicator, Jump to Live, Smart Pause from the cache.
- [ ] Unplug or stop the source: reconnect attempts, then the error card with Retry.
- [ ] Force-quit while playing, relaunch: resume prompt. Quit normally, relaunch: no prompt.
- [ ] Statistics window: Smart Pause frame memory stays small over a long session.
- [ ] Release build launches (no LuaJIT / hardened-runtime kill).

## Debugging

- mpv messages at warning level and above go to the console (`msg-level=all=warn`).
- Sampling-tier changes are printed (`Smart Pause sampling -> …`).
- A Release build that dies at launch with "Code Signature Invalid" usually means an mpv Lua script got enabled again; see the option list in `MPVPlayerWrapper.createHandle()`.
- If Smart Pause / OCR capture returns nothing, check that `hwdec` is still a copy-back mode; zero-copy frames cannot be read by `screenshot-raw` with the render API.

## Auto-update

There is no auto-update mechanism.

## Contributing

1. Create a feature branch.
2. Make your change and add or update tests.
3. Run `scripts/full_check.sh` (with `.env` configured if you touched playback, Smart Pause or OCR).
4. Open a pull request.

## OCR benchmark

`scripts/ocr_bench/` compiles the app's own `OCREngine` and `SharpnessMetrics` into a command-line harness and scores images against a ground-truth file (JSON array of `{"pt": 12, "text": "five random words and 123"}`). A truth line counts as read when its number and at least 4 of its 5 words appear on one recognized line.

```bash
# Score camera frames (e.g. grabbed with ffmpeg at 4 fps) and report which frame Smart Pause's metric would pick
scripts/ocr_bench/run.sh --truth testpage_truth.json frames/*.jpg

# Synthetic renders of the test page: resolution, defocus and rotation sweeps
scripts/ocr_bench/run.sh --truth testpage_truth.json --pdf ocr_testpage.pdf --height 1080 --blur 0,1,2,3 --rotate 72
```

Other options: `--csv`, `--min-height`, `--level fast|accurate`, `--correction`, `--languages`, `--upscale`.

`SharpStreamTests/OCRBenchmarkTests` embeds the same test page and guards three findings from these runs: sharp 1080p reads every line down to 12 pt, 720p needs the engine's < 1600 px upscale to reach 12-14 pt, and the frame ranked sharpest by the Laplacian metric is the frame OCR reads best.
