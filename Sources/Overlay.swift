import AppKit
import Metal
import QuartzCore

/// Shared Metal objects. The pipelines are compiled once from `glowShaderSource`.
@MainActor
final class GlowRenderer {
    static let shared = GlowRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let library: MTLLibrary

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this Mac")
        }
        self.device = device
        self.queue = queue
        do {
            library = try device.makeLibrary(source: glowShaderSource, options: nil)
        } catch {
            fatalError("Glow shader failed to compile: \(error)")
        }
    }

    func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = pipelines[format] { return p }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "glow_vertex")
        desc.fragmentFunction = library.makeFunction(name: "glow_fragment")
        desc.colorAttachments[0].pixelFormat = format
        guard let p = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipelines[format] = p
        return p
    }
}

/// Transparent, click-through view that draws the rim light with Metal. Only four strips along the
/// screen edges are rendered (each its own CAMetalLayer), so the GPU and the window server only
/// touch the pixels that can actually light up; the middle of the screen costs nothing.
@MainActor
final class GlowView: NSView {
    private enum Edge: CaseIterable { case top, bottom, left, right }

    private struct Strip {
        let edge: Edge
        let layer: CAMetalLayer
        var rect: CGRect = .zero   // points, top-left origin
    }

    private var strips: [Strip] = []
    private var link: CADisplayLink?
    private var linkRate: Float = -1
    private var hdr = false
    private var quality = Settings.shared.quality
    private var visibleOnScreen = true
    private var laidOutThickness: Double = -1
    private var renderScale: CGFloat = 2
    private let screenIsBuiltIn: Bool

