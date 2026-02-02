#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

SMOKE_ENV_FILE="/tmp/sharpstream_smoke.env"
cat > "$SMOKE_ENV_FILE" <<EOF
SHARPSTREAM_TEST_RTSP_URL=${SHARPSTREAM_TEST_RTSP_URL:-}
SHARPSTREAM_TEST_VIDEO_FILE=${SHARPSTREAM_TEST_VIDEO_FILE:-}
SHARPSTREAM_TEST_STREAMS=${SHARPSTREAM_TEST_STREAMS:-}
EOF
export SHARPSTREAM_SMOKE_ENV_FILE="$SMOKE_ENV_FILE"

echo "==> Build"
xcodebuild build \
  -project SharpStream.xcodeproj \
  -scheme SharpStream \
  -configuration Debug \
  -destination 'platform=macOS'

echo "==> Test (Unit + UI smoke)"
xcodebuild test \
  -project SharpStream.xcodeproj \
  -scheme SharpStream \
  -destination 'platform=macOS' \
  -testPlan TestPlan \
  SHARPSTREAM_SMOKE_ENV_FILE="$SHARPSTREAM_SMOKE_ENV_FILE"

echo "==> Done"
