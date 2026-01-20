# Quick Start Guide

## Testing the Application

The easiest way to test SharpStream is to drag and drop a video file!

### Step 1: Build the Project

```bash
open SharpStream.xcodeproj
```

In Xcode:
- Press ⌘R to build and run
- Or Product > Run

### Step 2: Test with Drag & Drop

1. **Open the app** - You'll see "No Stream Connected" message
2. **Drag an MP4 file** (or any supported video) from Finder onto the video player area
3. **Video starts playing automatically!**

### Supported Video Formats

Drag and drop supports:
- **MP4** - Most common format
- **MKV** - Matroska container
- **MOV** - QuickTime format
- **AVI** - Classic format
- **TS** - Transport stream
- **WebM** - Web format
- And more (see full list in [README.md](README.md))

### Alternative Testing Methods

**Option 1: File Menu**
- File > Open... (⌘O)
- Select a video file

**Option 2: Stream URL**
- Copy a stream URL (RTSP, SRT, etc.) to clipboard
- Press ⌘⇧N or click "Paste Stream URL" in toolbar

**Option 3: Add to Stream Library**
- Click "+" in sidebar
- Enter name and URL
- Click "Save" then connect

## Features to Test

Once video is playing:

1. **Playback Controls**
   - Space bar: Play/Pause
   - Timeline scrubber: Seek to any position
   - Arrow keys: Step frame-by-frame

2. **Smart Pause**
   - Press ⌘S or click "Smart Pause" button
   - App finds sharpest frame in last 3 seconds

3. **OCR** (if text visible in video)
   - Enable OCR in Preferences (⌘,)
   - Click Smart Pause to trigger OCR
   - Text appears in overlay

4. **Export**
   - Click export button (⬇️) in toolbar
   - Export current frame, OCR text, or composite image

## Troubleshooting

**File won't play:**
- Check file format is supported
- Verify file isn't corrupted
- Try a different video file

**No video appears:**
- Check console for errors
- Verify MPVKit is properly linked
- Ensure file path is valid

**Build errors:**
- Clean build folder (⌘⇧K)
- Reset package caches (File > Packages > Reset Package Caches)
- Verify SPM dependencies resolved correctly

## Next Steps

- See [docs/USER_GUIDE.md](docs/USER_GUIDE.md) for complete usage guide
- See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) to contribute
- See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) to understand the system
