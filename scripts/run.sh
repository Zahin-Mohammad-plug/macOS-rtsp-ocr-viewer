#!/usr/bin/env bash
# Build (Debug) and launch SharpStream, optionally straight into a stream.
#   scripts/run.sh                          # just launch
#   scripts/run.sh rtsp://host:8554/cam     # launch and connect
#   scripts/run.sh --demo                   # local demo streams + connect over RTSP
#   SKIP_BUILD=1 scripts/run.sh ...
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/DerivedData/Build/Products/Debug/SharpStream.app"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild -project "$ROOT/SharpStream.xcodeproj" -scheme SharpStream -configuration Debug \
        -derivedDataPath "$ROOT/DerivedData" -destination 'platform=macOS' build | grep -E "error:|BUILD" || true
fi
[[ -d "$APP" ]] || { echo "Build failed" >&2; exit 1; }

URL="${1:-}"
if [[ "$URL" == "--demo" ]]; then
    "$ROOT/scripts/local_streams.sh" start >/dev/null
    URL="$("$ROOT/scripts/local_streams.sh" urls | head -1)"
    echo "Demo streams running (stop with scripts/local_streams.sh stop); opening $URL"
fi

pkill -f "$APP/Contents/MacOS/SharpStream" 2>/dev/null || true
sleep 0.5
# Launch through LaunchServices so the app is activated like a normal launch
# (running the binary from a background shell leaves it without a window).
if [[ -n "$URL" ]]; then
    open -n "$APP" --env SHARPSTREAM_OPEN_URL="$URL"
else
    open "$APP"
fi
