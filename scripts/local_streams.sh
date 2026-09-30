#!/usr/bin/env bash
# Serve a video over every protocol SharpStream supports, on 127.0.0.1 only.
#   scripts/local_streams.sh start [clip.mp4]   (default: the generated demo clip)
#   scripts/local_streams.sh stop
#   scripts/local_streams.sh urls
# Needs ffmpeg and MediaMTX (brew install ffmpeg mediamtx). The clip loops forever.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/build/local-streams"
PATHNAME="demo"

urls() {
    cat <<URLS
rtsp://127.0.0.1:8554/$PATHNAME
http://127.0.0.1:8888/$PATHNAME/index.m3u8
udp://127.0.0.1:5004
http://127.0.0.1:8080/clip.mp4
URLS
}

stop() {
    [[ -f "$STATE/pids" ]] && while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$STATE/pids"
    rm -f "$STATE/pids"
}

start() {
    command -v mediamtx >/dev/null || { echo "MediaMTX not found: brew install mediamtx" >&2; exit 1; }
    stop
    mkdir -p "$STATE/http"
    local clip="${1:-$ROOT/build/test-media/demo_ocr.mp4}"
    [[ -f "$clip" ]] || "$ROOT/scripts/make_demo_clip.sh" "$clip" >/dev/null
    clip="$(cd "$(dirname "$clip")" && pwd)/$(basename "$clip")"   # absolute (used by a symlink)
    cat > "$STATE/mediamtx.yml" <<YML
logLevel: warn
rtspAddress: 127.0.0.1:8554
rtpAddress: 127.0.0.1:8000
rtcpAddress: 127.0.0.1:8001
rtmp: no
webrtc: no
moq: no
api: no
metrics: no
pprof: no
playback: no
hls: yes
hlsAddress: 127.0.0.1:8888
hlsVariant: mpegts
# SRT is off: SharpStream's bundled FFmpeg has no libsrt.
srt: no
paths:
  all_others:
YML
    mediamtx "$STATE/mediamtx.yml" < /dev/null > "$STATE/mediamtx.log" 2>&1 & echo $! >> "$STATE/pids"
    sleep 1
    # RTSP publish feeds RTSP and HLS readers via MediaMTX.
    ffmpeg -loglevel error -re -stream_loop -1 -i "$clip" -map 0:v -c copy -f rtsp -rtsp_transport tcp \
        "rtsp://127.0.0.1:8554/$PATHNAME" < /dev/null > "$STATE/publish.log" 2>&1 & echo $! >> "$STATE/pids"
    ffmpeg -loglevel error -re -stream_loop -1 -i "$clip" -map 0:v -c copy -f mpegts \
        "udp://127.0.0.1:5004?pkt_size=1316" < /dev/null > "$STATE/udp.log" 2>&1 & echo $! >> "$STATE/pids"
    ln -sf "$clip" "$STATE/http/clip.mp4"
    python3 "$ROOT/scripts/range_http_server.py" "$STATE/http" 8080 \
        < /dev/null > "$STATE/http.log" 2>&1 & echo $! >> "$STATE/pids"
    sleep 2
    echo "Serving $(basename "$clip") on:"; urls | sed 's/^/  /'
}

case "${1:-}" in
    start) start "${2:-}" ;;
    stop) stop; echo "stopped" ;;
    urls) urls ;;
    *) echo "usage: $0 start [clip.mp4] | stop | urls" >&2; exit 2 ;;
esac
