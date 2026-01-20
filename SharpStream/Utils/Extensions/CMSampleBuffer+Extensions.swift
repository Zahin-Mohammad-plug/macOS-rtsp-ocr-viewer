//
//  CMSampleBuffer+Extensions.swift
//  SharpStream
//
//  CMSampleBuffer utility extensions
//

import Foundation
import CoreMedia

extension CMSampleBuffer {
    var timestamp: Date {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(self)
        let seconds = CMTimeGetSeconds(presentationTime)
        return Date(timeIntervalSince1970: seconds)
    }
    
    var pixelBuffer: CVPixelBuffer? {
        return CMSampleBufferGetImageBuffer(self)
    }
}
