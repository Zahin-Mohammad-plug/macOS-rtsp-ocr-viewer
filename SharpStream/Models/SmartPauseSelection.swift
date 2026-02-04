//
//  SmartPauseSelection.swift
//  SharpStream
//
//  Smart Pause selection metadata
//

import Foundation

struct SmartPauseSelection: Equatable {
    let sequenceNumber: Int
    let score: Double
    let frameTimestamp: Date
    let playbackTime: TimeInterval?
    let frameAge: TimeInterval
    let seekMode: SeekMode
}
