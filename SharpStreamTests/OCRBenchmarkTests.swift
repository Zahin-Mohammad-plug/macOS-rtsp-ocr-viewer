//
//  OCRBenchmarkTests.swift
//  SharpStreamTests
//
//  OCR regression tests on a synthetic test page: random-word lines at
//  6-18 pt (no context for OCR to guess from) with known ground truth. The
//  page is rendered rotated and defocused to mimic a camera, and scored with
//  the rule used in scripts/ocr_bench: a line counts as read when its number
//  and >= 4 of its 5 words appear on one recognized line.
//
//  Thresholds sit a little below measured values (macOS 26, Vision accurate)
//  so they catch regressions without flaking.
//

import XCTest
import CoreImage
import CoreVideo
@testable import SharpStream

final class OCRBenchmarkTests: XCTestCase {
    // MARK: Fixture

    /// ocr_testpage.pdf (US Letter, Helvetica), base64.
    private static let pageBase64 = [
        "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUg",
        "L1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAg",
        "UiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ29udGVudHMgNCAwIFIgL1Jlc291cmNlcyA8PCAvRm9udCA8PCAvRjEgNSAwIFIg",
        "L0YyIDYgMCBSID4+ID4+ID4+CmVuZG9iago0IDAgb2JqCjw8IC9MZW5ndGggMTYyNiA+PgpzdHJlYW0KQlQgL0YyIDE2IFRmIDU0",
        "IDc0MCBUZCAoT0NSIFRFU1QgUEFHRSAtIFBpNGIgYmVuY2ggdGVzdCAyMDI2LTA5LTI5KSBUaiBFVApCVCAvRjIgOSBUZiA1NCA3",
        "MDYgVGQgKDZwdCkgVGogRVQKQlQgL0YxIDYgVGYgMTAwIDcwNiBUZCAoemVwaHlyIGp1bmdsZSB6aXBwZXIgc2FkZGxlIHNpbHZl",
        "ciA1NzQpIFRqIEVUCkJUIC9GMiA5IFRmIDU0IDY4MC40IFRkICg2cHQpIFRqIEVUCkJUIC9GMSA2IFRmIDEwMCA2ODAuNCBUZCAo",
        "amFzcGVyIGRvbHBoaW4gcGVwcGVyIG95c3RlciB5b25kZXIgNTkzKSBUaiBFVApCVCAvRjIgOSBUZiA1NCA2NTQuOCBUZCAoOHB0",
        "KSBUaiBFVApCVCAvRjEgOCBUZiAxMDAgNjU0LjggVGQgKGVtYmVyIGluZGlnbyBhbWJlciB0aW1iZXIgbm9ibGUgNzA2KSBUaiBF",
        "VApCVCAvRjIgOSBUZiA1NCA2MjYuMCBUZCAoOHB0KSBUaiBFVApCVCAvRjEgOCBUZiAxMDAgNjI2LjAgVGQgKGRvbHBoaW4gZm9y",
        "ZXN0IGVuZ2luZSBpbmRpZ28gdHVubmVsIDIzNSkgVGogRVQKQlQgL0YyIDkgVGYgNTQgNTk3LjIgVGQgKDEwcHQpIFRqIEVUCkJU",
        "IC9GMSAxMCBUZiAxMDAgNTk3LjIgVGQgKHZpb2xldCBkZWx0YSBsYW50ZXJuIGhhbW1lciBkb2xwaGluIDIyOCkgVGogRVQKQlQg",
        "L0YyIDkgVGYgNTQgNTY1LjIgVGQgKDEwcHQpIFRqIEVUCkJUIC9GMSAxMCBUZiAxMDAgNTY1LjIgVGQgKGxhbnRlcm4gcXVhcnR6",
        "IHF1aXZlciB1bWJlciBoYW1tZXIgMjQ4KSBUaiBFVApCVCAvRjIgOSBUZiA1NCA1MzMuMiBUZCAoMTJwdCkgVGogRVQKQlQgL0Yx",
        "IDEyIFRmIDEwMCA1MzMuMiBUZCAoYW1iZXIgaXNsYW5kIGluZGlnbyBrZXJuZWwgZW5naW5lIDk1NSkgVGogRVQKQlQgL0YyIDkg",
        "VGYgNTQgNDk4LjAwMDAwMDAwMDAwMDA2IFRkICgxMnB0KSBUaiBFVApCVCAvRjEgMTIgVGYgMTAwIDQ5OC4wMDAwMDAwMDAwMDAw",
        "NiBUZCAoZm9yZXN0IHZpb2xldCB3aW5kb3cgdHVubmVsIHlvbmRlciA4NTkpIFRqIEVUCkJUIC9GMiA5IFRmIDU0IDQ2Mi44MDAw",
        "MDAwMDAwMDAwNyBUZCAoMTRwdCkgVGogRVQKQlQgL0YxIDE0IFRmIDEwMCA0NjIuODAwMDAwMDAwMDAwMDcgVGQgKHNhZGRsZSBt",
        "ZWFkb3cgZG9scGhpbiBlbmdpbmUgc2lsdmVyIDE0NSkgVGogRVQKQlQgL0YyIDkgVGYgNTQgNDI0LjQwMDAwMDAwMDAwMDEgVGQg",
        "KDE0cHQpIFRqIEVUCkJUIC9GMSAxNCBUZiAxMDAgNDI0LjQwMDAwMDAwMDAwMDEgVGQgKG1hcmJsZSB5b25kZXIgYmFzaW4gY2Fu",
        "ZGxlIHF1YXJ0eiA4NzYpIFRqIEVUCkJUIC9GMiA5IFRmIDU0IDM4Ni4wMDAwMDAwMDAwMDAxIFRkICgxOHB0KSBUaiBFVApCVCAv",
        "RjEgMTggVGYgMTAwIDM4Ni4wMDAwMDAwMDAwMDAxIFRkIChqdW5nbGUgbWFyYmxlIHBlcHBlciB2ZWx2ZXQgZG9scGhpbiA4NTcp",
        "IFRqIEVUCkJUIC9GMiA5IFRmIDU0IDM0MS4yMDAwMDAwMDAwMDAxIFRkICgxOHB0KSBUaiBFVApCVCAvRjEgMTggVGYgMTAwIDM0",
        "MS4yMDAwMDAwMDAwMDAxIFRkIChxdWl2ZXIgaGFtbWVyIHZpb2xldCBtZWFkb3cgYW1iZXIgMjg4KSBUaiBFVAowLjUgdyA1NCA2",
        "MCBtIDU1OCA2MCBsIFMKQlQgL0YyIDggVGYgNTQgNDYgVGQgKEhlbHZldGljYS4gSG9sZCBmbGF0LCB3ZWxsIGxpdC4gR3JvdW5k",
        "IHRydXRoIGluIHRlc3RwYWdlX3RydXRoLmpzb24pIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKNSAwIG9iago8PCAvVHlwZSAvRm9u",
        "dCAvU3VidHlwZSAvVHlwZTEgL0Jhc2VGb250IC9IZWx2ZXRpY2EgPj4KZW5kb2JqCjYgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1",
        "YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhLUJvbGQgPj4KZW5kb2JqCnhyZWYKMCA3CjAwMDAwMDAwMDAgNjU1MzUg",
        "ZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDU4IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKMDAwMDAwMDI1MSAw",
        "MDAwMCBuIAowMDAwMDAxOTI5IDAwMDAwIG4gCjAwMDAwMDE5OTkgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA3IC9Sb290IDEg",
        "MCBSID4+CnN0YXJ0eHJlZgoyMDc0CiUlRU9GCg==",
    ].joined()

