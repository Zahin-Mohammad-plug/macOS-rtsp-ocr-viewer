//
//  VideoLayoutMapper.swift
//  SharpStream
//
//  Geometry helpers for mapping OCR overlays to the rendered video rect.
//

import CoreGraphics

enum VideoLayoutMapper {
    static func videoRect(container: CGSize, source: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        guard source.width > 0, source.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }

        let scale = min(container.width / source.width, container.height / source.height)
        let renderedWidth = source.width * scale
        let renderedHeight = source.height * scale
        let originX = (container.width - renderedWidth) / 2.0
        let originY = (container.height - renderedHeight) / 2.0

        return CGRect(x: originX, y: originY, width: renderedWidth, height: renderedHeight)
    }

    static func mapVisionBox(_ normalizedBox: CGRect, in videoRect: CGRect) -> CGRect {
        guard videoRect.width > 0, videoRect.height > 0 else { return .zero }

        let width = normalizedBox.width * videoRect.width
        let height = normalizedBox.height * videoRect.height
        let x = videoRect.minX + (normalizedBox.minX * videoRect.width)

        // Vision bounding boxes use bottom-left origin. SwiftUI uses top-left.
        let y = videoRect.minY + ((1.0 - normalizedBox.maxY) * videoRect.height)

        return CGRect(x: x, y: y, width: width, height: height)
    }
}
