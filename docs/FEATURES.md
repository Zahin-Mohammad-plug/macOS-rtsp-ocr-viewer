# Feature List

This list covers what the current code does. See [USER_GUIDE.md](USER_GUIDE.md) for how to use each feature.

## Playback
- libmpv (MPVKit 0.41) playback of RTSP (over TCP), SRT, UDP, HLS, HTTP(S) and local files
- VideoToolbox hardware decoding in copy-back mode, with a ~2 s grace period before falling back to software (for live streams joined mid-GOP)
- Rendering through the libmpv render API (OpenGL, `CAOpenGLLayer`); follows window resizes, sidebar/inspector toggles and fullscreen
- Play/pause, ±5 s and ±10 s seeks, frame stepping (files), speed 0.25×/0.5×/1×/1.5×/2×, volume
- Timeline scrubbing with keyframe previews while dragging and an exact seek on release (files)
- Files stay loaded and seekable after they finish
- Drag and drop of files and URLs; open panel; open URL from clipboard

## Live rewind
- Pause and rewind live streams inside mpv's seekable demuxer cache
- Rewind window setting: 10 / 20 / 30 / 40 minutes (default 30); cache sized from bitrate, 512 MB–2 GB
- Timeline window taken from the real cache ranges; wall-clock labels; LIVE / behind-live indicator
- Jump to Live (⌘L)

## Smart Pause
- Background frame sampling at 4 FPS, adapting to 2 or 1 FPS based on capture+scoring cost and memory pressure
- Sharpness metrics with vImage/vDSP on a luma plane downscaled to 960 px max: Laplacian variance, Tenengrad, Sobel
- Bounded candidate store: only frames that can still win a lookback window keep their pixels
- Lookback window 1–5 s (default 3 s)
- Pauses, exact-seeks to the chosen frame and freezes that exact frame on screen
- Timeline marker for the selected frame (files)
- Optional automatic text recognition afterwards (on by default)
- Diagnostics and failure reasons (see [DEVELOPMENT.md](DEVELOPMENT.md))

## Text recognition
- Apple Vision `VNRecognizeTextRequest`, enabled by default
- Fast / Accurate (persisted), languages list or automatic detection, language correction (off by default)
- Per-line results in reading order with confidence
- Boxes on the frozen analyzed frame; hover shows the text, click copies the line
- Recognized Text inspector panel with Copy Line, Copy All and export
- Recognize Text (⌘R)

## Copy and export
- Copy recognized text (⇧⌘C), copy frame (⌥⌘C)
- Save Frame As… (⌘E), Quick Save Frame (⇧⌘E) to the last export folder
- Export recognized text as `.txt`
- Export frame with text boxes and labels drawn on it (PNG/JPEG)
- PNG exports keep correct (opaque) alpha

## Library
- Saved streams (add, edit, delete, connect) in SQLite
- Recent streams (last 5 in the sidebar, last 10 in File › Open Recent)
- URL validation per protocol and a Test Connection probe
- URLs shown without credentials or query strings in the sidebar, menus and prompts
- Security-scoped bookmarks so picked/dropped files reopen from Recent/Saved after a relaunch

## Reliability
- Automatic reconnect for network sources: up to 10 attempts with exponential backoff (1 s up to 30 s); 15 s connection timeout
- Resume prompt after an unclean exit only; cleared on clean quit or disconnect

## Statistics
- Separate Statistics window (⌥⌘I): health, bitrate, receive rate, buffer level, jitter/loss proxies, resolution, frame rate, codec, keyframe interval, rewind window, Smart Pause memory, focus score, CPU, scoring FPS, sampling tier, memory pressure

## Interface
- `NavigationSplitView` sidebar, video area, inspector for recognized text
- Two-row control bar with full, icon-only and minimal layouts
- Commands added to the standard File, Edit and View menus, plus a Playback menu
- Plain-key shortcuts that never swallow typing in text fields
- Settings window with General, Text, Export and Shortcuts tabs

## Not implemented
- Auto-update
- Published download (signed DMG / Homebrew): on hold until a Developer ID is available
- GPU usage metric (not collected)
- Batch export

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Play / pause |
| ← / → | Seek −5 s / +5 s (frame step when a file is paused) |
| ⌘← / ⌘→ | Seek −10 s / +10 s |
| ⌥⌘← / ⌥⌘→ | Back / forward 10 seconds |
| , / . | Previous / next frame |
| ⌘S | Smart Pause |
| ⌘R | Recognize Text |
| ⌘L | Jump to Live |
| ⇧⌘C | Copy Recognized Text |
| ⌥⌘C | Copy Frame |
| ⌘E / ⇧⌘E | Save Frame As… / Quick Save Frame |
| ⌘N | New Stream… |
| ⌘O | Open File… |
| ⇧⌘V | Open URL from Clipboard |
| ⇧⌘D | Disconnect |
| ⌥⌘T | Show / hide Text Panel |
| ⌥⌘I | Show Statistics |
| Esc | Dismiss analyzed frame |
| ⌘, | Settings |
