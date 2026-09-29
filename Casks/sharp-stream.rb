# Homebrew cask for SharpStream.
#
# Not yet installable: no release has been published. To ship one:
#   1. scripts/create_dmg.sh with DEVELOPER_ID / TEAM_ID / NOTARY_PROFILE set
#      (Homebrew users hit Gatekeeper without a notarized build).
#   2. Upload build/SharpStream-<version>.dmg to a GitHub release tagged v<version>.
#   3. Set `version` and `sha256` below from the script's output.
#   4. Publish this file in a tap repo (e.g. Zahin-Mohammad-plug/homebrew-tap)
#      so users can `brew install --cask zahin-mohammad-plug/tap/sharp-stream`.
cask "sharp-stream" do
  version "1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # set per release

  url "https://github.com/Zahin-Mohammad-plug/macOS-rtsp-ocr-viewer/releases/download/v#{version}/SharpStream-#{version}.dmg"
  name "SharpStream"
  desc "RTSP/SRT/HLS stream viewer with sharpest-frame pause and text recognition"
  homepage "https://github.com/Zahin-Mohammad-plug/macOS-rtsp-ocr-viewer"

  depends_on macos: ">= :tahoe"

  app "SharpStream.app"

  # Sandboxed app: all data lives in its container.
  zap trash: [
    "~/Library/Containers/com.sharpstream.SharpStream",
    "~/Library/Saved Application State/com.sharpstream.SharpStream.savedState",
  ]
end
