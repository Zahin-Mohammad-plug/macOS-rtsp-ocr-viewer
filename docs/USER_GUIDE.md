# SharpStream User Guide

## The window

- **Sidebar** (left): **Recent** (the last 5 URLs you played, with use counts) and **Saved Streams**. URLs are shown with user names, passwords and query strings removed. Show or hide it with the standard sidebar command in the View menu.
- **Video** (center): the picture, connection status cards, the frozen analyzed frame with text boxes, and short status messages at the bottom.
- **Control bar** (below the video): a timeline row and a control row. The control row adapts to the window width. At full width buttons show icons and labels; narrower, they become icon-only with volume in a popover; at the narrowest, frame stepping and speed move into the **More** (…) menu.
- **Recognized Text panel** (right inspector): lines from the last recognition. Toggle with ⌥⌘T or the toolbar button.
- **Toolbar**: Open URL from Clipboard, Open File, Statistics, Text Panel.

## Opening something to play

- **Drag and drop** a video file (or a URL) onto the video area.
- **File › Open File…** (⌘O) opens a panel for video files.
- **File › Open URL from Clipboard** (⇧⌘V) connects to the URL or file path on the clipboard. Paths starting with `/` or `~` are treated as files.
- **File › New Stream…** (⌘N), or **+** in the sidebar, opens the stream sheet: enter a name and URL, optionally **Test Connection**, then **Save**. The stream appears under Saved Streams.
- Click a sidebar entry, or use **File › Open Recent** / **File › Saved Streams**.

Saved streams can be edited or deleted from their context menu. A recent entry can be saved to the library with **Save to Saved Streams…**. **File › Save Stream to Library…** saves the stream that is currently playing, and **File › Open Recent › Clear Menu** clears the recent list.

### Supported sources

| Scheme | Notes |
|---|---|
| `rtsp://`, `rtsps://` | Live, rewindable. TCP transport by default (Settings › Streams). |
| `srt://` | Not supported; the bundled video library has no SRT. Restream it as RTSP or HLS (e.g. MediaMTX). |
| `udp://` | Live, rewindable. |
| `http(s)://…m3u8` (HLS) | Seekable like a file if it has a duration, otherwise live. |
| `http(s)://` | Same as HLS. |
| `file://` or a path | Any format mpv/FFmpeg can play. The Open panel offers movie, MPEG-4, QuickTime, AVI and MPEG-2 TS types. |

The app is sandboxed. It can open files you pick in the Open panel or drop onto the window, and files in your Downloads and Movies folders. Files you picked or dropped are remembered, so they reopen from Recent or Saved Streams after a relaunch. A path typed or pasted for a file you never picked or dropped only works inside Downloads.

### Connection behaviour

- A stream that has not loaded within 15 seconds counts as failed.
- Network streams that fail or drop reconnect automatically: up to 10 attempts, waiting 1 s, 2 s, 4 s … up to 30 s between them. After that, or for files, an error card offers **Retry** and **Close**.
- **File › Disconnect** (⇧⌘D) stops playback.

## Playback

| Action | How |
|---|---|
| Play / pause | Space, or the play button |
| Seek ±5 s | ← / → |
| Seek ±10 s | ⌘← / ⌘→, ⌥⌘← / ⌥⌘→, or the ±10 buttons |
| Previous / next frame | `,` / `.`, the frame buttons, or ← / → while a file is paused |
| Scrub | Drag the timeline. Files show keyframes while you drag and seek exactly when you release. |
| Speed | Speed menu in the control bar or **Playback › Speed**: 0.25×, 0.5×, 1×, 1.5×, 2× |
| Volume | Volume slider or popover |

Plain keys (Space, arrows, `,`, `.`, Esc) only act on the player window and are ignored while you type in a text field or a sheet is open.

Files stay on their last frame when they finish, so you can still seek back or analyze the frame.

### Live streams and rewind

For live sources the timeline covers what the player currently holds in its cache. The left label shows the wall-clock time at the playhead (12- or 24-hour, see Settings). On the right, **"4:32 buffered"** tells you how far back you can go right now, followed by **LIVE** at the live edge or how far behind live you are (for example `−00:42`). Hover over the timeline for details, including how much memory the buffer is using.

- Pause, seek or drag the timeline to rewind within the window.
- **Live** button or **Playback › Jump to Live** (⌘L) returns to the live edge and resumes.
- The maximum rewind window is set in Settings › Streams › Rewind window (10, 20, 30 or 40 minutes). The window grows as the stream plays.
- The buffer is kept in **memory, not on disk**, so disk space doesn't matter. Its size is estimated from the stream's bitrate and capped at 1/8 of your Mac's RAM (at most 2 GB); a high-bitrate stream may therefore hold less than the chosen window. The "buffered" label always shows what is actually available.
- After a reconnect the old cache is gone, so the rewind window starts over.
- Rewind and Jump to Live can only land where the stream has a keyframe in the buffer. Cameras normally send one every 1–2 s, which gives precise seeks; sources with keyframes far apart (some phone recordings re-streamed, up to 10 s) need a longer buffer before you can rewind, and seeks snap to the nearest available keyframe.

## Smart Pause

Smart Pause returns to the sharpest frame from the last few seconds. It helps with motion blur, focus hunting and compression smear.

1. Let the video play for a couple of seconds. Frames are only sampled while playing.
   Already paused? Smart Pause then looks back from the moment you paused, so it still finds the sharpest frame from just before the pause.
