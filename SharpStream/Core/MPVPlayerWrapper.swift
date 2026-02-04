//
//  MPVPlayerWrapper.swift
//  SharpStream
//
//  Swift wrapper around libmpv (MPVKit) for video playback and frame extraction
//

import Foundation
import CoreVideo
import CoreMedia
import AppKit
import Combine
import os.log

#if canImport(Libmpv)
import Libmpv
#endif

enum MPVPlayerEvent {
    case fileLoaded
    case endFile
    case shutdown
    case loadFailed(String)
}

/// Swift wrapper around libmpv C API for video playback and frame extraction
/// 
/// This class provides a clean, type-safe interface to MPVKit/libmpv for:
/// - Multi-protocol stream playback (RTSP, SRT, UDP, HLS, etc.)
/// - Frame extraction for buffering and OCR
/// - Playback control (play, pause, seek, speed, volume)
/// - Stream metadata extraction
///
/// Thread Safety: All player operations must be called from the main thread.
/// Frame callbacks are dispatched to a background queue for processing.
class MPVPlayerWrapper: ObservableObject {
    
    // MARK: - Properties
    
    private var mpvHandle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var frameCallback: ((CVPixelBuffer, Date, TimeInterval?) -> Void)?
    private var windowView: Any? // Store view/layer for later wid setup
    private var windowIDSet: Bool = false // Track if wid was set
    private var isInitialized: Bool = false // Track if mpv_initialize was called
    private var pendingStreamURL: String? // Store stream URL if loadStream called before init
    private let isHeadless: Bool
    var eventHandler: ((MPVPlayerEvent) -> Void)?
    
    private let frameExtractionQueue = DispatchQueue(label: "com.sharpstream.frame-extraction", qos: .userInitiated)
    private var frameExtractionTimer: Timer?
    private var frameExtractionInterval: TimeInterval = 0.25 // 4 FPS baseline for Smart Pause selection quality
    private var frameExtractionInFlight = false
    private var frameExtractionSuspendedForSnapshot = false
    
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackSpeed: Double = 1.0
    @Published var volume: Double = 1.0
    
    private var metadataUpdateTimer: Timer?
    private var timeUpdateErrorCount = 0 // Track errors for logging
    private var eventLogCount = 0 // Track event logging to avoid spam
    private var lastSeekTime: TimeInterval = -1 // Track last seek attempt to detect failures
    
    // MARK: - Initialization
    
    private static let logger = Logger(subsystem: "com.sharpstream", category: "mpv")
    
