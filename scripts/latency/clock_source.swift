// Raw BGRA frames (640x360 @ 30 fps) stamped with the wall clock at the moment
// each frame is drawn: big digits for people, a 40-cell bar code (epoch ms,
// low 40 bits, MSB first) for SelfTest to decode exactly. Writes to stdout.
import AppKit

let width = 640, height = 360, fps = 30.0
let cells = 40, cellWidth = 16, barY = 300, barHeight = 48
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bitmapFormat: [.thirtyTwoBitLittleEndian, .alphaFirst], bytesPerRow: width * 4, bitsPerPixel: 32)!
rep.size = NSSize(width: width, height: height)
let font = NSFont.monospacedDigitSystemFont(ofSize: 110, weight: .bold)
let out = FileHandle.standardOutput
var next = Date().timeIntervalSince1970

while true {
    let ms = Int64((Date().timeIntervalSince1970 * 1000).rounded())
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
    let text = String(format: "%03d.%03d", Int((ms / 1000) % 1000), Int(ms % 1000))
    (text as NSString).draw(at: NSPoint(x: 40, y: 150), withAttributes: [.font: font, .foregroundColor: NSColor.black])
    NSColor.black.setFill()
    for bit in 0..<cells where (ms >> Int64(cells - 1 - bit)) & 1 == 1 {
        // AppKit's origin is bottom-left; the decoder reads rows from the top.
        NSRect(x: bit * cellWidth, y: height - barY - barHeight, width: cellWidth, height: barHeight).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    out.write(Data(bytes: rep.bitmapData!, count: width * height * 4))

    next += 1 / fps
    let wait = next - Date().timeIntervalSince1970
    if wait > 0 { Thread.sleep(forTimeInterval: wait) } else { next = Date().timeIntervalSince1970 }
}
