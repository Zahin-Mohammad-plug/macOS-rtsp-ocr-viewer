//
//  MPVVideoView.swift
//  SharpStream
//
//  SwiftUI view wrapper for MPVKit video rendering
//

import SwiftUI
import AppKit
import QuartzCore

/// SwiftUI view that wraps MPVKit video rendering using NSViewRepresentable
/// 
/// This view bridges MPVKit's native rendering (OpenGL/Metal) to SwiftUI.
/// It creates an NSView that hosts the MPVKit player's video output.
struct MPVVideoView: NSViewRepresentable {
    let player: MPVPlayerWrapper?

    func makeNSView(context: Context) -> MPVVideoNSView {
        let view = MPVVideoNSView(frame: .zero)
        view.player = player
        return view
    }

    func updateNSView(_ nsView: MPVVideoNSView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// NSView that hosts MPVKit video rendering
/// 
/// This view sets up the rendering context for MPVKit to draw video frames.
/// The actual rendering is handled by MPVKit's libmpv render API.
class MPVVideoNSView: NSView {
    var player: MPVPlayerWrapper? {
        didSet {
            if player != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.setupRendering()
                }
            }
        }
    }
    
    private var layoutUpdateTimer: Timer?
    private var windowObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    deinit {
        layoutUpdateTimer?.invalidate()
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowResizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupView() {
        wantsLayer = true

        // For Metal/Vulkan rendering (gpu-next), we need a CAMetalLayer
        // This matches the demo app's approach
        let metalLayer = CAMetalLayer()
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
        metalLayer.framebufferOnly = false  // Allow compositing for video rendering
        metalLayer.backgroundColor = NSColor.black.cgColor

        // Set a minimum valid drawable size to avoid Metal validation errors
        // Will be updated properly in layout() when view has valid bounds
        metalLayer.drawableSize = CGSize(width: 1, height: 1)
        layer = metalLayer
    }
    
    private func setupRendering() {
        guard let player = player else {
            return
        }
        guard window != nil else {
            return
        }
        guard bounds.width > 1, bounds.height > 1 else {
            scheduleLayoutUpdate()
            return
        }
        
        #if canImport(Libmpv)
        // Set up Libmpv rendering
        // For Metal/Vulkan (gpu-next), we pass the CAMetalLayer pointer
        // For Cocoa (libmpv), we pass the NSView pointer
        if let metalLayer = layer as? CAMetalLayer {
            guard updateMetalLayerSize(force: true), metalLayer.drawableSize.width > 1, metalLayer.drawableSize.height > 1 else {
                scheduleLayoutUpdate()
                return
            }
            // Use Metal layer for gpu-next rendering (like demo)
            player.setWindowID(metalLayer)
        } else {
            // Fallback to NSView for Cocoa rendering
            player.setWindowID(self)
        }
        #endif
    }
    
    override func layout() {
        super.layout()
        
        // Cancel pending update
        layoutUpdateTimer?.invalidate()
        
        // Debounce rapid updates during window movement
        layoutUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.updateMetalLayerSize()
            self?.setupRendering()
        }
    }
    
    @discardableResult
    private func updateMetalLayerSize(force: Bool = false) -> Bool {
        guard let metalLayer = layer as? CAMetalLayer,
              bounds.width > 0 && bounds.height > 0,
              window != nil else {
            return false
        }
        
        let scale = metalLayer.contentsScale
        let newDrawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        
        // Only update if size actually changed significantly
        let widthDiff = abs(metalLayer.drawableSize.width - newDrawableSize.width)
        let heightDiff = abs(metalLayer.drawableSize.height - newDrawableSize.height)
        
        if force || widthDiff > 2.0 || heightDiff > 2.0 {
            // Keep this synchronous so mpv does not initialize against a stale 1x1 drawable.
            metalLayer.drawableSize = newDrawableSize
        }
        return metalLayer.drawableSize.width > 1 && metalLayer.drawableSize.height > 1
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        if let window = window {
            // Update scale for current screen
            if let metalLayer = layer as? CAMetalLayer {
                metalLayer.contentsScale = window.screen?.backingScaleFactor ?? 1.0
            }
            
            // Ensure the drawable is sized before mpv initialization.
            _ = updateMetalLayerSize(force: true)
            setupRendering()
            
            // Observe window dragging
            observeWindowDragging()
        } else {
            // View removed from window, clean up observers
            if let observer = windowObserver {
                NotificationCenter.default.removeObserver(observer)
                windowObserver = nil
            }
            if let observer = windowResizeObserver {
                NotificationCenter.default.removeObserver(observer)
                windowResizeObserver = nil
            }
        }
    }
    
    private func observeWindowDragging() {
        guard let window = window else { return }
        
        // Remove existing observer if any
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Observe window frame changes to detect dragging
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // Window moved - debounce layout update
            self?.scheduleLayoutUpdate()
        }
        
        // Also observe window resize
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleLayoutUpdate()
        }
    }
    
    private func scheduleLayoutUpdate() {
        layoutUpdateTimer?.invalidate()
        layoutUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.updateMetalLayerSize()
            self?.setupRendering()
        }
    }
}