    init(headless: Bool = false) {
        self.isHeadless = headless
        Self.logger.info("🚀 MPVPlayerWrapper.init() called")
        print("🚀 MPVPlayerWrapper.init() called")
        print("🔍 Checking MPVKit availability...")
        Self.logger.info("🔍 Checking MPVKit availability...")
        
        #if canImport(Libmpv)
        Self.logger.info("✅ canImport(Libmpv) = TRUE - Module found at compile time")
        print("✅ canImport(Libmpv) = TRUE - Module found at compile time")
        #else
        Self.logger.error("❌ canImport(Libmpv) = FALSE - COMPILATION ERROR")
        print("❌ canImport(Libmpv) = FALSE")
        print("   Swift compiler cannot find Libmpv module")
        print("   This is a compile-time check - module must be available to compiler")
        #endif
        
        setupMPV()
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Setup & Cleanup
    
    private func setupMPV() {
        print("🔧 MPVPlayerWrapper.setupMPV() called")

        #if canImport(Libmpv)
        print("✅ MPVKit is available")

        // Create mpv instance
        print("🎮 Creating mpv instance...")
        mpvHandle = mpv_create()
        guard let handle = mpvHandle else {
            print("❌ ERROR: Failed to create mpv instance")
            return
        }
        print("✅ MPV instance created")

        // Set options BEFORE initialization
        print("⚙️ Setting MPV options...")
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        if isHeadless {
            // Probe mode for validation/testing where no rendering view exists.
            mpv_set_option_string(handle, "vo", "null")
            mpv_set_option_string(handle, "audio", "no")
        } else {
            // Use gpu-next with moltenvk for Metal/Vulkan rendering (matches demo app)
            mpv_set_option_string(handle, "vo", "gpu-next")
            mpv_set_option_string(handle, "gpu-api", "vulkan")
            mpv_set_option_string(handle, "gpu-context", "moltenvk")
            // Audio configuration - explicit CoreAudio output for macOS
            mpv_set_option_string(handle, "audio", "yes")
            mpv_set_option_string(handle, "ao", "coreaudio")
        }
        mpv_set_option_string(handle, "network-timeout", "10")
        mpv_set_option_string(handle, "rtsp-transport", "tcp")
        mpv_set_option_string(handle, "video", "yes")
        print("✅ MPV options set")

        // IMPORTANT: Don't initialize yet - wait for window/view to be set
        // This ensures wid is set BEFORE mpv_initialize

        #else
        print("⚠️ WARNING: Libmpv not available - using placeholder implementation")
        print("   Make sure MPVKit package is added and Libmpv is accessible")
        #endif
    }

    /// Initialize MPV with the render context set up
    /// Called from setWindowID after window/view is available
    private func completeMPVInitialization() {
        #if canImport(Libmpv)
        guard let handle = mpvHandle, !isInitialized else {
            if isInitialized {
                print("⏭️ MPV already initialized")
            } else {
                print("❌ ERROR: MPV handle not available for initialization")
            }
            return
        }

        print("🚀 Initializing MPV...")
        let status = mpv_initialize(handle)
        if status < 0 {
            let errorString = mpv_error_string(status)
            let error = errorString != nil ? String(cString: errorString!) : "Unknown error"
            print("❌ ERROR: MPV initialization failed")
            print("   Status code: \(status)")
            print("   Error: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.loadFailed("MPV initialization failed: \(error)"))
            }
            mpv_destroy(handle)
            mpvHandle = nil
            return
        }

        isInitialized = true
        print("✅ MPV initialized successfully")

        // Set up event handling
        setupEventHandling()

        // Start metadata update timer
        startMetadataUpdateTimer()
        print("✅ MPVPlayerWrapper initialization complete")

        // If a stream was queued, load it now
        if let pendingURL = pendingStreamURL {
            pendingStreamURL = nil // Clear pending to avoid reload
            loadStream(url: pendingURL)
        }
        #endif
    }

    /// Headless mode can initialize without a rendering surface.
    /// Returns false when initialization is unavailable/failed.
    @discardableResult
    func initializeForHeadlessIfNeeded() -> Bool {
        #if canImport(Libmpv)
        guard isHeadless else { return isInitialized }
        if !isInitialized {
            completeMPVInitialization()
        }
        return isInitialized
        #else
        return false
        #endif
    }
    
    /// Set the window ID for video rendering
    /// IMPORTANT: This must be called BEFORE mpv_initialize() for proper setup
    /// This function sets the wid and then completes initialization
    /// Supports both NSView (for Cocoa) and CAMetalLayer (for Metal/Vulkan)
    func setWindowID(_ layerOrView: Any) {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else {
            print("⚠️ setWindowID: MPV handle not available")
            return
        }

        // If already initialized and window ID is set, skip
        if isInitialized && windowIDSet {
            return
        }
        
        // CRITICAL: wid must be set BEFORE mpv_initialize
        // If MPV is already initialized, we cannot set wid - this will fail
        // The view must be created before initialization completes
        if isInitialized {
            print("❌ ERROR: Cannot set window ID after MPV initialization")
            print("   Window ID must be set before mpv_initialize()")
            print("   The view should be created before the stream is loaded")
            return
        }

        // Convert layer/view to pointer for wid
        let pointer: UnsafeMutableRawPointer
        let typeName: String
        if let metalLayer = layerOrView as? CAMetalLayer {
            pointer = Unmanaged.passUnretained(metalLayer).toOpaque()
            typeName = "CAMetalLayer"
        } else if let view = layerOrView as? NSView {
            pointer = Unmanaged.passUnretained(view).toOpaque()
            typeName = "NSView"
        } else {
            print("❌ ERROR: setWindowID called with unsupported type: \(type(of: layerOrView))")
            return
        }

        let widValue = Int64(bitPattern: UInt64(Int(bitPattern: pointer)))
        var wid = widValue
        let result = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)

        if result < 0 {
            let errorString = mpv_error_string(result)
            let error = errorString != nil ? String(cString: errorString!) : "Unknown error"
            print("❌ ERROR: Failed to set window ID: \(error) (code: \(result))")
        } else {
            windowIDSet = true
            windowView = layerOrView
            print("✅ Window ID set successfully for video rendering (\(typeName))")

            // If not yet initialized, complete the initialization now
            if !isInitialized {
                completeMPVInitialization()
            }
        }
        #endif
    }
    
