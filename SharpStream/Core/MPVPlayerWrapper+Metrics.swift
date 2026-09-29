//
//  MPVPlayerWrapper+Metrics.swift
//  SharpStream
//
//  Stream metadata, demuxer-cache (live DVR) and transport metrics.
//

import Foundation
import CoreGraphics
import Libmpv

extension MPVPlayerWrapper {
    struct LiveCacheMetrics {
        let windowSeconds: TimeInterval?
        /// Earliest stream timestamp that can still be seeked to.
        let windowStartTime: TimeInterval?
        let liveEdgeTime: TimeInterval?
        let cacheDuration: TimeInterval?
        let rawInputRateBps: Int?
        let totalBytesRead: Int64?
    }

    struct TransportMetricsSnapshot {
        let resolution: CGSize?
        let bitrate: Int?
        let frameRate: Double?
        let codecName: String?
        let frameType: String?
        let cacheDurationSeconds: TimeInterval?
        let seekableWindowSeconds: TimeInterval?
        let rawInputRateBps: Int?
        let totalBytesRead: Int64?
    }

    fileprivate struct DemuxerCacheRange {
        let start: Double
        let end: Double
    }

    fileprivate struct DemuxerCacheState {
        let ranges: [DemuxerCacheRange]
        let cacheDuration: Double?
        let rawInputRateBps: Int?
        let totalBytesRead: Int64?
    }

    static func windowSecondsForSeekableRanges(_ ranges: [(start: Double, end: Double)]) -> TimeInterval? {
        guard !ranges.isEmpty else { return nil }
        let minStart = ranges.map { $0.start }.min() ?? 0
        let maxEnd = ranges.map { $0.end }.max() ?? 0
        let window = max(0, maxEnd - minStart)
        return window > 0 ? window : nil
    }

    /// The seekable window reported by mpv's demuxer cache. Only the ranges mpv
    /// actually holds are reported — nothing is extrapolated from session time.
    func liveCacheMetrics() -> LiveCacheMetrics? {
        guard let handle = mpvHandle,
              let state = fetchDemuxerCacheState(handle: handle) else { return nil }

        let minStart = state.ranges.map { $0.start }.min()
        let maxEnd = state.ranges.map { $0.end }.max()
        let cacheDuration = (state.cacheDuration ?? 0) > 0 ? state.cacheDuration : nil

        return LiveCacheMetrics(
            windowSeconds: Self.windowSecondsForSeekableRanges(state.ranges.map { (start: $0.start, end: $0.end) }),
            windowStartTime: minStart,
            liveEdgeTime: maxEnd,
            cacheDuration: cacheDuration,
            rawInputRateBps: state.rawInputRateBps,
            totalBytesRead: state.totalBytesRead
        )
    }

    func getTransportMetricsSnapshot() -> TransportMetricsSnapshot {
        let metadata = getMetadata()
        let cacheMetrics = liveCacheMetrics()
        let resolvedRxRateBps: Int?
        if let rawInputRateBps = cacheMetrics?.rawInputRateBps, rawInputRateBps > 0 {
            resolvedRxRateBps = rawInputRateBps
        } else if let bitrate = metadata.bitrate, bitrate > 0 {
            resolvedRxRateBps = max(1, bitrate / 8)
        } else {
            resolvedRxRateBps = nil
        }

        return TransportMetricsSnapshot(
            resolution: metadata.resolution,
            bitrate: metadata.bitrate,
            frameRate: metadata.frameRate,
            codecName: metadata.codecName,
            frameType: currentFrameType(),
            cacheDurationSeconds: cacheMetrics?.cacheDuration,
            seekableWindowSeconds: cacheMetrics?.windowSeconds,
            rawInputRateBps: resolvedRxRateBps,
            totalBytesRead: cacheMetrics?.totalBytesRead
        )
    }

