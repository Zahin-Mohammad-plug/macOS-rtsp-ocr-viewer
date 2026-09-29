#!/bin/bash
# create_dmg.sh — build SharpStream (Release) and package it as a local DMG.
#
# Usage:
#   scripts/create_dmg.sh              # build + package
#   SKIP_BUILD=1 scripts/create_dmg.sh # package an existing build/SharpStream.app
#   BUILD_DIR=out scripts/create_dmg.sh
#
# The DMG is unsigned (ad-hoc signed app): it opens on the machine that built
# it, but Gatekeeper blocks it on other Macs. Distributing to other people
# needs a Developer ID signature and notarization; see BUILD.md.

set -euo pipefail

APP_NAME="SharpStream"
REPO_URL="https://github.com/Zahin-Mohammad-plug/macOS-rtsp-ocr-viewer"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DERIVED="$BUILD_DIR/DerivedData"

mkdir -p "$BUILD_DIR"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    echo "🔨 Building $APP_NAME (Release)…"
    xcodebuild -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
        -configuration Release -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD" || true
    BUILT="$DERIVED/Build/Products/Release/$APP_NAME.app"
    [[ -d "$BUILT" ]] || { echo "❌ Build failed: $BUILT not found" >&2; exit 1; }
    rm -rf "$APP_PATH"
    ditto "$BUILT" "$APP_PATH"
fi

[[ -d "$APP_PATH" ]] || { echo "❌ $APP_PATH not found" >&2; exit 1; }

INFO="$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO" 2>/dev/null || echo "unknown")"
DMG_FINAL="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "📦 Packaging $APP_NAME $VERSION (requires macOS $MIN_MACOS)"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/README.txt" <<EOF
$APP_NAME $VERSION

Install: drag $APP_NAME.app onto the Applications folder, then open it from Applications.

Requires macOS $MIN_MACOS or later.

$REPO_URL
EOF

rm -f "$DMG_FINAL"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG_FINAL" >/dev/null

echo "✅ $DMG_FINAL ($(du -h "$DMG_FINAL" | cut -f1))"
