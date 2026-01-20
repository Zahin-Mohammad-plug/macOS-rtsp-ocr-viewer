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
                setupRendering()
            }
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
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
        
        #if canImport(Libmpv)
        // Set up Libmpv rendering
        // For Metal/Vulkan (gpu-next), we pass the CAMetalLayer pointer
        // For Cocoa (libmpv), we pass the NSView pointer
        if let metalLayer = layer as? CAMetalLayer {
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

        // Update Metal layer drawable size when view resizes
        // Only update if view has valid non-zero bounds
        if let metalLayer = layer as? CAMetalLayer, bounds.width > 0 && bounds.height > 0 {
            let scale = metalLayer.contentsScale
            let newDrawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )

            // Only update if size actually changed to avoid unnecessary updates
            if abs(metalLayer.drawableSize.width - newDrawableSize.width) > 1.0 ||
               abs(metalLayer.drawableSize.height - newDrawableSize.height) > 1.0 {
                metalLayer.drawableSize = newDrawableSize
            }
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // View is now in a window, can set up rendering
            setupRendering()
        }
    }
}
