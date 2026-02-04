#!/usr/bin/env bash
set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_DIR="$ROOT_DIR/DerivedData/smart-pause-tests/$TIMESTAMP"
mkdir -p "$ARTIFACT_DIR"

SMOKE_ENV_FILE="/tmp/sharpstream_smoke.env"
cat > "$SMOKE_ENV_FILE" <<EOF
SHARPSTREAM_TEST_RTSP_URL=${SHARPSTREAM_TEST_RTSP_URL:-}
SHARPSTREAM_TEST_VIDEO_FILE=${SHARPSTREAM_TEST_VIDEO_FILE:-}
SHARPSTREAM_TEST_STREAMS=${SHARPSTREAM_TEST_STREAMS:-}
EOF
export SHARPSTREAM_SMOKE_ENV_FILE="$SMOKE_ENV_FILE"

OVERALL_EXIT=0
SMART_PAUSE_REPEATS="${SMART_PAUSE_REPEATS:-10}"
FILE_PASS=0
FILE_FAIL=0
RTSP_PASS=0
RTSP_FAIL=0

run_step() {
  local name="$1"
  shift
  local log_file="$ARTIFACT_DIR/${name}.log"

  echo ""
  echo "==> $name"
  if "$@" 2>&1 | tee "$log_file"; then
    echo "✅ $name passed"
  else
    echo "❌ $name failed (see $log_file)"
    OVERALL_EXIT=1
  fi
}

run_ui_iteration() {
  local suite_name="$1"
  local test_name="$2"
  local iteration="$3"

  local prefix="${suite_name}-iter-${iteration}"
  local log_file="$ARTIFACT_DIR/${prefix}.log"
  local result_bundle="$ARTIFACT_DIR/${prefix}.xcresult"

  echo ""
  echo "==> ${suite_name} (iteration ${iteration}/${SMART_PAUSE_REPEATS})"

  if xcodebuild test \
    -project SharpStream.xcodeproj \
    -scheme SharpStream \
    -destination 'platform=macOS' \
    -resultBundlePath "$result_bundle" \
    -only-testing:"$test_name" \
    SHARPSTREAM_SMOKE_ENV_FILE="$SHARPSTREAM_SMOKE_ENV_FILE" \
    2>&1 | tee "$log_file"; then
    echo "✅ ${suite_name} iteration ${iteration} passed"
    return 0
  fi

  echo "❌ ${suite_name} iteration ${iteration} failed (see $log_file)"
  OVERALL_EXIT=1

  local attachment_dir="$ARTIFACT_DIR/${prefix}-attachments"
  mkdir -p "$attachment_dir"
  xcrun xcresulttool export attachments \
    --path "$result_bundle" \
    --output-path "$attachment_dir" \
    > "$ARTIFACT_DIR/${prefix}-attachments.log" 2>&1 || true
  return 1
}

echo "==> Smart Pause test matrix"
echo "Artifact directory: $ARTIFACT_DIR"
echo "Repeats per UI scenario: $SMART_PAUSE_REPEATS"
echo "RTSP configured: $([[ -n "${SHARPSTREAM_TEST_RTSP_URL:-}" ]] && echo "yes" || echo "no")"
echo "Video file configured: $([[ -n "${SHARPSTREAM_TEST_VIDEO_FILE:-}" ]] && echo "yes" || echo "no")"

run_step "unit-smart-pause" \
  xcodebuild test \
    -project SharpStream.xcodeproj \
    -scheme SharpStream \
    -destination 'platform=macOS' \
    -resultBundlePath "$ARTIFACT_DIR/unit-smart-pause.xcresult" \
    -only-testing:SharpStreamTests/FocusScorerTests \
    -only-testing:SharpStreamTests/SmartPauseCoordinatorTests \
    -only-testing:SharpStreamTests/SmartPauseQoSTests \
    SHARPSTREAM_SMOKE_ENV_FILE="$SHARPSTREAM_SMOKE_ENV_FILE"

for i in $(seq 1 "$SMART_PAUSE_REPEATS"); do
  if run_ui_iteration \
    "ui-smart-pause-file" \
    "SharpStreamUITests/SharpStreamUITests/testOptionalConnectFileViaPasteStreamURLAndTimeProgress" \
    "$i"; then
    FILE_PASS=$((FILE_PASS + 1))
  else
    FILE_FAIL=$((FILE_FAIL + 1))
  fi
done

for i in $(seq 1 "$SMART_PAUSE_REPEATS"); do
  if run_ui_iteration \
    "ui-smart-pause-rtsp" \
    "SharpStreamUITests/SharpStreamUITests/testOptionalConnectRTSPViaPasteStreamURL" \
    "$i"; then
    RTSP_PASS=$((RTSP_PASS + 1))
  else
    RTSP_FAIL=$((RTSP_FAIL + 1))
  fi
done

echo ""
echo "==> Smart Pause matrix summary"
echo "File scenario: $FILE_PASS passed / $FILE_FAIL failed (target: $SMART_PAUSE_REPEATS)"
echo "RTSP scenario: $RTSP_PASS passed / $RTSP_FAIL failed (target: $SMART_PAUSE_REPEATS)"

cat > "$ARTIFACT_DIR/README.txt" <<EOF
Smart Pause Matrix Artifacts
===========================

Logs:
  - unit-smart-pause.log
  - ui-smart-pause-file-iter-<n>.log
  - ui-smart-pause-rtsp-iter-<n>.log

Result bundles:
  - unit-smart-pause.xcresult
  - ui-smart-pause-file-iter-<n>.xcresult
  - ui-smart-pause-rtsp-iter-<n>.xcresult

Failed iteration attachments:
  - ui-smart-pause-file-iter-<n>-attachments/
  - ui-smart-pause-rtsp-iter-<n>-attachments/

Environment file used:
  - $SMOKE_ENV_FILE

Repeat count:
  - SMART_PAUSE_REPEATS=$SMART_PAUSE_REPEATS

Summary:
  - File: $FILE_PASS passed / $FILE_FAIL failed
  - RTSP: $RTSP_PASS passed / $RTSP_FAIL failed
EOF

echo ""
echo "==> Completed Smart Pause matrix"
echo "Artifacts: $ARTIFACT_DIR"
exit "$OVERALL_EXIT"
