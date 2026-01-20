# SharpStream User Guide

## Getting Started

### Opening a Video File

SharpStream supports multiple ways to open video files:

1. **Drag and Drop** (Easiest)
   - Simply drag any video file (MP4, MKV, MOV, AVI, TS, etc.) onto the video player window
   - The file will start playing automatically

2. **File Menu**
   - File > Open... (⌘O)
   - Browse and select a video file

3. **Stream URL**
   - Paste a stream URL (RTSP, SRT, UDP, HLS, etc.) using ⌘⇧N
   - Or click "Paste Stream URL" in the toolbar

### Supported Video Formats

**Local Files:**
- MP4, MKV, MOV, AVI, M4V, TS, MTS, WebM, FLV, WMV, MPG, MPEG

**Stream Protocols:**
- RTSP (rtsp://)
- SRT (srt://)
- UDP (udp://)
- HLS (http:// or https:// with .m3u8)
- HTTP/HTTPS streams
- Local file paths (file://)

## Features Overview

### Playback Controls

- **Play/Pause**: Space bar or play button
- **Seek**: Click and drag on timeline scrubber
- **Rewind 10s**: ⌘← or rewind button
- **Forward 10s**: ⌘→ or forward button
- **Frame-by-Frame**: ← → arrow keys
- **Speed Control**: Use speed picker (0.25x - 2x)
- **Volume**: Adjust with volume slider

### Smart Pause

Find the sharpest frame in recent playback:
1. Click "Smart Pause" or press ⌘S
2. App automatically finds best frame in last 3 seconds (configurable)
3. If Auto-OCR is enabled, text recognition runs automatically

### OCR (Text Recognition)

- Enable OCR in Preferences (OCR tab)
- Toggle OCR overlay visibility
- View bounding boxes around recognized text
- Copy text to clipboard by clicking on overlay
- Export OCR text to file

### Export Options

Access via Export button (⬇️) in toolbar:

- **Save Frame as Image**: Export current frame as PNG/JPEG
- **Copy Frame**: Copy current frame to clipboard
- **Export OCR Text**: Save recognized text to .txt file
- **Copy OCR Text**: Copy text to clipboard
- **Export Frame with OCR**: Composite image with text overlay

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

## Preferences

Access via SharpStream > Preferences or ⌘,

### Buffer Settings
- **RAM Buffer Size**: Low (1s), Medium (3s), High (5s)
- **Maximum Buffer Length**: 20/30/40 minutes

### Smart Pause
- **Lookback Window**: 1-5 seconds (default: 3s)
- **Auto-OCR**: Automatically run OCR on smart pause

### OCR Settings
- **Enable OCR**: Toggle text recognition
- **Recognition Level**: Fast or Accurate
- **Language**: Language code (e.g., en-US, fr-FR)

### Focus Algorithm
- **Laplacian**: Standard variance-based scoring (default)
- **Tenengrad**: Gradient-based method (coming soon)
- **Sobel**: Edge detection-based (coming soon)

## Tips & Tricks

1. **Quick Testing**: Drag an MP4 file onto the window to test playback
2. **Multiple Streams**: Save frequently used streams in the sidebar
3. **Recent Streams**: Last 5 used streams appear in sidebar
4. **Export Quality**: Adjust JPEG quality in export dialog
5. **Performance**: Lower RAM buffer size if experiencing memory issues
6. **OCR Languages**: Support multiple languages by adding codes separated by commas

## Troubleshooting

**Video won't play:**
- Check file format is supported
- Verify file isn't corrupted
- For streams: Check network connectivity and URL

**No OCR results:**
- Enable OCR in Preferences
- Ensure text is visible and clear in frame
- Try "Accurate" recognition level

**Performance issues:**
- Reduce RAM buffer size
- Lower frame extraction FPS
- Close other applications

**Stream connection fails:**
- Verify URL is correct
- Check network connectivity
- Test with "Test Connection" button
