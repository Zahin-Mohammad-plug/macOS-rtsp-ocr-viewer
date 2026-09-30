#!/usr/bin/env bash
# Build a difficulty ladder of OCR demo clips, CAPTCHA-style: each level shows
# the text in focus for less time, blurs harder, adds noise and compression.
# Feed them to `MODE=ocrsweep` to see where plain OCR gives up and whether
# Smart Pause still finds the readable frame.
#   scripts/make_ocr_ladder.sh            -> build/test-media/ladder/L0.mp4 … L5.mp4
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/build/test-media/ladder"
mkdir -p "$DIR"
#        level SHARP BLUR NOISE CONTRAST TEXT_SCALE CRF
LEVELS=("L0    0.6   6    0     1        1          23"
        "L1    0.3   8    8     0.8      1          26"
        "L2    0.2   10   14    0.6      0.8        28"
        "L3    0.134 12   18    0.5      0.7        30"
        "L4    0.1   12   22    0.45     0.6        32"
        "L5    0.067 14   26    0.4      0.5        34")
for row in "${LEVELS[@]}"; do
    read -r name sharp blur noise contrast scale crf <<<"$row"
    SHARP=$sharp BLUR=$blur NOISE=$noise CONTRAST=$contrast TEXT_SCALE=$scale CRF=$crf \
        "$ROOT/scripts/make_demo_clip.sh" "$DIR/$name.mp4" >/dev/null
    echo "$name: in focus ${sharp}s of every 2 s, blur $blur, noise $noise, contrast $contrast, text x$scale, crf $crf"
done