    fileprivate func fetchDemuxerCacheState(handle: OpaquePointer) -> DemuxerCacheState? {
        var node = mpv_node()
        let result = mpv_get_property(handle, "demuxer-cache-state", MPV_FORMAT_NODE, &node)
        guard result == 0 else { return nil }
        defer { mpv_free_node_contents(&node) }

        guard node.format == MPV_FORMAT_NODE_MAP,
              let nodeList = node.u.list else {
            return nil
        }

        let list = nodeList.pointee
        var ranges: [DemuxerCacheRange] = []
        var cacheDuration: Double?
        var rawInputRateBps: Int?
        var totalBytesRead: Int64?

        for index in 0..<Int(list.num) {
            guard let keyPtr = list.keys?[index] else { continue }
            let key = String(cString: keyPtr)
            let value = list.values[index]
            let lowerKey = key.lowercased()

            switch key {
            case "seekable-ranges":
                if let parsedRanges = parseSeekableRanges(value) {
                    ranges.append(contentsOf: parsedRanges)
                }
            case "cache-duration":
                cacheDuration = nodeToDouble(value)
            case "total-bytes":
                if let numericValue = nodeToDouble(value), numericValue >= 0 {
                    totalBytesRead = Int64(numericValue)
                }
            case "fw-bytes":
                if totalBytesRead == nil, let numericValue = nodeToDouble(value), numericValue >= 0 {
                    totalBytesRead = Int64(numericValue)
                }
            default:
                if rawInputRateBps == nil, let numericValue = nodeToDouble(value) {
                    if lowerKey == "raw-input-rate" {
                        rawInputRateBps = Int(max(0, numericValue))
                    } else if lowerKey.contains("input")
                                && lowerKey.contains("rate")
                                && (lowerKey.contains("byte") || lowerKey.contains("raw")) {
                        rawInputRateBps = Int(max(0, numericValue))
                    }
                }
            }
        }

        if rawInputRateBps == nil {
            rawInputRateBps = readFirstNumericProperty(
                handle: handle,
                names: [
                    "demuxer-cache-state/raw-input-rate",
                    "demuxer-cache-state/cache-speed",
                    "cache-speed"
                ]
            ).map { Int(max(0, $0)) }
        }

        if totalBytesRead == nil {
            totalBytesRead = readFirstNumericProperty(
                handle: handle,
                names: [
                    "demuxer-cache-state/total-bytes",
                    "demuxer-cache-state/fw-bytes"
                ]
            ).map { Int64(max(0, $0)) }
        }

        return DemuxerCacheState(
            ranges: ranges,
            cacheDuration: cacheDuration,
            rawInputRateBps: rawInputRateBps,
            totalBytesRead: totalBytesRead
        )
    }

    fileprivate func readFirstNumericProperty(handle: OpaquePointer, names: [String]) -> Double? {
        for name in names {
            if let intValue = readInt64Property(handle: handle, name: name) {
                return Double(intValue)
            }
            if let doubleValue = readDoubleProperty(handle: handle, name: name) {
                return doubleValue
            }
        }
        return nil
    }

