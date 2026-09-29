#!/bin/bash
# create_dmg.sh — build SharpStream (Release) and package it as a DMG.
#
# Usage:
#   scripts/create_dmg.sh                 # unsigned local DMG (for testing only)
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID \
#   NOTARY_PROFILE=sharpstream-notary scripts/create_dmg.sh
#
# Environment:
#   DEVELOPER_ID     Developer ID Application identity. When set, the app and
#                    its embedded frameworks are signed with hardened runtime
#                    and a secure timestamp, and the DMG is signed too.
#   TEAM_ID          Apple Developer team ID (required with DEVELOPER_ID).
#   NOTARY_PROFILE   notarytool keychain profile. When set (with DEVELOPER_ID),
#                    the DMG is notarized and stapled. Create it once with:
#                      xcrun notarytool store-credentials sharpstream-notary \
#                        --apple-id you@example.com --team-id TEAMID
#   BUILD_DIR        Output directory (default: build).
#   SKIP_BUILD=1     Package an existing $BUILD_DIR/SharpStream.app.
#
# Without a Developer ID, macOS Gatekeeper blocks the app for anyone who
# downloads it; unsigned DMGs are only useful on the machine that built them.

set -euo pipefail

APP_NAME="SharpStream"
REPO_URL="https://github.com/Zahin-Mohammad-plug/macOS-rtsp-ocr-viewer"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DERIVED="$BUILD_DIR/DerivedData"

if [[ -n "${DEVELOPER_ID:-}" && -z "${TEAM_ID:-}" ]]; then
    echo "❌ TEAM_ID is required when DEVELOPER_ID is set" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

# 1. Build ---------------------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    echo "🔨 Building $APP_NAME (Release)…"
    SIGN_ARGS=()
    if [[ -n "${DEVELOPER_ID:-}" ]]; then
        SIGN_ARGS=(
            CODE_SIGN_STYLE=Manual
            CODE_SIGN_IDENTITY="$DEVELOPER_ID"
            DEVELOPMENT_TEAM="$TEAM_ID"
            ENABLE_HARDENED_RUNTIME=YES
            OTHER_CODE_SIGN_FLAGS="--timestamp"
        )
    fi
    xcodebuild -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
        -configuration Release -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build | grep -E "error:|BUILD" || true
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

# 2. Verify signature ------------------------------------------------------------
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    # Release builds must not rely on JIT (mpv's LuaJIT scripts are disabled).
    if codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "allow-jit\|allow-unsigned-executable-memory"; then
        echo "⚠️  App requests JIT entitlements; review before notarizing"
    fi
else
    echo "⚠️  No DEVELOPER_ID: building an unsigned DMG for local testing only"
fi

# 3. Build the DMG ---------------------------------------------------------------
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

# 4. Sign and notarize the DMG -----------------------------------------------------
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "🔐 Signing DMG…"
    codesign --sign "$DEVELOPER_ID" --timestamp "$DMG_FINAL"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "📋 Notarizing (this can take a few minutes)…"
        xcrun notarytool submit "$DMG_FINAL" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG_FINAL"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG_FINAL"
    else
        echo "ℹ️  NOTARY_PROFILE not set: DMG is signed but not notarized"
    fi
fi

SHA256="$(shasum -a 256 "$DMG_FINAL" | awk '{print $1}')"
echo "✅ $DMG_FINAL ($(du -h "$DMG_FINAL" | cut -f1))"
echo "   sha256 $SHA256"
echo ""
echo "Next (release): upload to $REPO_URL/releases/tag/v$VERSION, then set"
echo "   version \"$VERSION\" and sha256 \"$SHA256\" in Casks/sharp-stream.rb"
