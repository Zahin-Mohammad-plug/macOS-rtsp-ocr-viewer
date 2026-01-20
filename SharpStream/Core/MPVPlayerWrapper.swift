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
    private var frameCallback: ((CVPixelBuffer, Date) -> Void)?
    private var windowView: Any? // Store view/layer for later wid setup
    private var windowIDSet: Bool = false // Track if wid was set
    private var isInitialized: Bool = false // Track if mpv_initialize was called
    private var pendingStreamURL: String? // Store stream URL if loadStream called before init
    
    private let frameExtractionQueue = DispatchQueue(label: "com.sharpstream.frame-extraction", qos: .userInitiated)
    private var frameExtractionTimer: Timer?
    private var frameExtractionInterval: TimeInterval = 1.0 / 30.0 // Default: 30 FPS
    
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackSpeed: Double = 1.0
    @Published var volume: Double = 1.0
    
    private var metadataUpdateTimer: Timer?
    
    // MARK: - Initialization
    
    private static let logger = Logger(subsystem: "com.sharpstream", category: "mpv")
    
    init() {
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
        // Use gpu-next with moltenvk for Metal/Vulkan rendering (matches demo app)
        mpv_set_option_string(handle, "vo", "gpu-next")
        mpv_set_option_string(handle, "gpu-api", "vulkan")
        mpv_set_option_string(handle, "gpu-context", "moltenvk")
        // Audio configuration - explicit CoreAudio output for macOS
        mpv_set_option_string(handle, "audio", "yes")
        mpv_set_option_string(handle, "ao", "coreaudio")
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
                self?.updateDuration()
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
                self?.isPlaying = false
            }
            
        default:
            // Log unknown events for debugging
            if eventId != MPV_EVENT_NONE {
                print("MPV Event: \(eventId)")
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
                    self?.currentTime = time
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
    
    func seek(to time: TimeInterval) {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        let command = "seek \(time) absolute"
        mpv_command_string(handle, command)
        DispatchQueue.main.async { [weak self] in
            self?.currentTime = time
        }
        #endif
    }
    
    func seek(offset: TimeInterval) {
        #if canImport(Libmpv)
        guard let handle = mpvHandle else { return }
        let command = "seek \(offset) relative"
        mpv_command_string(handle, command)
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
    
    /// Set callback for frame extraction
    /// - Parameter callback: Called with CVPixelBuffer and timestamp for each extracted frame
    func setFrameCallback(_ callback: @escaping (CVPixelBuffer, Date) -> Void) {
        frameCallback = callback
        startFrameExtraction()
    }
    
    private func startFrameExtraction() {
        stopFrameExtraction()
        
        frameExtractionTimer = Timer.scheduledTimer(withTimeInterval: frameExtractionInterval, repeats: true) { [weak self] _ in
            self?.extractCurrentFrame()
        }
    }
    
    private func stopFrameExtraction() {
        frameExtractionTimer?.invalidate()
        frameExtractionTimer = nil
    }
    
    private func extractCurrentFrame() {
        guard let handle = mpvHandle,
              let callback = frameCallback else { return }
        
        // Get current frame using screenshot API (simpler approach)
        // Note: This is a placeholder - actual implementation would use render context
        frameExtractionQueue.async { [weak self] in
            // For now, we'll use a workaround with screenshot command
            // In production, use mpv_render_context_render() for better performance
            self?.extractFrameViaScreenshot(callback: callback)
        }
    }
    
    private func extractFrameViaScreenshot(callback: @escaping (CVPixelBuffer, Date) -> Void) {
        // This is a simplified approach using screenshot
        // Better approach would be to use render context directly
        guard let handle = mpvHandle else { return }
        
        // Get current playback time for timestamp
        var time: Double = 0
        let format = MPV_FORMAT_DOUBLE
        mpv_get_property(handle, "playback-time", format, &time)
        
        let timestamp = Date()
        
        // For now, return a placeholder
        // TODO: Implement actual frame extraction using render context
        // This requires setting up mpv_render_context with proper parameters
        
        // Placeholder: Create empty pixel buffer
        // In production, extract actual frame from MPVKit
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        
        if status == kCVReturnSuccess, let buffer = pixelBuffer {
            callback(buffer, timestamp)
        }
    }
    
    /// Get current frame as CVPixelBuffer (synchronous)
    func getCurrentFrame() -> CVPixelBuffer? {
        // Placeholder implementation
        // In production, use render context to extract frame
        return nil
    }
    
    // MARK: - Metadata Extraction
    
    private func startMetadataUpdateTimer() {
        // Update duration less frequently to avoid excessive logging
        metadataUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateDuration()
        }
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
