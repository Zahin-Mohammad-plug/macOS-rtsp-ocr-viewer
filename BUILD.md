# Building SharpStream

## Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- Swift 5.9 or later
- Apple Developer account (for code signing and distribution)

## Setup

1. Clone the repository:
```bash
git clone https://github.com/yourusername/macOS-rtsp-ocr-viewer.git
cd macOS-rtsp-ocr-viewer
```

2. Open the project in Xcode:
```bash
open SharpStream.xcodeproj
```

3. Add SPM Dependencies:
   - In Xcode, go to File > Add Package Dependencies
   - Add MPVKit (when available via SPM)
   - Add OpenCV-SPM: `https://github.com/yeatse/opencv-spm`

## Building

### Debug Build
1. Select the "SharpStream" scheme
2. Choose "My Mac" as the destination
3. Press ⌘R to build and run

### Release Build
1. Select "Any Mac" as the destination
2. Product > Archive
3. Once archived, click "Distribute App"
4. Choose distribution method (DMG, App Store, etc.)

## Code Signing

1. In Xcode, select the project
2. Go to "Signing & Capabilities"
3. Select your development team
4. Enable "Automatically manage signing"

For distribution:
- Use a Distribution certificate
- Enable Hardened Runtime
- Add necessary entitlements (network access, etc.)

## Notarization

For distribution outside the App Store:
1. Archive the app
2. Export as Developer ID-signed app
3. Notarize using `xcrun notarytool` or Xcode Organizer
4. Create DMG with notarized app

## Creating DMG

1. Create a DMG using Disk Utility or `create-dmg`:
```bash
create-dmg --volname "SharpStream" \
  --window-pos 200 120 \
  --window-size 800 400 \
  --icon-size 100 \
  --icon "SharpStream.app" 200 190 \
  --hide-extension "SharpStream.app" \
  --app-drop-link 600 185 \
  SharpStream.dmg \
  build/Release/SharpStream.app
```

2. Sign and notarize the DMG

## Homebrew Cask

To create a Homebrew cask:

1. Create `Casks/sharp-stream.rb`:
```ruby
cask "sharp-stream" do
  version "1.0.0"
  sha256 "..."

  url "https://github.com/yourusername/macOS-rtsp-ocr-viewer/releases/download/v#{version}/SharpStream.dmg"
  name "SharpStream"
  desc "macOS RTSP OCR Viewer"
  homepage "https://github.com/yourusername/macOS-rtsp-ocr-viewer"

  app "SharpStream.app"
end
```

2. Submit to homebrew-cask repository

## Testing

Run unit tests:
```bash
xcodebuild test -scheme SharpStream -destination 'platform=macOS'
```

Run UI tests:
```bash
xcodebuild test -scheme SharpStreamUITests -destination 'platform=macOS'
```

## Troubleshooting

### SPM Dependencies Not Found
- Ensure package dependencies are added in Xcode
- Check Package.swift for correct URLs
- Try: File > Packages > Reset Package Caches

### Code Signing Issues
- Verify your Apple Developer account is active
- Check certificate validity in Keychain Access
- Ensure provisioning profile matches bundle ID

### Build Errors
- Clean build folder: ⌘⇧K
- Delete DerivedData
- Reset package caches