    init(frame: NSRect, builtIn: Bool) {
        screenIsBuiltIn = builtIn
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.isOpaque = false
        hdr = wantsHDR()
        for edge in Edge.allCases {
            let l = CAMetalLayer()
            l.device = GlowRenderer.shared.device
            l.isOpaque = false
            l.framebufferOnly = true
            l.maximumDrawableCount = 3
            l.anchorPoint = .zero
            configure(l, hdr: hdr)
            layer?.addSublayer(l)
            strips.append(Strip(edge: edge, layer: l))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// HDR when asked for, and always in Extreme on displays that can go brighter than white (XDR):
    /// the neon tube gets the extra headroom.
    private func wantsHDR() -> Bool {
        let s = Settings.shared
        let screen = window?.screen ?? NSScreen.main
        return s.hdr || (s.quality == .extreme && (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1)
    }

    private func configure(_ l: CAMetalLayer, hdr: Bool) {
        if hdr {
            l.pixelFormat = .rgba16Float
            l.wantsExtendedDynamicRangeContent = true
            l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        } else if quality == .extreme {
            // 16-bit colour: perfectly smooth falloff, no dithering needed.
            l.pixelFormat = .rgba16Float
            l.wantsExtendedDynamicRangeContent = false
            l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        } else {
            l.pixelFormat = .bgra8Unorm
            l.wantsExtendedDynamicRangeContent = false
            l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    func applySettings() {
        let s = Settings.shared
        if wantsHDR() != hdr || s.quality != quality {
            let rescale = s.quality.renderScale(backing: 2) != quality.renderScale(backing: 2)
            quality = s.quality
            hdr = wantsHDR()
            for strip in strips { configure(strip.layer, hdr: hdr) }
            if rescale { layoutStrips() }
        }
        if s.thickness != laidOutThickness { layoutStrips() }
        wake()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        linkRate = -1
        guard window != nil else { return }
        layoutStrips()
        let l = displayLink(target: self, selector: #selector(step(_:)))
        // .common keeps the light moving while a menu is open (menus run the event-tracking mode).
        l.add(to: .main, forMode: .common)
        link = l
        setRate(60)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutStrips()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutStrips()
    }

    /// Sizes the four strips to the deepest the light can reach (a beat-swollen border), plus the
    /// notch on the top strip.
    private func layoutStrips() {
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        laidOutThickness = Settings.shared.thickness
        let scale = quality.renderScale(backing: window?.backingScaleFactor ?? 2)
        renderScale = scale
        // Matches the shader: th ≤ 1.35 × thickness, nothing drawn beyond 1.35 × th.
        let depth = min(ceil(CGFloat(laidOutThickness) * 1.35 * 1.35) + 2, min(W, H) / 2)
        let notchDepth = window?.screen?.safeAreaInsets.top ?? 0
        let top = min(depth + notchDepth, H / 2)
        let sideHeight = max(H - top - depth, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in strips.indices {
            let r: CGRect
            switch strips[i].edge {
            case .top: r = CGRect(x: 0, y: 0, width: W, height: top)
            case .bottom: r = CGRect(x: 0, y: H - depth, width: W, height: depth)
            case .left: r = CGRect(x: 0, y: top, width: depth, height: sideHeight)
            case .right: r = CGRect(x: W - depth, y: top, width: depth, height: sideHeight)
            }
            strips[i].rect = r
            let l = strips[i].layer
            // Layer coordinates have a bottom-left origin.
            l.frame = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
            l.contentsScale = scale
            l.drawableSize = CGSize(width: max(r.width * scale, 1), height: max(r.height * scale, 1))
            l.isHidden = r.width < 1 || r.height < 1
        }
        CATransaction.commit()
        wake()
    }

    func setVisibleOnScreen(_ visible: Bool) {
        visibleOnScreen = visible
        if visible { wake() } else { link?.isPaused = true }
    }

    /// Something changed (settings, palette, display): make sure at least a few frames render.
    func wake() {
        guard visibleOnScreen else { return }
        setRate(60)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private func setRate(_ rate: Float) {
        guard let link else { return }
        if rate <= 0 {
            link.isPaused = true
            linkRate = 0
            return
        }
        link.isPaused = !visibleOnScreen
        guard rate != linkRate else { return }
        linkRate = rate
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
    }

    @objc private func step(_ link: CADisplayLink) {
        let engine = LightEngine.shared
        let f = engine.frame(at: CACurrentMediaTime())
        draw(f)
        setRate(engine.wantedFrameRate)
    }

    /// Notch rectangle in screen pixels (top-left origin), or zero.
    private func notchRect(scale: CGFloat) -> SIMD4<Float> {
        guard let screen = window?.screen, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return .zero }
        let x = (left.maxX - screen.frame.minX) * scale
        let w = (right.minX - left.maxX) * scale
        let h = screen.safeAreaInsets.top * scale
        guard w > 0 else { return .zero }
        return SIMD4(Float(x), 0, Float(w), Float(h))
    }

    /// The shader's `Uniforms`: 20 floats, float4 notch at byte 80, six float4 colours at 96,
    /// 24 spectrum bands at 192, then drop and eqAmount (304 bytes in all).
    private func uniforms(for f: LightFrame, scale: CGFloat) -> [Float] {
        var u = [Float](repeating: 0, count: 76)
        u[0] = Float(bounds.width * scale)
        u[1] = Float(bounds.height * scale)
        u[6] = f.thickness * Float(scale)
        u[7] = Float((screenIsBuiltIn ? 11 : 0) * scale)
        u[8] = f.intensity
        u[9] = f.phase
        u[10] = f.clock
        u[11] = f.pulse
        u[12] = f.level
        u[13] = f.travel
        let headroom = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        u[14] = hdr ? Float(min(max(headroom, 1), 4)) : 1
        u[15] = hdr ? 1 : 0
        u[16] = Float(min(f.colors.count, 6))
        u[17] = f.streaks
        u[18] = f.accent
        u[19] = quality.level
        let notch = notchRect(scale: scale)
        for i in 0..<4 { u[20 + i] = notch[i] }
        for (i, c) in f.colors.prefix(6).enumerated() {
            u[24 + i * 4] = c.x
            u[25 + i * 4] = c.y
            u[26 + i * 4] = c.z
            u[27 + i * 4] = 1
        }
        for (i, v) in f.eq.prefix(24).enumerated() { u[48 + i] = v }
        u[72] = f.drop
        u[73] = f.eqAmount
        return u
    }

    private func draw(_ f: LightFrame) {
        guard let cmd = GlowRenderer.shared.queue.makeCommandBuffer() else { return }
        let scale = renderScale
        var u = uniforms(for: f, scale: scale)
        var drawables: [CAMetalDrawable] = []

        for strip in strips where !strip.layer.isHidden {
            let l = strip.layer
            guard let drawable = l.nextDrawable(), let pipeline = GlowRenderer.shared.pipeline(for: l.pixelFormat) else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { continue }
            if f.intensity > 0.0005 {
                u[2] = Float(strip.rect.minX * scale)
                u[3] = Float(strip.rect.minY * scale)
                u[4] = Float(l.drawableSize.width)
                u[5] = Float(l.drawableSize.height)
                enc.setRenderPipelineState(pipeline)
                u.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
            drawables.append(drawable)
        }
        for d in drawables { cmd.present(d) }
        cmd.commit()
    }
}

/// Borderless, transparent, click-through window covering one display, Dock included. It sits just
/// below the menu bar, which is transparent on macOS 26, so the light shows behind the menu bar
/// (and around the notch) while menu titles and icons stay readable on top.
private let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)

@MainActor
final class OverlayWindow: NSWindow {
    let glow: GlowView

    init(screen: NSScreen) {
        glow = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size),
                        builtIn: CGDisplayIsBuiltin(screen.displayID) != 0)
        // No `screen:` argument, so contentRect is in global coordinates.
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        canHide = false   // the Dock click hides the app to return focus; the light must stay
        animationBehavior = .none
        level = overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        sharingType = Settings.shared.hideFromCapture ? .none : .readOnly
        contentView = glow
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keeps one overlay window per selected display and rebuilds them when displays change.
@MainActor
final class OverlayController {
    private var windows: [CGDirectDisplayID: OverlayWindow] = [:]
    private var lastScope = Settings.shared.displays
    private var teardownWork: DispatchWorkItem?
    private var locked = false

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        nc.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        nc.addObserver(forName: SpotifyMonitor.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeAll() }
        }
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? OverlayWindow else { return }
                w.glow.setVisibleOnScreen(w.occlusionState.contains(.visible))
            }
        }
        // Entering or leaving a fullscreen Space can drop us behind; re-assert right away and once
        // the transition animation has settled.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reassert()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.reassert() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        // Nothing to see on the lock screen: stop drawing until unlocked.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        }
        rebuild()
    }

    private func setLocked(_ value: Bool) {
        locked = value
        for w in windows.values { w.glow.setVisibleOnScreen(!value && w.occlusionState.contains(.visible)) }
    }

    private func wantedScreens() -> [NSScreen] {
        // NSScreen.screens[0] is always the display with the menu bar.
        Settings.shared.displays == .main ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
    }

    private func settingsChanged() {
        if Settings.shared.enabled {
            teardownWork?.cancel()
            teardownWork = nil
            if windows.isEmpty { rebuild() }
        } else if !windows.isEmpty && teardownWork == nil {
            // Let the light fade out, then remove the windows entirely: off means nothing drawn.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !Settings.shared.enabled else { return }
                    self.teardownWork = nil
                    self.removeAll()
                }
            }
            teardownWork = work
            // The fade has a 0.3 s time constant; remove the windows only once it has fully finished.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
        }
        if Settings.shared.displays != lastScope {
            lastScope = Settings.shared.displays
            rebuild()
        }
        let sharing: NSWindow.SharingType = Settings.shared.hideFromCapture ? .none : .readOnly
        for w in windows.values {
            if w.sharingType != sharing { w.sharingType = sharing }
            w.glow.applySettings()
        }
    }

    private func wakeAll() {
        for w in windows.values { w.glow.wake() }
    }

    private func reassert() {
        for w in windows.values {
            w.level = overlayLevel
            w.orderFrontRegardless()
        }
    }

    private func removeAll() {
        for w in windows.values {
            w.glow.stop()
            w.orderOut(nil)
            w.contentView = nil
        }
        windows.removeAll()
    }

    func rebuild() {
        guard Settings.shared.enabled else { removeAll(); return }
        let screens = wantedScreens()
        let wanted = Set(screens.map(\.displayID))
        for (id, w) in windows where !wanted.contains(id) {
            w.glow.stop()
            w.orderOut(nil)
            w.contentView = nil
            windows[id] = nil
        }
        for screen in screens {
            if let w = windows[screen.displayID] {
                if w.frame != screen.frame { w.setFrame(screen.frame, display: true) }
                w.glow.wake()
            } else {
                let w = OverlayWindow(screen: screen)
                windows[screen.displayID] = w
                w.orderFrontRegardless()
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