    private func setupEventHandling() {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        
        // Observe properties for state changes
        mpv_observe_property(handle, 0, "playback-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "volume", MPV_FORMAT_DOUBLE)
        
        // Start event loop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.eventLoop()
        }
        #endif
    }
    
    private func eventLoop() {
        guard let handle = mpvHandle else { return }
        
        // Event loop runs on background thread
        while let event = mpv_wait_event(handle, -1) {
            #if canImport(Libmpv)
            let eventId = event.pointee.event_id
            if eventId == MPV_EVENT_SHUTDOWN {
                DispatchQueue.main.async { [weak self] in
                    self?.eventHandler?(.shutdown)
                }
                break
            }
            
            handleEvent(event.pointee)
            #else
            // Placeholder for when MPVKit is not available
            break
            #endif
        }
    }
    
        #if canImport(Libmpv)
    private func handleEvent(_ event: mpv_event) {
        let eventId = event.event_id
        
        switch eventId {
        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.fileLoaded)
            }
            DispatchQueue.main.async { [weak self] in
                self?.updateDuration()
                // Start frame extraction once stream is loaded
                self?.startFrameExtraction()
                // Force initial time update after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.updateCurrentTime()
                }
            }
            
        case MPV_EVENT_PROPERTY_CHANGE:
            if let data = event.data {
                let property = data.bindMemory(to: mpv_event_property.self, capacity: 1).pointee
                if let name = property.name {
                    let propertyName = String(cString: name)
                    handlePropertyChange(propertyName, property: property)
                }
            }
            
        case MPV_EVENT_END_FILE:
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.endFile)
            }
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = false
            }
            
        case MPV_EVENT_SEEK:
            // Seek event - update time after seek completes
            print("📍 MPV_EVENT_SEEK received")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.updateCurrentTime()
            }
            
        case MPV_EVENT_PLAYBACK_RESTART:
            // Playback restarted - update time
            print("🔄 MPV_EVENT_PLAYBACK_RESTART received")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.updateCurrentTime()
            }
            
        default:
            // Log unknown events for debugging (but not constantly)
            if eventId != MPV_EVENT_NONE {
                // Only log occasionally to avoid spam
                eventLogCount += 1
                if eventLogCount % 50 == 0 {
                    print("MPV Event: \(eventId)")
                }
            }
            break
        }
    }
    
    private func handlePropertyChange(_ propertyName: String, property: mpv_event_property) {
        guard let data = property.data else { return }
        
        DispatchQueue.main.async { [weak self] in
            switch propertyName {
            case "playback-time":
                if property.format == MPV_FORMAT_DOUBLE {
                    let time = data.bindMemory(to: Double.self, capacity: 1).pointee
                    // Only update if time is valid and changed
                    if time >= 0 && abs(self?.currentTime ?? -1 - time) > 0.01 {
                        self?.currentTime = time
                    }
                }
                
            case "duration":
                if property.format == MPV_FORMAT_DOUBLE {
                    let dur = data.bindMemory(to: Double.self, capacity: 1).pointee
                    self?.duration = dur
                }
                
            case "pause":
                if property.format == MPV_FORMAT_FLAG {
                    let paused = data.bindMemory(to: Int32.self, capacity: 1).pointee
                    self?.isPlaying = (paused == 0)
                }
                
            case "speed":
                if property.format == MPV_FORMAT_DOUBLE {
                    let speed = data.bindMemory(to: Double.self, capacity: 1).pointee
                    self?.playbackSpeed = speed
                }
                
            case "volume":
                if property.format == MPV_FORMAT_DOUBLE {
                    let vol = data.bindMemory(to: Double.self, capacity: 1).pointee
                    self?.volume = vol / 100.0 // Convert from 0-100 to 0-1
                }
                
            default:
                break
            }
        }
    }
    #else
    private func handleEvent(_ event: Any) {
        // Placeholder
    }
    #endif
    
    func cleanup() {
        stopFrameExtraction()
        stopMetadataUpdateTimer()
        
        #if canImport(Libmpv)
        if let context = renderContext {
            mpv_render_context_free(context)
            renderContext = nil
        }
        
        if let handle = mpvHandle {
            mpv_terminate_destroy(handle)
            mpvHandle = nil
        }
        #endif
        isInitialized = false
        windowIDSet = false
        pendingStreamURL = nil
    }
    
    // MARK: - Stream Loading
    
    /// Load a stream URL (RTSP, SRT, UDP, HLS, local file, etc.)
    /// If MPV is not initialized yet, stores the URL and loads it after initialization
    func loadStream(url: String) {
        print("🎬 MPVPlayerWrapper.loadStream called")

        #if canImport(Libmpv)
        guard let handle = mpvHandle else {
            print("❌ ERROR: MPV handle not available")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("MPVError"),
                    object: nil,
                    userInfo: ["message": "MPV player not initialized"]
                )
            }
            return
        }

        // If MPV is not yet initialized, defer the stream loading
        if !isInitialized {
            pendingStreamURL = url
            return
        }

        // Escape URL if needed
        let escapedURL = url.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "loadfile \"\(escapedURL)\""

        print("📝 Executing MPV command: loadfile")

        let result = mpv_command_string(handle, command)

        if result < 0 {
            let errorString = mpv_error_string(result)
            let error = errorString != nil ? String(cString: errorString!) : "Unknown error (code: \(result))"
            print("❌ ERROR: Failed to load stream")
            print("   Error code: \(result)")
            print("   Error message: \(error)")
            print("   Original URL: \(url)")

            DispatchQueue.main.async {
                self.eventHandler?(.loadFailed("Failed to load stream: \(error)"))
                NotificationCenter.default.post(
                    name: NSNotification.Name("MPVError"),
                    object: nil,
                    userInfo: ["message": "Failed to load stream: \(error)", "url": url]
                )
            }
        } else {
            print("✅ Stream load command executed successfully (result: \(result))")
            print("   Waiting for MPV to start playback...")
        }
        #else
        print("⚠️ WARNING: Libmpv not available - cannot load stream: \(url)")
        print("   Make sure MPVKit package is properly linked and Libmpv is accessible")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("MPVError"),
                object: nil,
                userInfo: ["message": "Libmpv not available - check project dependencies"]
            )
        }
        #endif
    }
    
    // MARK: - Playback Control
    
    func play() {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, "pause", "no")
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = true
        }
        #endif
    }
    
    func pause() {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, "pause", "yes")
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
        }
        #endif
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    @discardableResult
    func seek(to time: TimeInterval) -> Bool {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return false }
        guard duration > 0 else {
            print("⚠️ Absolute seek unavailable: stream duration is unknown")
            return false
        }
        
        // Clamp time to valid range
        let clampedTime = max(0, min(time, duration))
        
        // Check if this is a significant change (avoid micro-seeks)
        let currentPlayerTime = self.currentTime
        if abs(clampedTime - currentPlayerTime) < 0.1 {
            return true // Too small a change, treat as successful no-op
        }
        
        print("🎯 Seeking to: \(String(format: "%.1f", clampedTime))s (current: \(String(format: "%.1f", currentPlayerTime))s)")
        
        // For streams with known duration, use percentage-based seeking for better accuracy
        // For streams without duration (live streams), use absolute time
        var seekSucceeded = false
        
        if duration > 0 {
            let percentage = (clampedTime / duration) * 100.0
            let command = "seek \(percentage) absolute-percent"
            let result = mpv_command_string(handle, command)
            
            if result == 0 {
                seekSucceeded = true
                print("✅ Seek command succeeded (percentage: \(String(format: "%.2f", percentage))%)")
            } else {
                // Log error
                let errorString = mpv_error_string(result)
                let error = errorString != nil ? String(cString: errorString!) : "Unknown error"
                print("⚠️ Percentage seek failed: \(result) (\(error)), trying absolute time")
                
                // Fallback to absolute time
                let fallbackCommand = "seek \(clampedTime) absolute"
                let fallbackResult = mpv_command_string(handle, fallbackCommand)
                if fallbackResult == 0 {
                    seekSucceeded = true
                    print("✅ Fallback absolute seek succeeded")
                } else {
                    let fallbackErrorString = mpv_error_string(fallbackResult)
                    let fallbackError = fallbackErrorString != nil ? String(cString: fallbackErrorString!) : "Unknown error"
                    print("❌ Absolute seek also failed: \(fallbackResult) (\(fallbackError))")
                    // Don't update UI if seek failed - let it stay at current position
                    return false
                }
            }
        }
        
        // Only update UI if seek command succeeded
        if seekSucceeded {
            lastSeekTime = clampedTime
            // Update currentTime immediately for UI responsiveness
            DispatchQueue.main.async { [weak self] in
                self?.currentTime = clampedTime
            }
            
            // Force multiple updates after seek to ensure we get the actual position
            // Sometimes MPV needs a moment to process the seek
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateCurrentTime()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.updateCurrentTime()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.updateCurrentTime()
                // After 0.5s, check if seek actually worked
                if let self = self, self.lastSeekTime >= 0 {
                    let actualTime = self.currentTime
                    if abs(actualTime - self.lastSeekTime) > 2.0 {
                        print("⚠️ Seek may have failed - requested \(String(format: "%.1f", self.lastSeekTime))s but got \(String(format: "%.1f", actualTime))s")
                    }
                    self.lastSeekTime = -1 // Reset
                }
            }
        } else {
            // Seek failed - don't update UI, keep current position
            print("⚠️ Seek failed - keeping current position: \(String(format: "%.1f", currentPlayerTime))s")
            // Force a time update to ensure we're still reading correctly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateCurrentTime()
            }
        }
        return seekSucceeded
        #else
        return false
        #endif
    }
    
    @discardableResult
    func seek(offset: TimeInterval) -> Bool {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return false }
        let command = "seek \(offset) relative"
        let result = mpv_command_string(handle, command)
        if result == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.updateCurrentTime()
            }
            return true
        }
        let errorString = mpv_error_string(result)
        let error = errorString != nil ? String(cString: errorString!) : "Unknown error"
        print("❌ Relative seek failed: \(result) (\(error))")
        return false
        #else
        return false
        #endif
    }
    
    func setSpeed(_ speed: Double) {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, "speed", String(speed))
        DispatchQueue.main.async { [weak self] in
            self?.playbackSpeed = speed
        }
        #endif
    }
    
    func setVolume(_ volume: Double) {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        let clampedVolume = max(0, min(100, volume * 100))
        mpv_set_property_string(handle, "volume", String(clampedVolume))
        DispatchQueue.main.async { [weak self] in
            self?.volume = volume
        }
        #endif
    }
    
    // MARK: - Frame-by-Frame Navigation
    
    func stepFrame(backward: Bool) {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        if backward {
            mpv_command_string(handle, "frame-back-step")
        } else {
            mpv_command_string(handle, "frame-step")
        }
        #endif
    }
    
    // MARK: - Frame Extraction
    
    /// Set callback for frame extraction.
    /// - Parameter callback: Called with frame, wall-clock timestamp, and playback time (if available).
    func setFrameCallback(_ callback: @escaping (CVPixelBuffer, Date, TimeInterval?) -> Void) {
        frameCallback = callback
        // Don't start extraction immediately - wait for stream to be ready
        // startFrameExtraction() will be called when stream is loaded
    }

    func setFrameExtractionInterval(_ seconds: TimeInterval) {
        let clampedInterval = max(0.1, seconds)
        guard abs(clampedInterval - frameExtractionInterval) > 0.001 else { return }
        frameExtractionInterval = clampedInterval

        // Re-arm timer so interval changes take effect immediately while connected.
        if frameExtractionTimer != nil {
            startFrameExtraction()
        }
    }
    
    func startFrameExtraction() {
        stopFrameExtraction()
        
        // Only start if we have a callback and handle
        guard frameCallback != nil, mpvHandle != nil else { return }
        
        frameExtractionTimer = Timer.scheduledTimer(withTimeInterval: frameExtractionInterval, repeats: true) { [weak self] _ in
            self?.extractCurrentFrame()
        }
    }

    func suspendFrameExtractionForSnapshot() {
        frameExtractionSuspendedForSnapshot = frameExtractionTimer != nil
        stopFrameExtraction()
    }

    func resumeFrameExtractionAfterSnapshot() {
        defer { frameExtractionSuspendedForSnapshot = false }
        guard frameExtractionSuspendedForSnapshot,
              frameCallback != nil,
              mpvHandle != nil else { return }
        startFrameExtraction()
    }
    
    private func stopFrameExtraction() {
        frameExtractionTimer?.invalidate()
        frameExtractionTimer = nil
        frameExtractionInFlight = false
    }
    
    private func extractCurrentFrame() {
        guard mpvHandle != nil,
              let callback = frameCallback else { return }

        guard !frameExtractionInFlight else { return }
        frameExtractionInFlight = true
        
        // Get current frame using screenshot API (simpler approach)
        // Note: This is a placeholder - actual implementation would use render context
        frameExtractionQueue.async { [weak self] in
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.frameExtractionInFlight = false
                }
            }
            // For now, we'll use a workaround with screenshot command
            // In production, use mpv_render_context_render() for better performance
            self?.extractFrameViaScreenshot(callback: callback)
        }
    }
    
    private func extractFrameViaScreenshot(callback: @escaping (CVPixelBuffer, Date, TimeInterval?) -> Void) {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }

        // Prefer a real playback timestamp, but still capture if timing is unavailable.
        let playbackTime = currentPlaybackTimeForFrameExtraction()
        let timestamp = Date()
        
        // Use screenshot command to extract frame to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let screenshotPath = tempDir.appendingPathComponent("mpv_screenshot_\(UUID().uuidString).png")
        
        // Execute screenshot command (screenshot-to-file is async, so we need to wait)
        let command = "screenshot-to-file \"\(screenshotPath.path)\" png"
        let result = mpv_command_string(handle, command)
        
        guard result == 0 else {
            // Fall back to rendering snapshot when mpv screenshot command is unavailable.
            if let fallbackBuffer = snapshotWindowViewPixelBuffer() {
                callback(fallbackBuffer, timestamp, playbackTime)
            }
            return
        }
        
        // Wait for file to be written (screenshot command is async)
        var attempts = 0
        let maxAttempts = 20 // 2 seconds max wait
        while attempts < maxAttempts {
            if FileManager.default.fileExists(atPath: screenshotPath.path) {
                loadScreenshotAsPixelBuffer(
                    from: screenshotPath,
                    timestamp: timestamp,
                    playbackTime: playbackTime,
                    callback: callback
                )
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
            attempts += 1
        }
        try? FileManager.default.removeItem(at: screenshotPath)
        if let fallbackBuffer = snapshotWindowViewPixelBuffer() {
            callback(fallbackBuffer, timestamp, playbackTime)
        }
        #else
        // Fallback: create empty placeholder
        let timestamp = Date()
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        
        if status == kCVReturnSuccess, let buffer = pixelBuffer {
            callback(buffer, timestamp, nil)
        }
        #endif
    }

    private func currentPlaybackTimeForFrameExtraction() -> TimeInterval? {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return nil }

        var time: Double = 0
        let format = MPV_FORMAT_DOUBLE

        var result = mpv_get_property(handle, "playback-time", format, &time)
        if result != 0 {
            result = mpv_get_property(handle, "time-pos", format, &time)
        }

        if result != 0 && duration > 0 {
            var position: Double = 0
            let posResult = mpv_get_property(handle, "percent-pos", format, &position)
            if posResult == 0 && position >= 0 {
                return (position / 100.0) * duration
            }
        }

        guard result == 0, time >= 0 else { return nil }
        return time
        #else
        return nil
        #endif
    }
    
    private func loadScreenshotAsPixelBuffer(
        from url: URL,
        timestamp: Date,
        playbackTime: TimeInterval?,
        callback: @escaping (CVPixelBuffer, Date, TimeInterval?) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("⚠️ Screenshot file not found: \(url.path)")
            return
        }
        
        // Load image from file
        guard let image = NSImage(contentsOf: url) else {
            print("⚠️ Failed to load screenshot image")
            try? FileManager.default.removeItem(at: url)
            return
        }
        
        // Convert NSImage to CVPixelBuffer
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("⚠️ Failed to get CGImage from screenshot")
            try? FileManager.default.removeItem(at: url)
            return
        }
        
        // Create CVPixelBuffer from CGImage
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
             kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!] as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            print("⚠️ Failed to create CVPixelBuffer")
            try? FileManager.default.removeItem(at: url)
            return
        }
        
        // Lock and copy image data
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: url)
        
        // Call callback with extracted frame
        callback(buffer, timestamp, playbackTime)
    }
    
    /// Get current frame as CVPixelBuffer (synchronous)
    /// Note: This is a blocking operation that uses screenshot command
    func getCurrentFrame() -> CVPixelBuffer? {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return nil }
        
        // Use screenshot command to extract frame
        let tempDir = FileManager.default.temporaryDirectory
        let screenshotPath = tempDir.appendingPathComponent("mpv_frame_\(UUID().uuidString).png")
        
        let command = "screenshot-to-file \"\(screenshotPath.path)\" png"
        let result = mpv_command_string(handle, command)
        
        guard result == 0 else { return snapshotWindowViewPixelBuffer() }
        
        // Wait for file (with timeout)
        var attempts = 0
        while !FileManager.default.fileExists(atPath: screenshotPath.path) && attempts < 40 {
            Thread.sleep(forTimeInterval: 0.05)
            attempts += 1
        }
        
        guard FileManager.default.fileExists(atPath: screenshotPath.path),
              let image = NSImage(contentsOf: screenshotPath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            try? FileManager.default.removeItem(at: screenshotPath)
            return snapshotWindowViewPixelBuffer()
        }
        
        // Convert to CVPixelBuffer
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
             kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!] as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            try? FileManager.default.removeItem(at: screenshotPath)
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        try? FileManager.default.removeItem(at: screenshotPath)
        return buffer
        #else
        return nil
        #endif
    }

    private func snapshotWindowViewPixelBuffer() -> CVPixelBuffer? {
        let cgImage: CGImage?

        if let layer = windowView as? CALayer {
            let bounds = layer.bounds.integral
            guard bounds.width > 1, bounds.height > 1 else { return nil }

            let scale = layer.contentsScale > 0 ? layer.contentsScale : 1.0
            let width = max(1, Int(bounds.width * scale))
            let height = max(1, Int(bounds.height * scale))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            cgImage = context.makeImage()
        } else if let view = windowView as? NSView {
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            view.cacheDisplay(in: bounds, to: rep)
            cgImage = rep.cgImage
        } else {
            cgImage = nil
        }

        guard let cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
             kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!] as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
    
    // MARK: - Metadata Extraction
    
    private func startMetadataUpdateTimer() {
        stopMetadataUpdateTimer() // Stop any existing timer
        
        // Update duration and currentTime periodically
        metadataUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateDuration()
            self?.updateCurrentTime()
        }
        
        // Verify timer was created
        if metadataUpdateTimer == nil {
            print("❌ ERROR: Failed to create metadata update timer")
        } else {
            print("✅ Metadata update timer started")
        }
    }
    
    private func updateCurrentTime() {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        var time: Double = 0
        let format = MPV_FORMAT_DOUBLE
        
        // Try playback-time first (most reliable)
        var result = mpv_get_property(handle, "playback-time", format, &time)
        
        // If that fails, try time-pos (alternative property name)
        if result != 0 {
            result = mpv_get_property(handle, "time-pos", format, &time)
        }
        
        // Also try position property (percentage-based, 0.0 to 100.0)
        if result != 0 && duration > 0 {
            var position: Double = 0
            let posResult = mpv_get_property(handle, "percent-pos", format, &position)
            if posResult == 0 && position >= 0 {
                // Convert percentage to time
                time = (position / 100.0) * duration
                result = 0 // Success
            }
        }
        
        // For live streams without duration, try to get elapsed time since start
        if result != 0 {
            // Try to get time-pos which works for live streams
            result = mpv_get_property(handle, "time-pos", format, &time)
        }
        
        if result == 0 && time >= 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Only update if value actually changed to avoid unnecessary UI updates
                let oldTime = self.currentTime
                if abs(oldTime - time) > 0.01 {
                    self.currentTime = time
                    // Log first successful update and updates after seeks
                    if oldTime == 0 && time > 0 {
                        print("✅ Time update working: \(String(format: "%.1f", time))s (duration: \(String(format: "%.1f", self.duration))s)")
                    } else if abs(oldTime - time) > 1.0 {
                        // Significant time change (likely after seek)
                        print("⏱️ Time updated: \(String(format: "%.1f", oldTime))s → \(String(format: "%.1f", time))s")
                    }
                } else if time == 0 && oldTime > 0 {
                    // Time reset to 0 - this might indicate a problem
                    print("⚠️ Time reset to 0 (was \(String(format: "%.1f", oldTime))s) - stream may have restarted")
                }
            }
        } else {
            // Log error for debugging (only occasionally to avoid spam)
            timeUpdateErrorCount += 1
            if timeUpdateErrorCount == 1 || timeUpdateErrorCount % 100 == 0 { // Log first error and every 100th
                let errorString = mpv_error_string(result)
                let error = errorString != nil ? String(cString: errorString!) : "Unknown error"
                print("⚠️ Failed to read playback-time: \(result) (\(error))")
                print("   Attempted: playback-time, time-pos, percent-pos")
                print("   Duration: \(duration), isPlaying: \(isPlaying), isInitialized: \(isInitialized)")
            }
        }
        #endif
    }
    
    private func stopMetadataUpdateTimer() {
        metadataUpdateTimer?.invalidate()
        metadataUpdateTimer = nil
    }
    
    private func updateDuration() {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        var dur: Double = 0
        let format = MPV_FORMAT_DOUBLE
        let result = mpv_get_property(handle, "duration", format, &dur)
        if result == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.duration = dur
            }
        }
        #endif
    }
    
    /// Get stream metadata (resolution, bitrate, frame rate)
    func getMetadata() -> (resolution: CGSize?, bitrate: Int?, frameRate: Double?) {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else {
            return (nil, nil, nil)
        }
        
        var resolution: CGSize?
        var bitrate: Int?
        var frameRate: Double?
        
        // Get resolution
        var width: Int64 = 0
        var height: Int64 = 0
        let formatInt64 = MPV_FORMAT_INT64
        
        if mpv_get_property(handle, "video-params/dw", formatInt64, &width) == 0,
           mpv_get_property(handle, "video-params/dh", formatInt64, &height) == 0 {
            resolution = CGSize(width: Int(width), height: Int(height))
        }
        
        // Get frame rate
        var fps: Double = 0
        let formatDouble = MPV_FORMAT_DOUBLE
        if mpv_get_property(handle, "video-params/fps", formatDouble, &fps) == 0 {
            frameRate = fps
        }
        
        // Get bitrate (may not be available for all streams)
        var br: Int64 = 0
        if mpv_get_property(handle, "video-bitrate", formatInt64, &br) == 0 {
            bitrate = Int(br)
        }
        
        return (resolution, bitrate, frameRate)
        #else
        return (nil, nil, nil)
        #endif
    }
    
    // MARK: - Render Context Setup (for frame extraction)
    
    /// Setup render context for frame extraction
    /// This is required for efficient frame extraction
    func setupRenderContext() -> Bool {
        #if canImport(Libmpv)
        guard mpvHandle != nil else { return false }
        
        // Create render context parameters
        // This is a placeholder - actual implementation requires proper setup
        // mpv_render_param structure setup would go here
        
        // TODO: Implement render context setup when MPVKit API is fully available
        return false
        #else
        return false
        #endif
    }
}

