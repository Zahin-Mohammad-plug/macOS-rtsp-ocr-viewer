#!/usr/bin/env bash
# Publish the latency clock to rtsp://127.0.0.1:8554/clock (start MediaMTX first
# with scripts/local_streams.sh start). x264 zerolatency: ~1 frame encode delay.
#   scripts/latency/publish_clock.sh           (Ctrl-C to stop)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${TMPDIR:-/tmp}/sharpstream_clock_source"
[[ "$BIN" -nt "$DIR/clock_source.swift" ]] || swiftc -O "$DIR/clock_source.swift" -o "$BIN"
"$BIN" | ffmpeg -loglevel error -f rawvideo -pix_fmt bgra -s 640x360 -r 30 -i - \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/clock
