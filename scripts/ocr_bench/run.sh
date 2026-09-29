#!/usr/bin/env bash
# Build the OCR benchmark from the app's own sources and run it.
#   scripts/ocr_bench/run.sh --truth truth.json frames/*.jpg
#   scripts/ocr_bench/run.sh --truth truth.json --pdf page.pdf --height 1080 --blur 0,1,2
# See main.swift for all options.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/sharpstream_ocr_bench"
swiftc -O -o "$OUT" \
  "$ROOT/SharpStream/Core/OCREngine.swift" \
  "$ROOT/SharpStream/Models/OCRResult.swift" \
  "$ROOT/SharpStream/Models/FocusAlgorithm.swift" \
  "$ROOT/SharpStream/Utils/FocusMetrics/SharpnessMetrics.swift" \
  "$ROOT/scripts/ocr_bench/main.swift" 2> >(grep -v "warning:" >&2)
exec "$OUT" "$@"
