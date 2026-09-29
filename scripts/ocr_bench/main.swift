//
//  main.swift — OCR / sharpness benchmark harness
//
//  Scores camera frames (or synthetic renders of a PDF test page) with the
//  app's own OCREngine and SharpnessMetrics against a ground-truth file.
//  Build and run with scripts/ocr_bench/run.sh.
//
//  Truth file: JSON array of {"pt": <font size>, "text": "<five words> <number>"}.
//  A truth line counts as read when its number and >= 4 of its 5 words appear
//  on a single recognized line (same rule as the original ocr_score.py).
//
//  Usage:
//    ocr_bench --truth truth.json [options] frame1.jpg frame2.jpg ...
//    ocr_bench --truth truth.json --pdf page.pdf --height 1080 --blur 0,1,2,3
//  Options:
//    --min-height <f>     Vision minimumTextHeight (default: app default)
//    --level fast|accurate
//    --correction         enable language correction
//    --languages en-US    comma-separated, empty = automatic
//    --rotate <deg>       rotate synthetic renders (default 0)
//    --upscale <f>        extra pre-scale before the engine (the engine itself
//                         already upscales frames < 1600 px tall by 1.5x)
//    --csv                one CSV row per image instead of a summary
//

import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import Vision

struct TruthLine: Decodable {
    let pt: Int
    let text: String
}

struct Options {
    var truthPath = ""
    var images: [String] = []
    var pdfPath: String?
    var height = 1080
    var blurs: [Double] = [0]
    var rotate: Double = 0
    var minHeight: Float = OCREngine.defaultMinimumTextHeight
    var level: VNRequestTextRecognitionLevel = .accurate
    var correction = false
    var languages = ["en-US"]
    var csv = false
    var upscale: Double = 1
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--truth": options.truthPath = args.removeFirst()
        case "--pdf": options.pdfPath = args.removeFirst()
        case "--height": options.height = Int(args.removeFirst()) ?? 1080
        case "--blur": options.blurs = args.removeFirst().split(separator: ",").compactMap { Double($0) }
        case "--rotate": options.rotate = Double(args.removeFirst()) ?? 0
        case "--min-height": options.minHeight = Float(args.removeFirst()) ?? options.minHeight
        case "--level": options.level = args.removeFirst() == "fast" ? .fast : .accurate
        case "--correction": options.correction = true
        case "--languages":
            options.languages = args.removeFirst().split(separator: ",").map(String.init)
        case "--csv": options.csv = true
        case "--upscale": options.upscale = Double(args.removeFirst()) ?? 1
        default: options.images.append(arg)
        }
    }
    return options
}

// MARK: - Images

func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                        attributes as CFDictionary, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Renders page 1 of a PDF onto a white 16:9 frame of the given height, the
/// page filling ~90% of the frame height (roughly a page held to a camera).
func renderPDF(_ path: String, frameHeight: Int, blur: Double, rotate: Double) -> CGImage? {
    guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL),
          let page = document.page(at: 1) else { return nil }
    let frameWidth = frameHeight * 16 / 9
    guard let context = CGContext(
        data: nil, width: frameWidth, height: frameHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(gray: 0.35, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))

    let box = page.getBoxRect(.mediaBox)
    let scale = CGFloat(frameHeight) * 0.9 / box.height
    context.translateBy(x: CGFloat(frameWidth) / 2, y: CGFloat(frameHeight) / 2)
    context.rotate(by: CGFloat(rotate * .pi / 180))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.width / 2, y: -box.height / 2)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(box)
    context.drawPDFPage(page)
    guard let sharp = context.makeImage() else { return nil }
    guard blur > 0 else { return sharp }

    let input = CIImage(cgImage: sharp)
    let output = input.clampedToExtent()
        .applyingGaussianBlur(sigma: blur)
        .cropped(to: input.extent)
    return CIContext().createCGImage(output, from: input.extent)
}

// MARK: - Scoring

struct Score {
    var linesRead: Int
    var readByPoint: [Int: Int]
    var tokenRecall: Double
    var recognizedLines: Int
}

func tokens(_ string: String) -> [String] {
    let cleaned = String(string.lowercased().map { (c: Character) -> Character in
        c.isLetter || c.isNumber ? c : " "
    })
    return cleaned.split(separator: " ").map(String.init)
}

