//
//  MPVPlayerWrapper.swift
//  SharpStream
//
//  Swift wrapper around libmpv (MPVKit) for playback control and frame capture.
//
//  Threading model
//  - Playback commands and @Published state live on the main thread.
//  - libmpv events are pumped on a dedicated thread and forwarded to main.
//  - Frame capture (`screenshot-raw`) runs on `captureQueue`, never on main.
//  - Video is drawn through libmpv's render API by MPVOpenGLLayer, which owns
//    the render context. Loading is deferred until that context exists.
//  - `cleanup()` stops both background paths and frees the render context
//    before the handle is destroyed; the (potentially slow)
//    `mpv_terminate_destroy` runs off the main thread.
//

import Foundation
import CoreVideo
import AppKit
import Combine
import QuartzCore
import Libmpv

enum MPVEndFileReason: Equatable {
    case eof
    case stop
    case quit
    case error
    case redirect
    case unknown
}

enum MPVPlayerEvent {
    case fileLoaded
    case endFile(reason: MPVEndFileReason, message: String?)
    case shutdown
    case loadFailed(String)
}

final class MPVPlayerWrapper: ObservableObject {

    // MARK: - Published playback state (main thread)

    @Published private(set) var isPlaying: Bool = false
    /// Playback position, published at ~10 Hz granularity to keep SwiftUI cheap.
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackSpeed: Double = 1.0
    @Published private(set) var volume: Double = 1.0
    @Published private(set) var isBuffering: Bool = false
    /// Display size of the decoded video (aspect-corrected), when known.
    @Published private(set) var videoSize: CGSize?

    var eventHandler: ((MPVPlayerEvent) -> Void)?
    /// Set by the video layer; called on main right before libmpv is destroyed
    /// so the render context can be freed first (required by libmpv).
    var willDestroyHandle: (() -> Void)?

    // MARK: - libmpv state

    /// Owned libmpv handle. Accessed from main, the event thread and `captureQueue`;
    /// libmpv's client API is thread-safe. Only `cleanup()` clears it, after the
    /// background users have been stopped.
    private(set) var mpvHandle: OpaquePointer?
    private let isHeadless: Bool
    private var isInitialized = false
    private var isRenderReady = false
    private var pendingStreamURL: String?
    private var liveBufferSettings: LiveBufferSettings?
    private var rawTimePosition: TimeInterval = 0

    private let eventThreadLock = NSLock()
    private var eventThreadRunning = false
    private let eventThreadExited = DispatchSemaphore(value: 0)

    // MARK: - Frame capture state

