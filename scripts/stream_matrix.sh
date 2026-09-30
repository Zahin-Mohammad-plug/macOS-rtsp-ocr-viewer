#!/usr/bin/env bash
# End-to-end stream matrix: runs the app's debug self test against each URL
# (connect, playback, seek / live rewind, Smart Pause playing + paused, OCR)
# and prints a pass/fail table. Needs a Debug build:
#   xcodebuild -project SharpStream.xcodeproj -scheme SharpStream -derivedDataPath DerivedData build
#
#   scripts/stream_matrix.sh rtsp://127.0.0.1:8554/cam ~/Downloads/clip.mp4 ...
#
# Local files must be readable by the sandboxed app (~/Downloads, ~/Movies).
# Runs use throwaway storage (SHARPSTREAM_UI_TESTING) and don't touch your
# library, recents or preferences.
#
# Set EXPECT_TEXT to also require that OCR on the Smart Pause frame reads it,
# e.g. with the demo clip from scripts/local_streams.sh:
#   scripts/local_streams.sh start
#   EXPECT_TEXT="ABC-1234" scripts/stream_matrix.sh $(scripts/local_streams.sh urls)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/DerivedData/Build/Products/Debug/SharpStream.app/Contents/MacOS/SharpStream"
REPORT_DIR="$HOME/Library/Containers/com.sharpstream.SharpStream/Data/tmp/selftest"
[[ -x "$APP" ]] || { echo "Debug build not found: $APP" >&2; exit 1; }
[[ $# -gt 0 ]] || { echo "usage: $0 <url-or-file>..." >&2; exit 2; }
mkdir -p "$REPORT_DIR"

overall=0
for source in "$@"; do
    report="$REPORT_DIR/$(date +%s)-$RANDOM.json"
    rm -f "$report"
    SHARPSTREAM_UI_TESTING=1 SHARPSTREAM_OPEN_URL="$source" SHARPSTREAM_SELFTEST_REPORT="$report" \
    SHARPSTREAM_SELFTEST_EXPECT_TEXT="${EXPECT_TEXT:-}" \
        "$APP" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 180); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill "$pid" 2>/dev/null
    python3 - "$report" "$source" <<'PY' || overall=1
import json, sys, os
path, source = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print(f"\n✗ {source}\n    no report (app crashed or timed out)"); sys.exit(1)
r = json.load(open(path))
mark = "✓" if r["passed"] else "✗"
print(f"\n{mark} {r['url']}")
print(f"    {r.get('seekMode','?')}  {r.get('resolution','?')} @ {r.get('frameRate',0):.0f} fps  {r.get('codec','?')}"
      f"  sampling {r.get('samplingFPS',0):.1f} fps  capture load {r.get('captureLoad',0)*100:.0f}%"
      + (f"  rewind {r['rewindWindowSeconds']:.0f} s" if 'rewindWindowSeconds' in r else ""))
for c in r["checks"]:
    print(f"    {'✓' if c['passed'] else '✗'} {c['name']}" + (f" — {c['detail']}" if c['detail'] else ""))
if r.get("ocrLines") is not None:
    print(f"    OCR: {r['ocrLines']} lines  {r.get('ocrSample','')[:90]}")
sys.exit(0 if r["passed"] else 1)
PY
done
exit $overall