func score(_ result: OCRResult?, truth: [TruthLine]) -> Score {
    let ocrLines = (result?.lines ?? []).map { tokens($0.text) }
    let allTokens = Set(ocrLines.flatMap { $0 })
    var read = 0
    var byPoint: [Int: Int] = [:]
    var tokenHits = 0
    var tokenTotal = 0
    for line in truth {
        let expected = tokens(line.text)
        let words = Array(expected.dropLast())
        let number = expected.last ?? ""
        let ok = ocrLines.contains { candidate in
            candidate.contains(number) && words.filter { candidate.contains($0) }.count >= 4
        }
        if ok {
            read += 1
            byPoint[line.pt, default: 0] += 1
        }
        tokenHits += expected.filter { allTokens.contains($0) }.count
        tokenTotal += expected.count
    }
    return Score(
        linesRead: read,
        readByPoint: byPoint,
        tokenRecall: tokenTotal > 0 ? Double(tokenHits) / Double(tokenTotal) : 0,
        recognizedLines: ocrLines.count
    )
}

/// Smallest point size such that it and every larger size read fully.
func smallestReliablePoint(_ byPoint: [Int: Int], truth: [TruthLine]) -> Int? {
    let perPoint = Dictionary(grouping: truth, by: \.pt).mapValues(\.count)
    var smallest: Int?
    for point in perPoint.keys.sorted(by: >) {
        if byPoint[point, default: 0] == perPoint[point] { smallest = point } else { break }
    }
    return smallest
}

// MARK: - Main

let options = parseOptions()
guard let truthData = FileManager.default.contents(atPath: options.truthPath),
      let truth = try? JSONDecoder().decode([TruthLine].self, from: truthData) else {
    FileHandle.standardError.write("Need --truth <truth.json>\n".data(using: .utf8)!)
    exit(2)
}

var inputs: [(name: String, image: CGImage)] = []
if let pdf = options.pdfPath {
    for blur in options.blurs {
        if let image = renderPDF(pdf, frameHeight: options.height, blur: blur, rotate: options.rotate) {
            inputs.append(("pdf h=\(options.height) blur=\(blur) rot=\(options.rotate)", image))
        }
    }
}
for path in options.images {
    if let image = loadImage(path) { inputs.append(((path as NSString).lastPathComponent, image)) }
}

if options.csv {
    print("image,laplacian,tenengrad,sobel,lines_read,total,token_recall,smallest_pt,recognized_lines,ocr_ms")
}
var results: [(name: String, laplacian: Double, read: Int, smallest: Int?)] = []
func upscaled(_ image: CGImage, by factor: Double) -> CGImage {
    guard factor != 1 else { return image }
    let input = CIImage(cgImage: image)
    let filter = CIFilter(name: "CILanczosScaleTransform")!
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(factor, forKey: kCIInputScaleKey)
    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
    let output = filter.outputImage!
    return CIContext().createCGImage(output, from: output.extent) ?? image
}

for input in inputs {
    guard let buffer = pixelBuffer(from: upscaled(input.image, by: options.upscale)) else { continue }
    let laplacian = SharpnessMetrics.score(buffer, algorithm: .laplacian)
    let tenengrad = SharpnessMetrics.score(buffer, algorithm: .tenengrad)
    let sobel = SharpnessMetrics.score(buffer, algorithm: .sobel)
    let started = Date()
    let result = try? OCREngine.recognize(
        in: buffer,
        level: options.level,
        languages: options.languages,
        correction: options.correction,
        minimumTextHeight: options.minHeight
    )
    let ms = Date().timeIntervalSince(started) * 1000
    let s = score(result, truth: truth)
    let smallest = smallestReliablePoint(s.readByPoint, truth: truth)
    results.append((input.name, laplacian, s.linesRead, smallest))
    if options.csv {
        print("\(input.name),\(String(format: "%.1f,%.1f,%.1f", laplacian, tenengrad, sobel)),\(s.linesRead),\(truth.count),\(String(format: "%.2f", s.tokenRecall)),\(smallest.map(String.init) ?? "-"),\(s.recognizedLines),\(Int(ms))")
    } else {
        let pts = s.readByPoint.keys.sorted().map { "\($0)pt:\(s.readByPoint[$0]!)" }.joined(separator: " ")
        print("\(input.name): read \(s.linesRead)/\(truth.count) recall \(String(format: "%.2f", s.tokenRecall)) smallest-reliable \(smallest.map { "\($0)pt" } ?? "-") [\(pts)] lap=\(String(format: "%.0f", laplacian)) \(Int(ms))ms")
    }
}

if results.count > 1, !options.csv {
    let bestOCR = results.map(\.read).max() ?? 0
    if let pick = results.max(by: { $0.laplacian < $1.laplacian }) {
        print("---")
        print("Sharpest frame by Laplacian: \(pick.name) reads \(pick.read)/\(truth.count); best frame reads \(bestOCR)/\(truth.count)")
        let sorted = results.map(\.read).sorted()
        print("Median frame reads \(sorted[sorted.count / 2])/\(truth.count)")
    }
}
