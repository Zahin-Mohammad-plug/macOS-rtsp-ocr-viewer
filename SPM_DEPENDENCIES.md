# Adding SPM Dependencies in Xcode

Since SharpStream is an Xcode app project (not a Swift Package), add dependencies through Xcode:

## Steps:

1. Open `SharpStream.xcodeproj` in Xcode

2. Go to **File > Add Package Dependencies...**

3. Add these packages:

### OpenCV
- URL: `https://github.com/yeatse/opencv-spm`
- Version: Latest (or specific version)
- Product: `opencv2` (import as `opencv2` in your code)

### MPVKit
- URL: `https://github.com/mpv-player/mpv` 
- Version: Latest (or specific version)

4. Select the **SharpStream** target

5. Add the products to your target:
   - `opencv` (from opencv-swift)
   - MPVKit product (name may vary)

## Alternative: If you want to use Package.swift

If you prefer using Package.swift, you need to:

1. Move all source files from `SharpStream/` to `Sources/SharpStream/`
2. Update Package.swift to be an executable target
3. This will break the Xcode project structure

**Recommendation**: Use the Xcode project approach above - it's the standard way for macOS apps.
