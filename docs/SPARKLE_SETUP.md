# Sparkle Auto-Update Setup

This document describes how to set up Sparkle framework for automatic updates in SharpStream.

## Prerequisites

1. Add Sparkle framework to the project via SPM or manually
2. Code signing certificate (Developer ID)
3. Appcast server or GitHub Releases

## Installation

### Via Swift Package Manager

Add to `Package.swift` or Xcode:
```
https://github.com/sparkle-project/Sparkle
```

### Manual Installation

1. Download Sparkle from https://sparkle-project.org
2. Add Sparkle.framework to project
3. Link framework in Build Phases

## Configuration

### 1. Add to App Delegate

```swift
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    var updaterController: SPUStandardUpdaterController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
```

### 2. Create Appcast

Create `appcast.xml` on your server:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>SharpStream</title>
        <item>
            <title>Version 1.0.1</title>
            <sparkle:releaseNotesLink>https://yourdomain.com/release-notes.html</sparkle:releaseNotesLink>
            <pubDate>Mon, 01 Jan 2024 12:00:00 +0000</pubDate>
            <enclosure url="https://yourdomain.com/releases/SharpStream-1.0.1.dmg"
                       sparkle:version="1.0.1"
                       sparkle:shortVersionString="1.0.1"
                       length="12345678"
                       type="application/octet-stream"
                       sparkle:dsaSignature="..." />
        </item>
    </channel>
</rss>
```

### 3. Configure Info.plist

Add to `Info.plist`:

```xml
<key>SUFeedURL</key>
<string>https://yourdomain.com/appcast.xml</string>
<key>SUPublicEDSAKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
```

### 4. Code Signing

- Sign app with Developer ID certificate
- Sign Sparkle framework
- Sign DMG (for distribution)

### 5. Generate DSA Key Pair

```bash
./bin/generate_keys
```

This creates:
- `dsa_priv.pem` (keep secret!)
- `dsa_pub.pem` (add to Info.plist)

### 6. Sign Updates

When creating DMG for release:

```bash
./bin/sign_update SharpStream-1.0.1.dmg dsa_priv.pem
```

## Testing

1. Build app with test feed URL
2. Create test appcast with higher version
3. Launch app and check for updates
4. Verify update process works

## GitHub Releases Integration

If using GitHub Releases:

1. Create release with DMG attached
2. Use GitHub Releases API to generate appcast
3. Point `SUFeedURL` to your appcast endpoint

Example appcast URL format:
```
https://api.github.com/repos/yourusername/macOS-rtsp-ocr-viewer/releases
```

## Security Notes

- Always use HTTPS for appcast
- Verify DSA signatures
- Keep private key secure
- Test updates thoroughly before release

## Resources

- Sparkle Documentation: https://sparkle-project.org/documentation/
- Sparkle GitHub: https://github.com/sparkle-project/Sparkle
