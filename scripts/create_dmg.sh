#!/bin/bash
# create_dmg.sh
# Creates a distributable DMG for SharpStream

set -e

APP_NAME="SharpStream"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}"
VERSION="${1:-1.0.0}"
BUILD_DIR="${2:-build}"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_TEMP="${DMG_DIR}/${APP_NAME}-temp.dmg"
DMG_FINAL="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "📦 Creating DMG for ${APP_NAME} v${VERSION}"

# Clean up previous builds
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"

# Check if app exists
if [ ! -d "${BUILD_DIR}/${APP_BUNDLE}" ]; then
    echo "❌ Error: ${APP_BUNDLE} not found in ${BUILD_DIR}"
    echo "   Build the app first: xcodebuild -scheme ${APP_NAME} -configuration Release"
    exit 1
fi

# Create DMG structure
echo "📁 Creating DMG structure..."
cp -R "${BUILD_DIR}/${APP_BUNDLE}" "${DMG_DIR}/"

# Create Applications symlink
ln -s /Applications "${DMG_DIR}/Applications"

# Create README
cat > "${DMG_DIR}/README.txt" << EOF
${APP_NAME} v${VERSION}

Installation:
1. Drag ${APP_NAME}.app to the Applications folder
2. Open Applications and launch ${APP_NAME}

System Requirements:
- macOS 14.0 or later

For more information, visit:
https://github.com/yourusername/macOS-rtsp-ocr-viewer
EOF

# Calculate DMG size (app size + 50MB overhead)
APP_SIZE=$(du -sm "${DMG_DIR}" | cut -f1)
DMG_SIZE=$((APP_SIZE + 50))

echo "💾 Creating DMG image (${DMG_SIZE}MB)..."
hdiutil create -srcfolder "${DMG_DIR}" -volname "${APP_NAME}" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size ${DMG_SIZE}m "${DMG_TEMP}"

# Mount the DMG
echo " mount DMG for customization..."
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "${DMG_TEMP}" | \
    egrep '^/dev/' | sed 1q | awk '{print $1}')

# Wait for mount
sleep 2

# Set DMG properties
echo "🎨 Customizing DMG appearance..."
VOLUME_NAME=$(diskutil info "${DEVICE}" | grep "Volume Name" | awk '{print $3" "$4" "$5}')
DISK_NAME=$(diskutil info "${DEVICE}" | grep "Volume Name" | awk '{print $3" "$4" "$5}')

# Set background (optional - requires background.png)
# osascript <<EOF
# tell application "Finder"
#     tell disk "${VOLUME_NAME}"
#         open
#         set current view of container window to icon view
#         set toolbar visible of container window to false
#         set statusbar visible of container window to false
#         set the bounds of container window to {400, 100, 920, 420}
#         set viewOptions to the icon view options of container window
#         set arrangement of viewOptions to not arranged
#         set icon size of viewOptions to 72
#         set background picture of viewOptions to file ".background:background.png"
#         set position of item "${APP_BUNDLE}" of container window to {160, 205}
#         set position of item "Applications" of container window to {360, 205}
#         close
#         open
#         update without registering applications
#         delay 2
#     end tell
# end tell
# EOF

# Unmount
hdiutil detach "${DEVICE}"

# Convert to compressed read-only DMG
echo "🗜️  Compressing DMG..."
hdiutil convert "${DMG_TEMP}" -format UDZO -imagekey zlib-level=9 -o "${DMG_FINAL}"

# Clean up
rm -f "${DMG_TEMP}"
rm -rf "${DMG_DIR}"

echo "✅ DMG created: ${DMG_FINAL}"
echo "📏 DMG size: $(du -h "${DMG_FINAL}" | cut -f1)"

# Optional: Code sign DMG (requires Developer ID)
if [ -n "${CODE_SIGN_IDENTITY}" ]; then
    echo "🔐 Code signing DMG..."
    codesign --sign "${CODE_SIGN_IDENTITY}" "${DMG_FINAL}"
fi

# Optional: Notarize DMG (requires Apple ID credentials)
if [ -n "${NOTARIZE_APPLE_ID}" ] && [ -n "${NOTARIZE_PASSWORD}" ]; then
    echo "📋 Notarizing DMG..."
    xcrun notarytool submit "${DMG_FINAL}" \
        --apple-id "${NOTARIZE_APPLE_ID}" \
        --password "${NOTARIZE_PASSWORD}" \
        --team-id "${NOTARIZE_TEAM_ID}" \
        --wait
    xcrun stapler staple "${DMG_FINAL}"
    echo "✅ DMG notarized and stapled"
fi
