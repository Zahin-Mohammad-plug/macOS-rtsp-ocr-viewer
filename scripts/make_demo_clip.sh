#!/usr/bin/env bash
# Generate the OCR demo clip: a moving test pattern with a text card that is
# sharp for 0.6 s out of every 2 s (Gaussian-ish box blur otherwise). Known
# text + periodic blur make it a deterministic Smart Pause / OCR fixture.
#   scripts/make_demo_clip.sh [output.mp4]   (default: build/test-media/demo_ocr.mp4)
#
# Difficulty knobs (environment; defaults give the standard demo clip):
#   SHARP=0.6      seconds of every 2 s the card is in focus
#   BLUR=6         defocus radius the rest of the time
#   NOISE=0        sensor noise strength (0-100, temporal)
#   CONTRAST=1     card contrast (0.3 = grey on grey)
#   TEXT_SCALE=1   card size (0.5 = half-size text)
#   CRF=23         x264 quality (higher = more compression smear)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/test-media/demo_ocr.mp4}"
mkdir -p "$(dirname "$OUT")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/card.swift" <<'SWIFT'
import AppKit
let w = 1000, h = 300
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)   // 1x pixels regardless of display scale
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
("PLATE ABC-1234" as NSString).draw(at: NSPoint(x: 40, y: 150),
    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 96), .foregroundColor: NSColor.black])
("Invoice 55821 / Gate 7" as NSString).draw(at: NSPoint(x: 40, y: 40),
    withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.darkGray])
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swift "$WORK/card.swift" "$WORK/card.png"
SHARP="${SHARP:-0.6}"; BLUR="${BLUR:-6}"; NOISE="${NOISE:-0}"; CONTRAST="${CONTRAST:-1}"
TEXT_SCALE="${TEXT_SCALE:-1}"; CRF="${CRF:-23}"
BLURRED=$(echo "2 - $SHARP" | bc -l)
FILTER="[1]scale=iw*${TEXT_SCALE}:-1,eq=contrast=${CONTRAST}[card];[0][card]overlay=x=140:y=210"
FILTER+=",boxblur=enable='lt(mod(t\,2)\,${BLURRED})':luma_radius=${BLUR}"
[ "$NOISE" != "0" ] && FILTER+=",noise=alls=${NOISE}:allf=t"
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" -i "$WORK/card.png" -t 60 \
    -filter_complex "$FILTER" \
    -c:v libx264 -crf "$CRF" -g 30 -pix_fmt yuv420p -movflags +faststart "$OUT"
echo "$OUT"
