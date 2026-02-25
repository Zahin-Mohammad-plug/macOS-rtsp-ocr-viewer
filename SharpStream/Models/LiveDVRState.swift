//
//  LiveDVRState.swift
//  SharpStream
//
//  Live DVR timeline state for buffered streams
//

import Foundation

struct LiveDVRState: Equatable {
    let windowSeconds: TimeInterval
    let lagSeconds: TimeInterval
    let liveEdgeDate: Date
    let dvrStartDate: Date

    var isAtLiveEdge: Bool {
        lagSeconds <= 1.0
    }

    static func empty(now: Date = Date()) -> LiveDVRState {
        LiveDVRState(
            windowSeconds: 0,
            lagSeconds: 0,
            liveEdgeDate: now,
            dvrStartDate: now
        )
    }
}
