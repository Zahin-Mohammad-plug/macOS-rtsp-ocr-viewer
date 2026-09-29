# Building SharpStream

## Prerequisites

- macOS 26.2 or later (the project's deployment target)
- Xcode with the macOS 26.2 SDK or newer
- An Apple ID or Developer account for signing. Developer ID is only needed to distribute outside your own machine.

## Dependencies

The only package is **MPVKit** 0.41 (`https://github.com/mpvkit/MPVKit.git`), already referenced in the project; Xcode resolves it on first build. Everything else is a system framework. There is no OpenCV and no Sparkle.

## Build in Xcode

```bash
git clone https://github.com/Zahin-Mohammad-plug/macOS-rtsp-ocr-viewer.git
cd macOS-rtsp-ocr-viewer
open SharpStream.xcodeproj
```

Select the **SharpStream** scheme and **My Mac**, then press ⌘R.

To open a stream immediately on launch, set `SHARPSTREAM_OPEN_URL` under Edit Scheme › Run › Arguments › Environment Variables.

## Build from the command line

```bash
# Debug
xcodebuild build -project SharpStream.xcodeproj -scheme SharpStream \
  -configuration Debug -destination 'platform=macOS'

# Release
xcodebuild build -project SharpStream.xcodeproj -scheme SharpStream \
  -configuration Release -destination 'platform=macOS'
```

## Tests

```bash
# Unit + UI tests (TestPlan.xctestplan)
xcodebuild test -project SharpStream.xcodeproj -scheme SharpStream \
  -destination 'platform=macOS' -testPlan TestPlan

# Unit tests only
xcodebuild test -project SharpStream.xcodeproj -scheme SharpStream \
  -destination 'platform=macOS' -only-testing:SharpStreamTests

# UI tests only
xcodebuild test -project SharpStream.xcodeproj -scheme SharpStream \
  -destination 'platform=macOS' -only-testing:SharpStreamUITests
```

UI tests need macOS UI automation. Approve the prompt when running from Xcode, or enable it once for command-line runs:

```bash
sudo automationmodetool enable-automationmode-without-authentication
```

The stream-dependent UI tests are opt-in. Pass sources with the `TEST_RUNNER_` prefix (for example `TEST_RUNNER_SHARPSTREAM_TEST_RTSP_URL=rtsp://…`), set them in the scheme, or put them in `.env` and use the scripts. Test videos must be readable by the sandboxed app (`~/Downloads` or the app container's tmp directory). Details are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

Scripts:
- `scripts/full_check.sh`: build and run the full test plan
- `scripts/targeted_bug_pass.sh`: build, unit and UI tests with logs and result bundles
- `scripts/smart_pause_test_matrix.sh`: repeated Smart Pause file/RTSP runs

## Signing

1. Select the SharpStream target › Signing & Capabilities.
2. Choose your team and keep "Automatically manage signing" on.

The target has App Sandbox and Hardened Runtime enabled. Entitlements are generated from the target's build settings (`ENABLE_APP_SANDBOX`, `ENABLE_HARDENED_RUNTIME`, incoming/outgoing network connections, user-selected files read/write, Downloads and Movies folders read/write). `SharpStream/Resources/SharpStream.entitlements` is not referenced by the build (`CODE_SIGN_ENTITLEMENTS` is unset) and does not reflect the signed app; check with `codesign -d --entitlements - SharpStream.app`.

Release builds must keep mpv's built-in Lua scripts disabled (see `MPVPlayerWrapper.createHandle()`). LuaJIT's JIT pages violate the hardened runtime, and the signed app is killed at launch otherwise.

## Distribution (manual, nothing published yet)

There are no published releases and no auto-update mechanism.

1. Product › Archive, then Distribute App › Developer ID to export a signed app.
2. Package it:
   ```bash
   scripts/create_dmg.sh 1.0.0 build   # expects build/SharpStream.app
   ```
   With `CODE_SIGN_IDENTITY` set the script signs the DMG; with `NOTARIZE_APPLE_ID`, `NOTARIZE_PASSWORD` and `NOTARIZE_TEAM_ID` set it notarizes and staples it. The README it places in the DMG still says macOS 14 and a placeholder repository URL.
3. `Casks/sharp-stream.rb` is a draft Homebrew cask. Its URLs point to a placeholder (`yourusername`) repository and it uses `sha256 :no_check`; update both before publishing.

Sparkle auto-update is not integrated; see [docs/SPARKLE_SETUP.md](docs/SPARKLE_SETUP.md) for a plan.

## Troubleshooting

- **Package resolution fails**: File › Packages › Reset Package Caches, or delete `DerivedData` and rebuild.
- **Signing errors**: check the selected team and that the bundle ID `com.sharpstream.SharpStream` is available to it.
- **Release build killed at launch ("Code Signature Invalid")**: an mpv Lua script is enabled; see above.
- **UI tests hang or fail to start**: enable UI automation (see Tests).