extension MPVPlayerWrapper: SmartPausePlayer {}

// MARK: - MPV C API Constants

// These constants should be available from MPVKit
// If MPVKit doesn't export them, they need to be defined here
#if !canImport(Libmpv)
// Placeholder constants - these should match Libmpv's definitions
private let MPV_FORMAT_DOUBLE: Int32 = 5
private let MPV_FORMAT_FLAG: Int32 = 1
private let MPV_FORMAT_INT64: Int32 = 4
private let MPV_FORMAT_STRING: Int32 = 6
private let MPV_EVENT_NONE: UInt32 = 0
private let MPV_EVENT_SHUTDOWN: UInt32 = 1
private let MPV_EVENT_FILE_LOADED: UInt32 = 8
private let MPV_EVENT_PROPERTY_CHANGE: UInt32 = 14
private let MPV_EVENT_END_FILE: UInt32 = 6
private let MPV_EVENT_SEEK: UInt32 = 3
private let MPV_EVENT_PLAYBACK_RESTART: UInt32 = 21

// Placeholder C API functions - these won't work without MPVKit
private func mpv_create() -> OpaquePointer? { return nil }
private func mpv_initialize(_: OpaquePointer) -> Int32 { return -1 }
private func mpv_set_option_string(_: OpaquePointer, _: String, _: String) {}
private func mpv_destroy(_: OpaquePointer) {}
private func mpv_command_string(_: OpaquePointer, _: String) -> Int32 { return -1 }
private func mpv_set_property_string(_: OpaquePointer, _: String, _: String) {}
private func mpv_get_property(_: OpaquePointer, _: String, _: Int32, _: UnsafeMutableRawPointer) -> Int32 { return -1 }
private func mpv_observe_property(_: OpaquePointer, _: UInt64, _: String, _: Int32) {}
private func mpv_wait_event(_: OpaquePointer, _: Double) -> UnsafePointer<mpv_event>? { return nil }
private func mpv_error_string(_: Int32) -> UnsafePointer<CChar>? { return nil }
private func mpv_terminate_destroy(_: OpaquePointer) {}
private func mpv_render_context_free(_: OpaquePointer) {}

// Placeholder structs
struct mpv_event {
    var event_id: UInt32
    var data: UnsafeMutableRawPointer?
}
struct mpv_event_property {
    var name: UnsafePointer<CChar>?
    var format: Int32
    var data: UnsafeMutableRawPointer?
}
struct mpv_event_error {
    var error: Int32
    var error_string: UnsafePointer<CChar>?
}
#endif