    private let captureQueue = DispatchQueue(label: "com.sharpstream.frame-capture", qos: .userInitiated)
    // The members below are only touched on `captureQueue`.
    private var captureTimer: DispatchSourceTimer?
    private var captureInterval: TimeInterval = 0.25
    private var frameCallback: ((CVPixelBuffer, Date, TimeInterval?) -> Void)?
    private var capturePaused = true
    private var captureShutDown = false
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)
    private let captureMetricsLock = NSLock()
    private var captureCostEWMA: TimeInterval = 0     // guarded by captureMetricsLock
    private var publishedCaptureInterval: TimeInterval = 0.25 // guarded by captureMetricsLock

    private static let observedTimePos: UInt64 = 1
    private static let observedDuration: UInt64 = 2
    private static let observedPause: UInt64 = 3
    private static let observedSpeed: UInt64 = 4
    private static let observedVolume: UInt64 = 5
    private static let observedPausedForCache: UInt64 = 6
    private static let observedVideoParams: UInt64 = 7

    // MARK: - Lifecycle

    init(headless: Bool = false) {
        self.isHeadless = headless
        createHandle()
        completeInitialization()
    }

    deinit {
        cleanup()
    }

    private func createHandle() {
        guard let handle = mpv_create() else {
            print("❌ mpv_create failed")
            return
        }
        mpvHandle = handle

        mpv_set_option_string(handle, "terminal", "no")
        mpv_set_option_string(handle, "msg-level", "all=warn")
        mpv_set_option_string(handle, "idle", "yes")
        // Stay on the last frame at EOF instead of unloading the file, so files
        // remain seekable/OCR-able when they finish.
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "input-default-bindings", "no")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "osc", "no")
        // No Lua scripts (ytdl hook, stats, …): not needed and slow startup.
        mpv_set_option_string(handle, "load-scripts", "no")
        mpv_set_option_string(handle, "ytdl", "no")
        // Hardware decode with copy-back. Zero-copy VideoToolbox frames can't be
        // read back by `screenshot-raw` with the render API, which silently broke
        // Smart Pause / OCR capture. Copy-back costs one GPU→RAM copy per frame
        // (cheap on unified memory) and lets capture work even when the window
        // is hidden or occluded.
        mpv_set_option_string(handle, "hwdec", "videotoolbox-copy")
        mpv_set_option_string(handle, "network-timeout", "10")
        mpv_set_option_string(handle, "rtsp-transport", "tcp")
        // Back-seeking inside the demuxer cache is what powers the live DVR.
        mpv_set_option_string(handle, "demuxer-seekable-cache", "yes")

        if isHeadless {
            mpv_set_option_string(handle, "vo", "null")
            mpv_set_option_string(handle, "audio", "no")
            isRenderReady = true
        } else {
            // Frames are pulled through the render API by MPVOpenGLLayer.
            mpv_set_option_string(handle, "vo", "libmpv")
            mpv_set_option_string(handle, "ao", "coreaudio")
        }
    }

    /// Called by the video layer once its render context exists.
    func renderContextDidAttach() {
        guard !isRenderReady else { return }
        isRenderReady = true
        if let pendingURL = pendingStreamURL {
            pendingStreamURL = nil
            loadStream(url: pendingURL)
        }
    }

    /// Kept for the headless connection probe.
    @discardableResult
    func initializeForHeadlessIfNeeded() -> Bool {
        isInitialized
    }

    private func completeInitialization() {
        guard let handle = mpvHandle, !isInitialized else { return }

        let status = mpv_initialize(handle)
        guard status >= 0 else {
            reportFailure("MPV initialization failed: \(Self.errorString(status))")
            mpv_destroy(handle)
            mpvHandle = nil
            return
        }
        isInitialized = true

        mpv_observe_property(handle, Self.observedTimePos, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Self.observedDuration, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Self.observedPause, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, Self.observedSpeed, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Self.observedVolume, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Self.observedPausedForCache, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, Self.observedVideoParams, "video-params/aspect", MPV_FORMAT_DOUBLE)

        startEventThread(handle: handle)
        applyLiveBufferSettingsIfPossible()
    }

    /// Stops capture and the event thread, then destroys libmpv asynchronously.
    /// Safe to call more than once.
    func cleanup() {
        eventHandler = nil
        captureQueue.sync {
            captureShutDown = true
            captureTimer?.cancel()
            captureTimer = nil
            frameCallback = nil
        }

        guard let handle = mpvHandle else { return }
        mpvHandle = nil

        let wasRunning = eventThreadLock.withLock { () -> Bool in
            let running = eventThreadRunning
            eventThreadRunning = false
            return running
        }
        if wasRunning {
            mpv_wakeup(handle)
            if eventThreadExited.wait(timeout: .now() + 2.0) == .timedOut {
                // The event thread is stuck inside libmpv; leaking the handle is
                // safer than destroying it underneath that thread.
                print("⚠️ mpv event thread did not exit; leaking handle")
                return
            }
        }

        willDestroyHandle?()
        willDestroyHandle = nil

        let initialized = isInitialized
        isInitialized = false
        DispatchQueue.global(qos: .utility).async {
            if initialized {
                mpv_terminate_destroy(handle)
            } else {
                mpv_destroy(handle)
            }
        }
    }

    // MARK: - Events

    private func startEventThread(handle: OpaquePointer) {
        eventThreadLock.withLock { eventThreadRunning = true }
        let thread = Thread { [weak self] in
            self?.runEventLoop(handle: handle)
        }
        thread.name = "com.sharpstream.mpv-events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func runEventLoop(handle: OpaquePointer) {
        defer { eventThreadExited.signal() }
        while eventThreadLock.withLock({ eventThreadRunning }) {
            guard let event = mpv_wait_event(handle, 0.5)?.pointee else { continue }
            if event.event_id == MPV_EVENT_SHUTDOWN {
                DispatchQueue.main.async { [weak self] in self?.eventHandler?(.shutdown) }
                return
            }
            handleEvent(event)
        }
    }

    /// Runs on the event thread. Event payloads are only valid until the next
    /// `mpv_wait_event`, so values are copied out before hopping to main.
    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventHandler?(.fileLoaded)
            }

        case MPV_EVENT_END_FILE:
            var reason = MPVEndFileReason.unknown
            var message: String?
            if let data = event.data {
                let info = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                switch info.reason {
                case MPV_END_FILE_REASON_EOF: reason = .eof
                case MPV_END_FILE_REASON_STOP: reason = .stop
                case MPV_END_FILE_REASON_QUIT: reason = .quit
                case MPV_END_FILE_REASON_ERROR: reason = .error
                case MPV_END_FILE_REASON_REDIRECT: reason = .redirect
                default: reason = .unknown
                }
                if info.error < 0 {
                    message = Self.errorString(info.error)
                }
            }
            captureQueue.async { [weak self] in self?.capturePaused = true }
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = false
                self?.eventHandler?(.endFile(reason: reason, message: message))
            }

        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            handlePropertyChange(id: event.reply_userdata, property: property)

        default:
            break
        }
    }

    private func handlePropertyChange(id: UInt64, property: mpv_event_property) {
        var double: Double?
        var flag: Bool?
        if let data = property.data {
            if property.format == MPV_FORMAT_DOUBLE {
                double = data.assumingMemoryBound(to: Double.self).pointee
            } else if property.format == MPV_FORMAT_FLAG {
                flag = data.assumingMemoryBound(to: Int32.self).pointee != 0
            }
        }

        switch id {
        case Self.observedTimePos:
            guard let time = double, time.isFinite, time >= 0 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rawTimePosition = time
                if abs(self.currentTime - time) >= 0.1 {
                    self.currentTime = time
                }
            }
        case Self.observedDuration:
            let value = (double ?? 0).isFinite ? max(0, double ?? 0) : 0
            DispatchQueue.main.async { [weak self] in
                if self?.duration != value { self?.duration = value }
            }
        case Self.observedPause:
            guard let paused = flag else { return }
            captureQueue.async { [weak self] in self?.capturePaused = paused }
            DispatchQueue.main.async { [weak self] in
                if self?.isPlaying == paused { self?.isPlaying = !paused }
            }
        case Self.observedSpeed:
            guard let speed = double else { return }
            DispatchQueue.main.async { [weak self] in self?.playbackSpeed = speed }
        case Self.observedVolume:
            guard let volume = double else { return }
            DispatchQueue.main.async { [weak self] in self?.volume = volume / 100.0 }
        case Self.observedPausedForCache:
            let buffering = flag ?? false
            DispatchQueue.main.async { [weak self] in
                if self?.isBuffering != buffering { self?.isBuffering = buffering }
            }
        case Self.observedVideoParams:
            let size = currentVideoDisplaySize()
            DispatchQueue.main.async { [weak self] in
                if self?.videoSize != size { self?.videoSize = size }
            }
        default:
            break
        }
    }

    private func currentVideoDisplaySize() -> CGSize? {
        guard let handle = mpvHandle else { return nil }
        var width: Int64 = 0
        var height: Int64 = 0
        guard mpv_get_property(handle, "video-params/dw", MPV_FORMAT_INT64, &width) >= 0,
              mpv_get_property(handle, "video-params/dh", MPV_FORMAT_INT64, &height) >= 0,
              width > 0, height > 0 else { return nil }
        return CGSize(width: Int(width), height: Int(height))
    }

    // MARK: - Loading

    /// Load a stream URL (RTSP, SRT, UDP, HLS, local file, ...). If libmpv is not
    /// initialized yet (no surface attached), the load is deferred.
    func loadStream(url: String) {
        guard mpvHandle != nil else {
            reportFailure("Player is not available")
            return
        }
        guard isInitialized, isRenderReady else {
            // Without a render context mpv would disable the video track.
            pendingStreamURL = url
            return
        }
        let result = command(["loadfile", url, "replace"])
        if result < 0 {
            reportFailure("Failed to load stream: \(Self.errorString(result))")
        }
    }

    private func reportFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.eventHandler?(.loadFailed(message))
        }
    }

    // MARK: - Playback control

    func play() {
        setProperty("pause", "no")
        isPlaying = true
    }

    func pause() {
        setProperty("pause", "yes")
        isPlaying = false
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Seek to an absolute position on the stream timeline.
    /// `exact: false` snaps to keyframes (fast, used while scrubbing).
    @discardableResult
    func seek(to time: TimeInterval, exact: Bool) -> Bool {
        guard time.isFinite else { return false }
        let target = max(0, time)
        let ok = command(["seek", String(format: "%.3f", target), exact ? "absolute+exact" : "absolute+keyframes"]) >= 0
        if ok {
            currentTime = target
            rawTimePosition = target
        }
        return ok
    }

    @discardableResult
    func seek(offset: TimeInterval, exact: Bool) -> Bool {
        guard offset.isFinite else { return false }
        let ok = command(["seek", String(format: "%.3f", offset), exact ? "relative+exact" : "relative"]) >= 0
        if ok {
            let target = max(0, rawTimePosition + offset)
            currentTime = target
            rawTimePosition = target
        }
        return ok
    }

    @discardableResult
    func seek(to time: TimeInterval) -> Bool {
        seek(to: time, exact: true)
    }

    @discardableResult
    func seek(offset: TimeInterval) -> Bool {
        seek(offset: offset, exact: false)
    }

    func setSpeed(_ speed: Double) {
        setProperty("speed", String(speed))
        playbackSpeed = speed
    }

    func setVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        setProperty("volume", String(clamped * 100))
        self.volume = clamped
    }

    func stepFrame(backward: Bool) {
        command([backward ? "frame-back-step" : "frame-step"])
    }

    /// Unrounded playback position (the published `currentTime` is throttled).
    var precisePlaybackTime: TimeInterval {
        rawTimePosition
    }

    // MARK: - Frame capture

    /// Called on the capture queue with each sampled frame.
    func setFrameCallback(_ callback: @escaping (CVPixelBuffer, Date, TimeInterval?) -> Void) {
        captureQueue.async { [weak self] in
            self?.frameCallback = callback
            self?.rescheduleCaptureTimer()
        }
    }

    func setFrameExtractionInterval(_ seconds: TimeInterval) {
        let interval = max(0.1, seconds)
        captureQueue.async { [weak self] in
            guard let self, abs(self.captureInterval - interval) > 0.001 else { return }
            self.captureInterval = interval
            self.captureMetricsLock.withLock { self.publishedCaptureInterval = interval }
            self.rescheduleCaptureTimer()
        }
    }

    /// Average seconds spent capturing + processing one sampled frame.
    func captureCost() -> TimeInterval {
        captureMetricsLock.withLock { captureCostEWMA }
    }

    /// Fraction of the capture interval spent on capture + processing.
    func capturePipelineLoad() -> Double {
        captureMetricsLock.withLock {
            publishedCaptureInterval > 0 ? captureCostEWMA / publishedCaptureInterval : 0
        }
    }

    private func rescheduleCaptureTimer() {
        captureTimer?.cancel()
        captureTimer = nil
        guard frameCallback != nil, !captureShutDown else { return }

        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + captureInterval, repeating: captureInterval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.captureTick() }
        captureTimer = timer
        timer.resume()
    }

    private func captureTick() {
        // Paused video does not change: re-scoring it would only add duplicates
        // with fresh timestamps and distort the Smart Pause lookback window.
        guard !capturePaused, !captureShutDown,
              let callback = frameCallback,
              let handle = mpvHandle else { return }

        let started = CACurrentMediaTime()
        let playbackTime = Self.readDouble(handle, "time-pos")
        guard let frame = captureCurrentFrame(handle: handle), !Self.isBlankFrame(frame) else { return }
        callback(frame, Date(), playbackTime)

        let cost = CACurrentMediaTime() - started
        captureMetricsLock.withLock {
            captureCostEWMA = captureCostEWMA == 0 ? cost : captureCostEWMA * 0.8 + cost * 0.2
        }
    }

    /// Grab the currently decoded frame as a BGRA pixel buffer (video resolution,
    /// no OSD/letterboxing). Runs on the capture queue; never blocks main.
    func captureFrame() async -> CVPixelBuffer? {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self, !self.captureShutDown, let handle = self.mpvHandle else {
                    continuation.resume(returning: nil)
                    return
                }
                let frame = self.captureCurrentFrame(handle: handle)
                continuation.resume(returning: frame.flatMap { Self.isBlankFrame($0) ? nil : $0 })
            }
        }
    }

    /// Must run on `captureQueue`.
    private func captureCurrentFrame(handle: OpaquePointer) -> CVPixelBuffer? {
        var result = mpv_node()
        let status = withCStrings(["screenshot-raw", "video", "bgra"]) { args in
            mpv_command_ret(handle, args, &result)
        }
        guard status >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        return pixelBuffer(fromScreenshotNode: result)
    }

    private func pixelBuffer(fromScreenshotNode node: mpv_node) -> CVPixelBuffer? {
        guard node.format == MPV_FORMAT_NODE_MAP, let listPtr = node.u.list else { return nil }
        let list = listPtr.pointee

        var width = 0, height = 0, stride = 0
        var format = ""
        var bytes: UnsafeRawPointer?
        var byteCount = 0

        for index in 0..<Int(list.num) {
            guard let keyPtr = list.keys?[index] else { continue }
            let value = list.values[index]
            switch String(cString: keyPtr) {
            case "w": width = Int(value.u.int64)
            case "h": height = Int(value.u.int64)
            case "stride": stride = Int(value.u.int64)
            case "format":
                if value.format == MPV_FORMAT_STRING, let str = value.u.string { format = String(cString: str) }
            case "data":
                if value.format == MPV_FORMAT_BYTE_ARRAY, let array = value.u.ba {
                    bytes = UnsafeRawPointer(array.pointee.data)
                    byteCount = Int(array.pointee.size)
                }
            default:
                break
            }
        }

        let rowBytes = abs(stride)
        guard width > 0, height > 0, rowBytes >= width * 4, byteCount >= rowBytes * height,
              let bytes, format == "bgra" || format == "bgr0" else { return nil }

        guard let buffer = makePooledPixelBuffer(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        let copyBytes = width * 4

        for row in 0..<height {
            let sourceRow = stride > 0 ? row : (height - 1 - row)
            memcpy(destination.advanced(by: row * destinationStride), bytes.advanced(by: sourceRow * rowBytes), copyBytes)
        }

        if format == "bgr0" {
            // Padding byte is undefined; force opaque alpha so exports/Vision see pixels.
            for row in 0..<height {
                let pixels = destination.advanced(by: row * destinationStride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { pixels[x * 4 + 3] = 255 }
            }
        }
        return buffer
    }

    private func makePooledPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pixelBufferPool == nil || poolSize.width != width || poolSize.height != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            pixelBufferPool = pool
            poolSize = (width, height)
        }
        guard let pool = pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// True for frames that are essentially pure black (e.g. before the first
    /// decoded picture). Genuinely dark scenes still pass.
    private static func isBlankFrame(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let stepX = max(1, width / 32)
        let stepY = max(1, height / 32)
        for y in Swift.stride(from: 0, to: height, by: stepY) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: stepX) {
                let offset = x * 4
                if row[offset] > 6 || row[offset + 1] > 6 || row[offset + 2] > 6 {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - libmpv helpers

    @discardableResult
    private func command(_ args: [String]) -> Int32 {
        guard let handle = mpvHandle else { return -1 }
        return withCStrings(args) { mpv_command(handle, $0) }
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let handle = mpvHandle else { return }
        if isInitialized {
            let result = mpv_set_property_string(handle, name, value)
            if result < 0 {
                print("⚠️ mpv set \(name)=\(value) failed: \(Self.errorString(result))")
            }
        } else {
            mpv_set_option_string(handle, name, value)
        }
    }

    func setOptionOrProperty(_ name: String, _ value: String) {
        setProperty(name, value)
    }

    private func withCStrings<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let owned = strings.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    static func errorString(_ code: Int32) -> String {
        guard let cString = mpv_error_string(code) else { return "error \(code)" }
        return String(cString: cString)
    }

    static func readDouble(_ handle: OpaquePointer, _ name: String) -> Double? {
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return nil }
        return value
    }

    // MARK: - Live buffer settings

    struct LiveBufferSettings: Equatable {
        let maxWindowSeconds: TimeInterval
        let backBufferBytes: Int64?
    }

    func applyLiveBufferSettings(maxWindowSeconds: TimeInterval, backBufferBytes: Int64?) {
        liveBufferSettings = LiveBufferSettings(
            maxWindowSeconds: max(0, maxWindowSeconds),
            backBufferBytes: backBufferBytes
        )
        applyLiveBufferSettingsIfPossible()
    }

    private func applyLiveBufferSettingsIfPossible() {
        guard mpvHandle != nil, let settings = liveBufferSettings else { return }
        let seconds = max(1, Int(settings.maxWindowSeconds.rounded()))
        setProperty("cache", "yes")
        // Keep `seconds` of already-played stream behind the playhead.
        setProperty("demuxer-seekable-cache", "yes")
        setProperty("cache-secs", String(seconds))
        if let backBytes = settings.backBufferBytes, backBytes > 0 {
            setProperty("demuxer-max-back-bytes", String(backBytes))
        }
    }
}

extension MPVPlayerWrapper: SmartPausePlayer {}
