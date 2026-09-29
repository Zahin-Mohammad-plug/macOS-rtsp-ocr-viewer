//
//  MPVVideoView.swift
//  SharpStream
//
//  Video surface driven by libmpv's render API (OpenGL, CAOpenGLLayer).
//
//  Why the render API instead of `wid` + Vulkan/MoltenVK: with `wid`, mpv
//  sizes its swapchain once at startup and never learns that the embedding
//  view resized, so any window resize, sidebar/inspector toggle or fullscreen
//  left a stale, cropped or offset picture. With the render API the app passes
//  the framebuffer size on every draw, so the picture always matches the view.
//
//  One view (and GL context) per player instance: SwiftUI gives this view the
//  player's identity, so a reconnect creates a fresh surface.
//

import SwiftUI
import AppKit
import OpenGL.GL
import OpenGL.GL3
import Libmpv

struct MPVVideoView: NSViewRepresentable {
    let player: MPVPlayerWrapper

    func makeNSView(context: Context) -> MPVVideoNSView {
        MPVVideoNSView(player: player)
    }

    func updateNSView(_ nsView: MPVVideoNSView, context: Context) {}
}

final class MPVVideoNSView: NSView {
    private let videoLayer: MPVOpenGLLayer

    init(player: MPVPlayerWrapper) {
        videoLayer = MPVOpenGLLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { true }

    override func makeBackingLayer() -> CALayer {
        videoLayer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.setNeedsDisplay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            videoLayer.contentsScale = window.backingScaleFactor
            videoLayer.setNeedsDisplay()
        }
    }
}

/// CAOpenGLLayer that owns the mpv render context.
///
/// The layer is asynchronous: CoreAnimation asks `canDraw` on every display
/// refresh (off the main thread) and we draw when mpv has signalled a new frame
/// or the drawable size changed. The CGL context lock serializes drawing with
/// render-context teardown on the main thread.
final class MPVOpenGLLayer: CAOpenGLLayer {
    private weak var player: MPVPlayerWrapper?
    private var renderContext: OpaquePointer?
    private var cglContext: CGLContextObj?
    private let stateLock = NSLock()
    private var frameAvailable = true      // guarded by stateLock
    private var lastDrawnSize = CGSize.zero // guarded by stateLock
    private var updateBox: RenderUpdateBox?

    init(player: MPVPlayerWrapper) {
        self.player = player
        super.init()
        isAsynchronous = true
        needsDisplayOnBoundsChange = true
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        updateBox = RenderUpdateBox { [weak self] in self?.markFrameAvailable() }
        player.willDestroyHandle = { [weak self] in self?.freeRenderContext() }
    }

    override init(layer: Any) {
        // Presentation-layer copies never render.
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        freeRenderContext()
        if let cglContext {
            CGLReleaseContext(cglContext)
        }
    }

    // MARK: CAOpenGLLayer

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorSize, CGLPixelFormatAttribute(32),
            CGLPixelFormatAttribute(0)
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &pixelFormat, &count)
        if let pixelFormat { return pixelFormat }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: pixelFormat)
        var swapInterval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swapInterval)
        CGLRetainContext(context)
        cglContext = context
        createRenderContext(in: context)
        return context
    }

    override func canDraw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        let pixelSize = CGSize(width: bounds.width * contentsScale, height: bounds.height * contentsScale)
        return stateLock.withLock { frameAvailable || pixelSize != lastDrawnSize }
    }

    override func draw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        stateLock.withLock {
            frameAvailable = false
            lastDrawnSize = CGSize(width: CGFloat(viewport[2]), height: CGFloat(viewport[3]))
        }

        if let renderContext, viewport[2] > 0, viewport[3] > 0 {
            var fbo = mpv_opengl_fbo(fbo: framebuffer, w: viewport[2], h: viewport[3], internal_format: 0)
            var flipY: CInt = 1
            withUnsafeMutablePointer(to: &fbo) { fboPointer in
                withUnsafeMutablePointer(to: &flipY) { flipPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                        mpv_render_param()
                    ]
                    _ = mpv_render_context_render(renderContext, &params)
                }
            }
            mpv_render_context_report_swap(renderContext)
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }

        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }

    // MARK: mpv render context

    private func createRenderContext(in context: CGLContextObj) {
        guard renderContext == nil, let player, let handle = player.mpvHandle, let updateBox else { return }

        CGLLockContext(context)
        defer { CGLUnlockContext(context) }
        CGLSetCurrentContext(context)

        let apiType = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                MPVOpenGLLayer.glProcAddress(name)
            },
            get_proc_address_ctx: nil
        )
        var created: OpaquePointer?
        let status = withUnsafeMutablePointer(to: &initParams) { initPointer -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPointer),
                mpv_render_param()
            ]
            return mpv_render_context_create(&created, handle, &params)
        }

        guard status >= 0, let created else {
            print("❌ mpv_render_context_create failed: \(MPVPlayerWrapper.errorString(status))")
            return
        }
        renderContext = created
        mpv_render_context_set_update_callback(created, { context in
            guard let context else { return }
            Unmanaged<RenderUpdateBox>.fromOpaque(context).takeUnretainedValue().callback()
        }, Unmanaged.passUnretained(updateBox).toOpaque())

        DispatchQueue.main.async { [weak player] in
            player?.renderContextDidAttach()
        }
    }

    /// Must run before the mpv handle is destroyed.
    private func freeRenderContext() {
        guard let renderContext else { return }
        if let cglContext {
            CGLLockContext(cglContext)
            CGLSetCurrentContext(cglContext)
        }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        if let cglContext {
            CGLUnlockContext(cglContext)
        }
    }

    /// Called by mpv (any thread) when a new frame should be drawn.
    private func markFrameAvailable() {
        stateLock.withLock { frameAvailable = true }
    }

    private static let openGLBundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)

    private static func glProcAddress(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
        guard let name,
              let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue) else {
            return nil
        }
        return CFBundleGetFunctionPointerForName(openGLBundle, symbol)
    }
}

private final class RenderUpdateBox {
    let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
}
