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

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_DIR="$ROOT_DIR/DerivedData/bug-pass/$TIMESTAMP"
mkdir -p "$ARTIFACT_DIR"

SMOKE_ENV_FILE="/tmp/sharpstream_smoke.env"
cat > "$SMOKE_ENV_FILE" <<EOF
SHARPSTREAM_TEST_RTSP_URL=${SHARPSTREAM_TEST_RTSP_URL:-}
SHARPSTREAM_TEST_VIDEO_FILE=${SHARPSTREAM_TEST_VIDEO_FILE:-}
SHARPSTREAM_TEST_STREAMS=${SHARPSTREAM_TEST_STREAMS:-}
EOF
export SHARPSTREAM_SMOKE_ENV_FILE="$SMOKE_ENV_FILE"

echo "==> Artifact directory: $ARTIFACT_DIR"
echo "==> Build"
xcodebuild build \
  -project SharpStream.xcodeproj \
  -scheme SharpStream \
  -configuration Debug \
  -destination 'platform=macOS' \
  | tee "$ARTIFACT_DIR/build.log"

echo "==> Unit/Integration Tests"
xcodebuild test \
  -project SharpStream.xcodeproj \
  -scheme SharpStream \
  -destination 'platform=macOS' \
  -only-testing:SharpStreamTests \
  -resultBundlePath "$ARTIFACT_DIR/unit-tests.xcresult" \
  SHARPSTREAM_SMOKE_ENV_FILE="$SHARPSTREAM_SMOKE_ENV_FILE" \
  | tee "$ARTIFACT_DIR/unit-tests.log"

echo "==> Focused UI Smoke Tests"
xcodebuild test \
  -project SharpStream.xcodeproj \
  -scheme SharpStream \
  -destination 'platform=macOS' \
  -only-testing:SharpStreamUITests \
  -resultBundlePath "$ARTIFACT_DIR/ui-smoke.xcresult" \
  SHARPSTREAM_SMOKE_ENV_FILE="$SHARPSTREAM_SMOKE_ENV_FILE" \
  | tee "$ARTIFACT_DIR/ui-smoke.log"

echo "==> Done"
echo "Artifacts:"
echo "  Build log:      $ARTIFACT_DIR/build.log"
echo "  Unit log:       $ARTIFACT_DIR/unit-tests.log"
echo "  UI smoke log:   $ARTIFACT_DIR/ui-smoke.log"
echo "  Unit xcresult:  $ARTIFACT_DIR/unit-tests.xcresult"
echo "  UI xcresult:    $ARTIFACT_DIR/ui-smoke.xcresult"
