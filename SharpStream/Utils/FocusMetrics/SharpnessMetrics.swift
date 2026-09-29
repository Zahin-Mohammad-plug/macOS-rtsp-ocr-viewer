//
//  SharpnessMetrics.swift
//  SharpStream
//
//  Focus/sharpness metrics computed with Accelerate (vImage + vDSP).
//
//  Frames are downscaled to a bounded luma plane before scoring. Relative
//  sharpness ranking between frames of the same stream is preserved, while the
//  cost stays roughly constant regardless of source resolution (4K frames cost
//  the same as 720p ones).
//

import Accelerate
import CoreVideo

nonisolated enum SharpnessMetrics {
    /// Longest edge of the luma plane that metrics are computed on.
    static let analysisMaxDimension = 960

    static func score(_ pixelBuffer: CVPixelBuffer, algorithm: FocusAlgorithm) -> Double {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let luma = makeLumaPlane(pixelBuffer) else {
            return 0
        }

        switch algorithm {
        case .laplacian:
            let response = convolve(luma, kernel: [0, 1, 0, 1, -4, 1, 0, 1, 0])
            return variance(response)
        case .tenengrad:
            let gx = convolve(luma, kernel: sobelX)
            let gy = convolve(luma, kernel: sobelY)
            return meanSquare(gx) + meanSquare(gy)
        case .sobel:
            let gx = convolve(luma, kernel: sobelX)
            let gy = convolve(luma, kernel: sobelY)
            var magnitude = [Float](repeating: 0, count: gx.values.count)
            vDSP_vdist(gx.values, 1, gy.values, 1, &magnitude, 1, vDSP_Length(magnitude.count))
            return variance(Plane(values: magnitude, width: gx.width, height: gx.height))
        }
    }

    // MARK: - Internals

    private static let sobelX: [Float] = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
    private static let sobelY: [Float] = [-1, -2, -1, 0, 0, 0, 1, 2, 1]

    private struct Plane {
        var values: [Float]
        let width: Int
        let height: Int
    }

    private static func makeLumaPlane(_ pixelBuffer: CVPixelBuffer) -> Plane? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth >= 3, srcHeight >= 3 else { return nil }

        var source = vImage_Buffer(
            data: base,
            height: vImagePixelCount(srcHeight),
            width: vImagePixelCount(srcWidth),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )

        let scale = min(1.0, Double(analysisMaxDimension) / Double(max(srcWidth, srcHeight)))
        let width = max(3, Int(Double(srcWidth) * scale))
        let height = max(3, Int(Double(srcHeight) * scale))

        // Downscale in BGRA space first (vImage scaling is channel-agnostic).
        var scaledStorage: [UInt8] = []
        var scaled = source
        if width != srcWidth || height != srcHeight {
            scaledStorage = [UInt8](repeating: 0, count: width * height * 4)
            let status = scaledStorage.withUnsafeMutableBytes { raw -> vImage_Error in
                var destination = vImage_Buffer(
                    data: raw.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                return vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
            }
            guard status == kvImageNoError else { return nil }
        }

        // BGRA -> 8-bit luma (Rec.601 weights, fixed point / 256).
        var luma8 = [UInt8](repeating: 0, count: width * height)
        let matrix: [Int16] = [29, 150, 77, 0] // B, G, R, A
        let status = luma8.withUnsafeMutableBytes { lumaRaw -> vImage_Error in
            var destination = vImage_Buffer(
                data: lumaRaw.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )
            if scaledStorage.isEmpty {
                return vImageMatrixMultiply_ARGB8888ToPlanar8(&scaled, &destination, matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
            }
            return scaledStorage.withUnsafeMutableBytes { scaledRaw -> vImage_Error in
                scaled = vImage_Buffer(
                    data: scaledRaw.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                return vImageMatrixMultiply_ARGB8888ToPlanar8(&scaled, &destination, matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { return nil }

        var values = [Float](repeating: 0, count: width * height)
        vDSP.convertElements(of: luma8, to: &values)
        return Plane(values: values, width: width, height: height)
    }

    private static func convolve(_ plane: Plane, kernel: [Float]) -> Plane {
        var input = plane.values
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeMutableBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                var src = vImage_Buffer(
                    data: inRaw.baseAddress,
                    height: vImagePixelCount(plane.height),
                    width: vImagePixelCount(plane.width),
                    rowBytes: plane.width * MemoryLayout<Float>.stride
                )
                var dst = vImage_Buffer(
                    data: outRaw.baseAddress,
                    height: vImagePixelCount(plane.height),
                    width: vImagePixelCount(plane.width),
                    rowBytes: plane.width * MemoryLayout<Float>.stride
                )
                _ = vImageConvolve_PlanarF(&src, &dst, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return Plane(values: output, width: plane.width, height: plane.height)
    }

    private static func variance(_ plane: Plane) -> Double {
        guard !plane.values.isEmpty else { return 0 }
        let mean = Double(vDSP.mean(plane.values))
        return max(0, meanSquare(plane) - mean * mean)
    }

    private static func meanSquare(_ plane: Plane) -> Double {
        guard !plane.values.isEmpty else { return 0 }
        return Double(vDSP.meanSquare(plane.values))
    }
}