2. Press ⌘S, click **Smart Pause**, or right-click the video › Smart Pause.
3. Playback pauses on the sharpest frame from the lookback window (Settings › Smart Pause, 1–5 s, default 3 s). That frame is frozen on screen and the status line reads "Sharpest frame: 1.2s ago (score …)". On files, an orange marker on the timeline shows where it is.
4. If **Recognize text after Smart Pause** is on (the default), text recognition runs on that exact frame.

Press Space to resume, or Esc / the × button to dismiss the frozen frame.

Frames are sampled 4 times a second by default. If the picture is only sharp for a split second at a time (a camera hunting for focus, a shaky hand, a passing vehicle), raise **Settings › Smart Pause › Sampling rate** to High (8/s): at 4/s a sharp moment shorter than a quarter second can fall between samples. Higher rates cost more CPU. If capturing and scoring takes too long, or macOS reports memory pressure, sampling drops to half the chosen rate, then 1 per second, and recovers when things settle. The Statistics window shows the current rate.

The **Sharpness metric** setting chooses Laplacian (default), Tenengrad or Sobel. They mostly differ on noisy or low-contrast footage.

Possible messages:
- "No frames captured yet — play for a couple of seconds and try again."
- "Best frame is stale; try again while playback is active."
- "Smart Pause picked a frame, but this source can't seek."

## Text recognition (OCR)

- **Recognize Text** (⌘R, the button, or the video context menu) pauses and recognizes text in the frame on screen. If a Smart Pause frame is frozen, it uses that frame.
- Each recognized line is outlined in green on the frozen frame. Hover to see its text; click to copy that line. The header shows how many regions were found.
- The **Recognized Text** panel lists every line with its confidence. Right-click a line › Copy Line, or use **Copy All** and the **Export** menu (Export Text…, Export Frame with Boxes…).

Settings › Text:
- **Enable text recognition** (on by default).
- **Accuracy**: Fast or Accurate (default).
- **Languages**: comma-separated codes such as `en-US, de-DE`. Leave empty for automatic detection. If the listed languages find nothing, recognition retries once with automatic detection.
- **Language correction** (off by default): helps with sentences, but tends to change codes, licence plates and IDs.
- **Outline recognized text** and **Show recognized text on hover** control the overlay.

## Copying and exporting

Available from the Edit and File menus, the **More** (…) menu in the control bar, and the video context menu:

| Item | Shortcut | Result |
|---|---|---|
| Copy Recognized Text | ⇧⌘C | Copies all recognized text; runs recognition first if needed |
| Copy Frame | ⌥⌘C | Copies the frozen frame, or the current frame, as an image |
| Save Frame As… | ⌘E | PNG or JPEG, chosen by the file extension |
| Quick Save Frame | ⇧⌘E | Saves `frame-<timestamp>` in the last folder you exported to (Pictures by default), in the Quick save format |
| Export Recognized Text… | | `.txt` file |
| Export Frame with Text Boxes… | | Image with the boxes and text drawn on it; runs recognition first if needed |

Settings › Export sets the Quick save format (PNG or JPEG) and the JPEG quality.

## Statistics

**View › Show Statistics** (⌥⌘I) opens a separate window with:
- Status, stream health and reason
- Transport: current bitrate, receive rate, buffer level, jitter and packet loss (estimated from player metrics, labelled "Proxy")
- Video: resolution, frame rate, codec, keyframe interval
- Buffer & performance: rewind window, memory held by Smart Pause frames, focus score, CPU usage, focus scoring FPS, Smart Pause sampling tier, memory pressure

## Resuming after a crash

If SharpStream quits unexpectedly while a stream is playing, the next launch asks "Resume Previous Stream?". A normal quit or disconnect does not trigger the prompt. The marker is ignored after 6 hours.

## Settings reference

| Tab | Setting | Default |
|---|---|---|
| General | Use 24-hour time on the live timeline | Off |
| General | Remember recently opened streams | On |
| General | Clear Recent Streams | (button) |
| Streams | RTSP transport | TCP |
| Streams | Hardware video decoding | On |
| Streams | Reconnect automatically when a stream drops | On |
| Streams | Rewind window | 30 minutes |
| Smart Pause | Look back | 3.0 s |
| Smart Pause | Sampling rate | Standard (4 per second) |
| Smart Pause | Sharpness metric | Laplacian |
| Smart Pause | Recognize text in the selected frame | On |
| Text | Enable text recognition | On |
| Text | Language | English (en-US); "Automatic" detects it |
| Text | Accuracy | Accurate |
| Text | Language correction | Off |
| Text | Outline recognized text on the frame | On |
| Text | Show the text when hovering an outline | On |
| Text | Open the Text panel when text is found | On |
| Export | Quick Save folder | Downloads |
| Export | Format | PNG |
| Export | JPEG quality | 80% |

RTSP transport and hardware decoding apply the next time a stream connects; everything else applies immediately. Playback volume is remembered between streams and launches. Try **UDP** transport for lower latency on a local network, or turn **hardware decoding** off if a stream shows corrupted or green frames.

The **Shortcuts** tab lists the keyboard shortcuts.

## Troubleshooting

- **A file won't open**: the sandboxed app can only read files you selected or dropped (remembered across launches), or files in Downloads/Movies. Open it once with File › Open File… or by dropping it; after that, Recent and Saved entries for it work.
- **Stream won't connect**: check the URL with **Test Connection** in the stream sheet. RTSP uses TCP; make sure the camera allows that.
- **Smart Pause says no frames**: play for a few seconds first; nothing is sampled while paused.
- **No text found**: try Accuracy › Accurate, clear the Languages field to use automatic detection, or Smart Pause first to get a sharper frame.
- **Boxes or labels in the way**: turn off the overlay options in Settings › Text, or hide the Text panel (⌥⌘T).
