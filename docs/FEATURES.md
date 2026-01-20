# Feature List

## Core Features (All Implemented ✅)

### Video Playback
- ✅ Multi-protocol stream support (RTSP, SRT, UDP, HLS, HTTP, local files)
- ✅ Hardware-accelerated decoding via MPVKit
- ✅ Drag and drop video files (MP4, MKV, MOV, AVI, TS, etc.)
- ✅ File menu open dialog (⌘O)
- ✅ Stream URL paste (⌘⇧N)

### Playback Controls
- ✅ Play/Pause (Space)
- ✅ Timeline scrubber (seek to any position)
- ✅ Rewind/Forward 10 seconds (⌘←/⌘→)
- ✅ Frame-by-frame navigation (←/→)
- ✅ Speed control (0.25x - 2x)
- ✅ Volume control

### Smart Features
- ✅ Smart Pause - finds sharpest frame automatically (⌘S)
- ✅ Focus scoring with Laplacian algorithm
- ✅ Configurable lookback window (1-5 seconds)
- ✅ OCR text recognition with Vision framework
- ✅ Auto-OCR on smart pause (optional)
- ✅ OCR bounding box visualization

### Buffering
- ✅ RAM buffer (configurable: 1s/3s/5s)
- ✅ Disk buffer (up to 40 minutes)
- ✅ Frame compression (JPEG) for efficiency
- ✅ Crash recovery with resume dialog
- ✅ Automatic buffer cleanup

### Export
- ✅ Save frame as PNG/JPEG
- ✅ Copy frame to clipboard
- ✅ Export OCR text to .txt file
- ✅ Copy OCR text to clipboard
- ✅ Export frame with OCR overlay
- ✅ Batch export (multiple frames)

### Stream Management
- ✅ Save streams to library
- ✅ Recent streams (last 5)
- ✅ Quick stream switching
- ✅ Stream URL validation
- ✅ Connection testing
- ✅ Auto-reconnect with exponential backoff

### Statistics & Monitoring
- ✅ Connection status
- ✅ Bitrate, resolution, frame rate
- ✅ Buffer health (RAM/disk usage)
- ✅ Focus score display
- ✅ CPU/GPU usage
- ✅ Memory pressure indicator
- ✅ Focus scoring FPS

### Preferences
- ✅ Buffer size configuration
- ✅ Maximum buffer length
- ✅ Lookback window duration
- ✅ Focus algorithm selection
- ✅ OCR settings (enable, level, language)
- ✅ Auto-OCR toggle

### UI Features
- ✅ Fullscreen support (⌘⌃F)
- ✅ Window size persistence
- ✅ Sidebar stream list
- ✅ Stats panel
- ✅ OCR overlay with bounding boxes
- ✅ Recovery dialog
- ✅ Error alerts

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Play/Pause |
| ⌘← / ⌘→ | Rewind/Forward 10s |
| ← / → | Step frame backward/forward |
| ⌘S | Smart Pause |
| ⌘+ / ⌘- | Increase/Decrease speed |
| ⌘O | Open file |
| ⌘⇧N | Paste stream URL |
| ⌘⌃F | Toggle fullscreen |
| ⌘, | Preferences |

## Supported Formats

### Video Files
- MP4, MKV, MOV, AVI, M4V, TS, MTS, WebM, FLV, WMV, MPG, MPEG, 3GP

### Stream Protocols
- RTSP (rtsp://)
- SRT (srt://)
- UDP (udp://)
- HLS (HTTP Live Streaming)
- HTTP/HTTPS
- Local files (file://)

## Testing

**Quick Test**: Drag an MP4 file onto the video player window!

The app is fully functional and ready for testing. All core features from the original plan have been implemented.
