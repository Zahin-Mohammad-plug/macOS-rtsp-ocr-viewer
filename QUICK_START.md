# Quick Start

## 1. Build and run

Requirements: macOS 26.2 or later and a current Xcode.

```bash
open SharpStream.xcodeproj
```

Select the **SharpStream** scheme and **My Mac**, then press ⌘R. Xcode resolves the only package dependency (MPVKit) on first build.

## 2. Play something

- Drag a video file (MP4, MOV, MKV, TS, …) onto the video area, or
- **File › Open File…** (⌘O), or
- copy a stream URL (`rtsp://…`, `srt://…`, `udp://…`, an HLS `.m3u8`, …) and press ⇧⌘V.

The app is sandboxed. Files picked in the Open panel or dropped on the window work from anywhere; for other paths, keep test videos in `~/Downloads` or `~/Movies`.

## 3. Try the main features

1. **Playback**: Space to play/pause, ← / → to seek 5 s, `,` / `.` to step frames on a file.
2. **Smart Pause**: let it play for a few seconds, then press ⌘S. The sharpest frame from the last 3 seconds is frozen on screen.
3. **Text**: if the frame contains text, green boxes appear (recognition runs after Smart Pause by default). Click a box to copy its line, or press ⌘R to recognize the current frame. ⌥⌘T shows the Recognized Text panel.
4. **Export**: ⇧⌘C copies all text, ⌥⌘C copies the frame, ⌘E saves it. The **…** menu in the control bar has all export options.
5. **Live streams**: pause or drag the timeline to rewind; ⌘L jumps back to live.
6. **Statistics**: ⌥⌘I.
7. **Settings**: ⌘, (rewind window, lookback window, sharpness metric, OCR options, export format).

Press Space or Esc to leave the frozen frame.

## Launching straight into a stream (development)

Set `SHARPSTREAM_OPEN_URL` in the scheme's environment (Product › Scheme › Edit Scheme › Run › Arguments) to a URL or `file://` path. The app connects to it at launch.

## Troubleshooting

- **File won't open**: see the sandbox note above.
- **Stream won't connect**: check the URL with Test Connection in the New Stream sheet (⌘N).
- **Build errors**: File › Packages › Reset Package Caches, then clean (⇧⌘K) and rebuild.

## Next steps

- [docs/USER_GUIDE.md](docs/USER_GUIDE.md): full user guide
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): tests and development workflow
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how it works
