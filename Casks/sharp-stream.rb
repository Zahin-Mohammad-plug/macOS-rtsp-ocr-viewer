cask "sharp-stream" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/yourusername/macOS-rtsp-ocr-viewer/releases/download/v#{version}/SharpStream-#{version}.dmg"
  name "SharpStream"
  desc "macOS RTSP OCR Viewer - Smart frame selection and text recognition for video streams"
  homepage "https://github.com/yourusername/macOS-rtsp-ocr-viewer"

  app "SharpStream.app"

  zap trash: [
    "~/Library/Application Support/SharpStream",
    "~/Library/Preferences/com.sharpstream.SharpStream.plist",
  ]
end