    private static let truth: [(pt: Int, text: String)] = [
        (6, "zephyr jungle zipper saddle silver 574"),
        (6, "jasper dolphin pepper oyster yonder 593"),
        (8, "ember indigo amber timber noble 706"),
        (8, "dolphin forest engine indigo tunnel 235"),
        (10, "violet delta lantern hammer dolphin 228"),
        (10, "lantern quartz quiver umber hammer 248"),
        (12, "amber island indigo kernel engine 955"),
        (12, "forest violet window tunnel yonder 859"),
        (14, "saddle meadow dolphin engine silver 145"),
        (14, "marble yonder basin candle quartz 876"),
        (18, "jungle marble pepper velvet dolphin 857"),
        (18, "quiver hammer violet meadow amber 288"),
    ]

    // MARK: Tests

    func testSharp1080pReadsDownTo12pt() throws {
        let frame = try render(height: 1080, blur: 0)
        let (read, smallest) = try score(frame)
        XCTAssertGreaterThanOrEqual(read, 8, "sharp 1080p page should read >= 8/12 lines")
        XCTAssertLessThanOrEqual(smallest ?? 99, 12, "sharp 1080p page should read every line >= 12 pt")
    }

    /// Guards the < 1600 px upscale step: without it 720p reads ~5/12 (14 pt).
    func test720pBenefitsFromUpscale() throws {
        let frame = try render(height: 720, blur: 0)
        let (read, smallest) = try score(frame)
        XCTAssertGreaterThanOrEqual(read, 6, "720p page should read >= 6/12 lines with upscaling")
        XCTAssertLessThanOrEqual(smallest ?? 99, 14)
    }

