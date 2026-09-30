#!/usr/bin/env bash
# Generate the OCR demo clip: a moving test pattern with a text card that is
# sharp for 0.6 s out of every 2 s (Gaussian-ish box blur otherwise). Known
# text + periodic blur make it a deterministic Smart Pause / OCR fixture.
#   scripts/make_demo_clip.sh [output.mp4]   (default: build/test-media/demo_ocr.mp4)
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
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" -i "$WORK/card.png" -t 60 \
    -filter_complex "[0][1]overlay=x=140:y=210,boxblur=enable='lt(mod(t\,2)\,1.4)':luma_radius=6" \
    -c:v libx264 -g 30 -pix_fmt yuv420p -movflags +faststart "$OUT"
echo "$OUT"
