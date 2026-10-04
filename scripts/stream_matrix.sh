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
#
# Other modes (one app run per listed source):
#   MODE=soak SOAK_SECONDS=600 scripts/stream_matrix.sh <url>       long run: memory, threads, drift
#   MODE=switch URLS="a,b,c" scripts/stream_matrix.sh <first>   rapid source switching
#   MODE=ocrsweep TRIALS=12 [EXPECT_TEXT=..] scripts/stream_matrix.sh <url>   Smart Pause vs plain OCR
#
# APP_ARGS passes setting overrides, e.g. APP_ARGS="-smartPauseSamplingRate 12"
# MPV_OPTIONS passes raw mpv options (DEBUG builds), e.g. MPV_OPTIONS="cache-pause=no;audio-buffer=0"
#   MODE=latency SOAK_SECONDS=20 scripts/stream_matrix.sh rtsp://127.0.0.1:8554/clock
#   (needs scripts/latency/publish_clock.sh running)
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
    SHARPSTREAM_SELFTEST_EXPECT_TEXT="${EXPECT_TEXT:-}" SHARPSTREAM_SELFTEST_MODE="${MODE:-standard}" \
    SHARPSTREAM_SELFTEST_SECONDS="${SOAK_SECONDS:-300}" SHARPSTREAM_SELFTEST_URLS="${URLS:-}" \
    SHARPSTREAM_SELFTEST_TRIALS="${TRIALS:-12}" SHARPSTREAM_MPV_OPTIONS="${MPV_OPTIONS:-}" \
        "$APP" -ApplePersistenceIgnoreState YES ${APP_ARGS:-} >/dev/null 2>&1 &
    pid=$!
    limit=$(( ${SOAK_SECONDS:-0} + ${TRIALS:-0} * 15 + 240 ))
    for _ in $(seq 1 "$limit"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill "$pid" 2>/dev/null
    python3 - "$report" "$source" <<'PY' || overall=1
import json, sys, os
path, source = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print(f"\n✗ {source}\n    no report (app crashed or timed out)"); sys.exit(1)
r = json.load(open(path))
mark = "✓" if r["passed"] else "✗"
print(f"\n{mark} [{r.get('mode','standard')}] {r.get('url') or ', '.join(r.get('sources', []))}")
for sample in r.get("samples", []):
    print(f"    t={sample['t']:>4}s  footprint {sample['footprintMB']:6.0f} MB  buffer {sample['bufferMB']:5.0f} MB  "
          f"threads {sample['threads']:3}  load {sample['captureLoad']*100:3.0f}%  sampling {sample['samplingFPS']:.1f} fps  "
          f"rewind {sample['rewindSeconds']:5.0f} s  {sample['state']}")
if "threads" in r and isinstance(r["threads"], dict):
    print(f"    threads {r['threads']['before']} -> {r['threads']['after']}   footprint {r['footprintMB']['before']:.0f} -> {r['footprintMB']['after']:.0f} MB")
if "seekMode" in r: print(f"    {r.get('seekMode','?')}  {r.get('resolution','?')} @ {r.get('frameRate',0):.0f} fps  {r.get('codec','?')}"
      f"  sampling {r.get('samplingFPS',0):.1f} fps  capture load {r.get('captureLoad',0)*100:.0f}%"
      + (f"  rewind {r['rewindWindowSeconds']:.0f} s" if 'rewindWindowSeconds' in r else ""))
for key in ("steady", "afterJumpToLive"):
    if key in r:
        m = r[key]
        print(f"    {key:16} latency {m['latencyMs']:6.0f} ms (min {m['latencyMinMs']:.0f}, max {m['latencyMaxMs']:.0f}, n={m['decoded']})"
              f"  buffered ahead {m['cacheAheadS']:.2f} s  behind live edge {m['lagS']:.2f} s")
if "rows" in r:
    for row in r["rows"]:
        print(f"    plain {'HIT ' if row['baselineHit'] else '    '}{row['baselineChars']:4} chars (score {row['baselineScore']:6.0f})"
              f"   smart {'HIT ' if row['smartHit'] else '    '}{row['smartChars']:4} chars (score {row['smartScore']:6.0f}, {row['smartAge']:.2f} s back)")
for c in r["checks"]:
    print(f"    {'✓' if c['passed'] else '✗'} {c['name']}" + (f" — {c['detail']}" if c['detail'] else ""))
if r.get("ocrLines") is not None:
    print(f"    OCR: {r['ocrLines']} lines  {r.get('ocrSample','')[:90]}")
sys.exit(0 if r["passed"] else 1)
PY
done
exit $overall