    /// Smart Pause's premise: the frame it ranks sharpest is the one OCR reads best.
    func testSharpnessRankingMatchesOCRQualityAcrossDefocus() throws {
        let blurs: [Double] = [2, 0, 1, 3]
        var scored: [(blur: Double, sharpness: Double, read: Int)] = []
        for blur in blurs {
            let frame = try render(height: 1080, blur: blur)
            let sharpness = SharpnessMetrics.score(frame, algorithm: .laplacian)
            scored.append((blur, sharpness, try score(frame).read))
        }
        let bySharpness = scored.sorted { $0.sharpness > $1.sharpness }
        XCTAssertEqual(bySharpness.map(\.blur), [0, 1, 2, 3], "sharpness must decrease with defocus")
        XCTAssertEqual(bySharpness.first?.read, scored.map(\.read).max(), "sharpest frame must read best")
        XCTAssertGreaterThan(bySharpness[0].read, bySharpness[2].read, "defocus should cost OCR lines")

        // And FocusScorer (what Smart Pause uses) picks that frame.
        let scorer = FocusScorer()
        let now = Date()
        for (index, blur) in blurs.enumerated() {
            scorer.scoreFrame(
                try render(height: 1080, blur: blur),
                timestamp: now.addingTimeInterval(-Double(blurs.count - index) * 0.25),
                sequenceNumber: index
            )
        }
        XCTAssertEqual(scorer.findBestFrame(in: 3, now: now)?.sequenceNumber, blurs.firstIndex(of: 0))
    }

    // MARK: Helpers

    private func score(_ frame: CVPixelBuffer) throws -> (read: Int, smallest: Int?) {
        let result = try OCREngine.recognize(
            in: frame,
            level: .accurate,
            languages: ["en-US"],
            correction: false,
            minimumTextHeight: OCREngine.defaultMinimumTextHeight
        )
        let lines = (result?.lines ?? []).map { tokens($0.text) }
        var readByPoint: [Int: Int] = [:]
        var read = 0
        for line in Self.truth {
            let expected = tokens(line.text)
            let words = expected.dropLast()
            let number = expected.last ?? ""
            let found = lines.contains { candidate in
                candidate.contains(number) && words.filter { candidate.contains($0) }.count >= 4
            }
            if found {
                read += 1
                readByPoint[line.pt, default: 0] += 1
            }
        }
        var smallest: Int?
        for point in Set(Self.truth.map(\.pt)).sorted(by: >) {
            let expectedCount = Self.truth.filter { $0.pt == point }.count
            if readByPoint[point, default: 0] == expectedCount { smallest = point } else { break }
        }
        return (read, smallest)
    }

    private func tokens(_ string: String) -> [String] {
        let cleaned = String(string.lowercased().map { (c: Character) -> Character in
            c.isLetter || c.isNumber ? c : " "
        })
        return cleaned.split(separator: " ").map(String.init)
    }

    /// Page filling ~90% of a 16:9 frame, rotated 72 degrees like the bench
    /// camera, with an optional Gaussian defocus.
    private func render(height: Int, blur: Double) throws -> CVPixelBuffer {
        let data = try XCTUnwrap(Data(base64Encoded: Self.pageBase64))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let page = try XCTUnwrap(CGPDFDocument(provider)?.page(at: 1))
        let width = height * 16 / 9
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 0.35, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let box = page.getBoxRect(.mediaBox)
        let scale = CGFloat(height) * 0.9 / box.height
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: 72 * .pi / 180)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.width / 2, y: -box.height / 2)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(box)
        context.drawPDFPage(page)

        var image = CIImage(cgImage: try XCTUnwrap(context.makeImage()))
        if blur > 0 {
            image = image.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: image.extent)
        }

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        let output = try XCTUnwrap(buffer)
        CIContext().render(image, to: output)
        return output
    }
}