    fileprivate func readInt64Property(handle: OpaquePointer, name: String) -> Int64? {
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) == 0 else {
            return nil
        }
        return value
    }

    fileprivate func readDoubleProperty(handle: OpaquePointer, name: String) -> Double? {
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) == 0 else {
            return nil
        }
        return value.isFinite ? value : nil
    }

    fileprivate func readFlagProperty(handle: OpaquePointer, name: String) -> Bool? {
        var value: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) == 0 else {
            return nil
        }
        return value != 0
    }

    fileprivate func readStringProperty(handle: OpaquePointer, name: String) -> String? {
        var node = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) == 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&node) }
        return stringFromNode(node)
    }

    fileprivate func parseSeekableRanges(_ node: mpv_node) -> [DemuxerCacheRange]? {
        guard node.format == MPV_FORMAT_NODE_ARRAY,
              let list = node.u.list else {
            return nil
        }

        var ranges: [DemuxerCacheRange] = []
        let nodeList = list.pointee

        for index in 0..<Int(nodeList.num) {
            let entry = nodeList.values[index]
            guard entry.format == MPV_FORMAT_NODE_MAP,
                  let mapList = entry.u.list else { continue }

            let map = mapList.pointee
            var start: Double?
            var end: Double?

            for mapIndex in 0..<Int(map.num) {
                guard let mapKeyPtr = map.keys?[mapIndex] else { continue }
                let mapKey = String(cString: mapKeyPtr)
                let mapValue = map.values[mapIndex]

                switch mapKey {
                case "start":
                    start = nodeToDouble(mapValue)
                case "end":
                    end = nodeToDouble(mapValue)
                default:
                    break
                }
            }

            if let start, let end {
                ranges.append(DemuxerCacheRange(start: start, end: end))
            }
        }

        return ranges.isEmpty ? nil : ranges
    }

    fileprivate func nodeToDouble(_ node: mpv_node) -> Double? {
        switch node.format {
        case MPV_FORMAT_DOUBLE:
            return node.u.double_
        case MPV_FORMAT_INT64:
            return Double(node.u.int64)
        default:
            return nil
        }
    }

    fileprivate func seekableRangeWindow(_ ranges: [DemuxerCacheRange]) -> TimeInterval? {
        MPVPlayerWrapper.windowSecondsForSeekableRanges(ranges.map { (start: $0.start, end: $0.end) })
    }

    fileprivate func stringFromNode(_ node: mpv_node) -> String? {
        guard node.format == MPV_FORMAT_STRING, let ptr = node.u.string else { return nil }
        let value = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    fileprivate func boolFromNode(_ node: mpv_node) -> Bool? {
        switch node.format {
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0
        case MPV_FORMAT_INT64:
            return node.u.int64 != 0
        default:
            return nil
        }
    }

    fileprivate func selectedVideoCodecFromTrackList(handle: OpaquePointer) -> String? {
        var node = mpv_node()
        guard mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &node) == 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&node) }

        guard node.format == MPV_FORMAT_NODE_ARRAY, let listPtr = node.u.list else {
            return nil
        }

        var fallbackCodec: String?
        let list = listPtr.pointee
        for index in 0..<Int(list.num) {
            let entry = list.values[index]
            guard entry.format == MPV_FORMAT_NODE_MAP, let mapPtr = entry.u.list else { continue }
            let map = mapPtr.pointee

            var type: String?
            var codec: String?
            var codecName: String?
            var codecDescription: String?
            var selected = false

            for mapIndex in 0..<Int(map.num) {
                guard let keyPtr = map.keys?[mapIndex] else { continue }
                let key = String(cString: keyPtr)
                let value = map.values[mapIndex]

                switch key {
                case "type":
                    type = stringFromNode(value)
                case "codec":
                    codec = stringFromNode(value)
                case "codec-name":
                    codecName = stringFromNode(value)
                case "codec-desc":
                    codecDescription = stringFromNode(value)
                case "selected":
                    selected = boolFromNode(value) ?? false
                default:
                    break
                }
            }

            guard type == "video" else { continue }
            let resolvedCodec = codecName ?? codec ?? codecDescription
            if fallbackCodec == nil {
                fallbackCodec = resolvedCodec
            }
            if selected, let resolvedCodec {
                return resolvedCodec
            }
        }

        return fallbackCodec
    }

    fileprivate func currentFrameType() -> String? {
        guard let handle = mpvHandle else { return nil }

        if let keyframe = readFlagProperty(handle: handle, name: "packet-video-keyframe") {
            return keyframe ? "I" : "P"
        }

        var node = mpv_node()
        guard mpv_get_property(handle, "video-frame-info", MPV_FORMAT_NODE, &node) == 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&node) }

        guard node.format == MPV_FORMAT_NODE_MAP, let mapPtr = node.u.list else {
            return nil
        }

        let map = mapPtr.pointee
        for mapIndex in 0..<Int(map.num) {
            guard let keyPtr = map.keys?[mapIndex] else { continue }
            let key = String(cString: keyPtr).lowercased()
            guard key.contains("type"), let value = stringFromNode(map.values[mapIndex]) else { continue }
            let uppercased = value.uppercased()
            if uppercased.hasPrefix("I") { return "I" }
            if uppercased.hasPrefix("P") { return "P" }
            if uppercased.hasPrefix("B") { return "B" }
        }

        return nil
    }


    /// Get stream metadata (resolution, bitrate, frame rate)
    func getMetadata() -> (resolution: CGSize?, bitrate: Int?, frameRate: Double?, codecName: String?) {
        guard let handle = mpvHandle else {
            return (nil, nil, nil, nil)
        }
        
        var resolution: CGSize?
        var bitrate: Int?
        var frameRate: Double?
        let codecName = selectedVideoCodecFromTrackList(handle: handle)
            ?? readStringProperty(handle: handle, name: "video-codec")
            ?? readStringProperty(handle: handle, name: "video-format")
        
        // Get resolution
        var width: Int64 = 0
        var height: Int64 = 0
        let formatInt64 = MPV_FORMAT_INT64
        
        if mpv_get_property(handle, "video-params/dw", formatInt64, &width) == 0,
           mpv_get_property(handle, "video-params/dh", formatInt64, &height) == 0 {
            resolution = CGSize(width: Int(width), height: Int(height))
        } else if mpv_get_property(handle, "video-params/w", formatInt64, &width) == 0,
                  mpv_get_property(handle, "video-params/h", formatInt64, &height) == 0 {
            resolution = CGSize(width: Int(width), height: Int(height))
        } else if let widthFallback = readFirstNumericProperty(
            handle: handle,
            names: ["video-out-params/w", "dwidth"]
        ), let heightFallback = readFirstNumericProperty(
            handle: handle,
            names: ["video-out-params/h", "dheight"]
        ), widthFallback > 0, heightFallback > 0 {
            resolution = CGSize(width: Int(widthFallback), height: Int(heightFallback))
        }
        
        // Get frame rate
        if let fps = readFirstNumericProperty(
            handle: handle,
            names: [
                "video-params/fps",
                "video-out-params/fps",
                "estimated-vf-fps",
                "container-fps",
                "display-fps",
                "fps"
            ]
        ), fps > 0 {
            frameRate = fps
        }
        
        // Get bitrate (may not be available for all streams)
        var br: Int64 = 0
        if mpv_get_property(handle, "video-bitrate", formatInt64, &br) == 0 {
            bitrate = Int(br)
        } else if mpv_get_property(handle, "packet-video-bitrate", formatInt64, &br) == 0 {
            bitrate = Int(br)
        }
        
        return (resolution, bitrate, frameRate, codecName)
    }
}
