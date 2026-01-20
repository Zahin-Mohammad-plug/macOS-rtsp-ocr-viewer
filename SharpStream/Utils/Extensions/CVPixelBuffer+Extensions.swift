//
//  CVPixelBuffer+Extensions.swift
//  SharpStream
//
//  CVPixelBuffer utility extensions
//

import Foundation
import CoreVideo

extension CVPixelBuffer {
    var size: CGSize {
        return CGSize(width: CVPixelBufferGetWidth(self), height: CVPixelBufferGetHeight(self))
    }
    
    var pixelFormat: OSType {
        return CVPixelBufferGetPixelFormatType(self)
    }
}
