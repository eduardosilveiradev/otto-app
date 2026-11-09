import ImageIO
import Metal
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// Pip faces, drawn from solid, colour and pose by the shader in Face.metal, never from shipped art.
// Small faces are rendered once to cached frames and animated by Core Animation, so a long list costs
// the main thread nothing. Large ones render live, for the eye transitions. Motion values come from
// design/multi-otto/style.css, the tween from faces/src/live.js.

enum FaceState: String, Codable, CaseIterable, Sendable {
    case rest, working, needs, asleep, gpt, failed
    init(from decoder: Decoder) throws {
        self = FaceState(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .rest   // a newer server's state
    }
    var blinks: Bool { self == .rest || self == .working || self == .failed }
}

enum FaceSolid: String, Codable, CaseIterable, Sendable {
    case sphere, roundedCube = "rounded-cube", capsule, gumdrop, gem, drum, diamond
    init(from decoder: Decoder) throws {
        self = FaceSolid(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .gem   // a newer server's solid
    }
    /// face.js FACE_SOLIDS: shape, then the pose and eye offset that solid looks right in.
    fileprivate var geometry: (shape: Int32, pitch: Float, yaw: Float, roll: Float, eyes: SIMD2<Float>) {
        switch self {
        case .sphere: (0, 0.05, -0.10, 0, [0, 0])
        case .roundedCube: (1, 0.1, -0.12, 0.02, [0, 0])
        case .capsule: (2, 0.14, -0.30, -0.16, [0, -0.02])
        case .gumdrop: (3, 0.16, -0.20, 0, [0, -0.16])
        case .gem: (4, 0.18, -0.2, 0.08, [0, 0])
        case .diamond: (6, 0.08, -0.16, 0, [0, 0.12])
        case .drum: (5, 0.34, -0.24, 0, [0, -0.02])
        }
    }
}

struct FaceLook: Hashable, Sendable {
    var solid: FaceSolid
    /// #RRGGBB, from the server.
    var colour: String
    var state: FaceState

    static let otto = FaceLook(solid: .sphere, colour: "#FF7C1A", state: .rest)
    func with(_ state: FaceState) -> FaceLook { var l = self; l.state = state; return l }

    /// 0–1 sRGB channels.
    var rgb: SIMD3<Float> {
        let hex = UInt32(colour.drop { $0 == "#" }, radix: 16) ?? 0xFF7C1A
        return SIMD3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255)) / 255
    }
    /// A touch lighter than the solid: the sleep z and the handoff arc.
    var tint: UIColor {
        let c = rgb + (SIMD3<Float>(repeating: 1) - rgb) * 0.08
        return UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }
}

/// Mirrors the struct in Face.metal.
struct FaceUniforms {
    var shape: Int32 = 0, shape2: Int32 = 0, arc: Int32 = 0, n: Int32 = 4
    var albedo = SIMD3<Float>(), pose = SIMD3<Float>()
    var e0 = SIMD4<Float>(), e1 = SIMD4<Float>()
    var er = SIMD2<Float>(), eo = SIMD2<Float>()
    var b: Float = 0, morph: Float = 0, res: Float = 0, bend: Float = 1

    init(_ look: FaceLook, b: Float = 0) {
        let g = look.solid.geometry
        let s = Self.state(look.state)
        let nudge = look.solid == .roundedCube ? s.nudge * 0.4 : s.nudge   // a flat face foreshortens the eyes
        shape = g.shape; shape2 = g.shape
        albedo = SIMD3(pow(look.rgb.x, 2.2), pow(look.rgb.y, 2.2), pow(look.rgb.z, 2.2))
        pose = SIMD3(g.pitch, g.yaw, g.roll) + nudge
        e0 = s.e0; e1 = s.e1; er = s.er; arc = s.arc; eo = g.eyes
        self.b = b
    }

    /// face.js FACE_STATES, in the same old 100-unit face box.
    private static func state(_ s: FaceState) -> (e0: SIMD4<Float>, e1: SIMD4<Float>, er: SIMD2<Float>, arc: Int32, nudge: SIMD3<Float>) {
        func eye(_ x: Float, _ y: Float, _ tilt: Float, _ half: Float) -> SIMD4<Float> {
            SIMD4((x - 50) / 50, (54 - y) / 50, tilt * .pi / 180, half)
        }
        switch s {
        case .rest: return (eye(37, 51, 0, 0.09), eye(63, 51, 0, 0.09), [0.1, 0.1], 0, [0, 0, 0])
        case .working: return (eye(39, 45, -8, 0.08), eye(63, 45, -8, 0.08), [0.1, 0.1], 0, [0.1, 0.1, 0])
        case .needs: return (eye(36, 51, 0, 0.17), eye(64, 51, 0, 0.17), [0.12, 0.12], 0, [-0.1, 0, 0])
        case .asleep: return (eye(37, 52, 0, 0.14), eye(63, 52, 0, 0.14), [0.05, 0.05], -1, [0.14, 0, -0.1])
        case .gpt: return (eye(37, 53, 0, 0.14), eye(63, 53, 0, 0.14), [0.058, 0.058], 1, [0, -0.14, 0.05])
        case .failed: return (eye(37, 60, -32, 0.09), eye(63, 60, 32, 0.09), [0.1, 0.1], 0, [0.2, 0, 0])
        }
    }
}

// MARK: - Rendering

/// The Metal side, shared by the cached frames and the live layers.
enum FaceGPU {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = device.makeDefaultLibrary() else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "faceVertex")
        d.fragmentFunction = library.makeFunction(name: "faceFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: d)
    }()

    static func encode(_ uniforms: FaceUniforms, into texture: MTLTexture, on buffer: MTLCommandBuffer) {
        guard let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let e = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        e.setRenderPipelineState(pipeline)
        e.setFragmentBytes(&u, length: MemoryLayout<FaceUniforms>.stride, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    /// One frame as a premultiplied image. Private texture and a blit: the simulator has no shared textures.
    static func image(_ look: FaceLook, b: Float, px: Int, samples: Int32 = 5) -> CGImage? {
        guard let device, let queue else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: px, height: px, mipmapped: false)
        d.usage = .renderTarget; d.storageMode = .private
        let length = px * px * 4
        guard let texture = device.makeTexture(descriptor: d),
              let readback = device.makeBuffer(length: length, options: .storageModeShared),
              let buffer = queue.makeCommandBuffer() else { return nil }
        var u = FaceUniforms(look, b: b)
        u.n = samples; u.res = Float(px)
        encode(u, into: texture, on: buffer)
        guard let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: px, height: px, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: px * 4, destinationBytesPerImage: length)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        // iOS refuses GPU work from the background, where stay-awake keeps the app running, and can cut off
        // a long render. Either leaves the texture clear: a transparent face that must never be kept.
        guard buffer.status == .completed else { return nil }
        let data = Data(bytes: readback.contents(), count: length)
        return data.withUnsafeBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}

/// Everything a cached face shows: its still, the three blink frames when it blinks, and the
/// silhouette a group picture cuts around it.
final class FaceFrames: @unchecked Sendable {   // immutable after init
    let rest: CGImage
    let blink: [CGImage]
    let halo: CGImage?
    init(rest: CGImage, blink: [CGImage], halo: CGImage?) { self.rest = rest; self.blink = blink; self.halo = halo }
}

enum FaceCache {
    private static let memory = NSCache<NSString, FaceFrames>()
    private static let work = DispatchQueue(label: "otto.faces", qos: .userInitiated)
    /// Bump when the shader or a pose changes, so old renders on disk aren't used.
    private static let version = 2   // 2: drops the blank faces version 1 could save
    private static let folder: URL = {
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "faces-\(version - 1)"))
        let dir = URL.cachesDirectory.appending(path: "faces-\(version)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func key(_ look: FaceLook, _ px: Int) -> String { "\(look.solid.rawValue)-\(look.colour.dropFirst())-\(look.state.rawValue)-\(px)" }

    static func cached(_ look: FaceLook, px: Int) -> FaceFrames? { memory.object(forKey: key(look, px) as NSString) }

    /// Rendered once ever: memory, then disk, then the GPU, off the main thread.
    static func load(_ look: FaceLook, px: Int, done: @escaping @MainActor (FaceFrames) -> Void) {
        work.async {
            let frames = cached(look, px: px) ?? render(look, px: px)
            guard let frames else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(frames) } }
        }
    }

    private static func render(_ look: FaceLook, px: Int) -> FaceFrames? {
        let k = key(look, px)
        func frame(_ name: String, b: Float) -> CGImage? {
            let url = folder.appending(path: "\(k)-\(name).png")
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) { return img }
            // Cut off at full quality: a lighter render for this run, and the full one next launch.
            guard let img = FaceGPU.image(look, b: b, px: px) else { return FaceGPU.image(look, b: b, px: px, samples: 2) }
            if let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(out, img, nil)
                CGImageDestinationFinalize(out)
            }
            return img
        }
        guard let rest = frame("rest", b: 0) else { return nil }
        // render.html's three blink frames.
        let blink = look.state.blinks ? [frame("b1", b: 0.5), frame("b2", b: 0.85), frame("b3", b: 1)].compactMap { $0 } : []
        let frames = FaceFrames(rest: rest, blink: blink, halo: halo(rest, px: px))
        memory.setObject(frames, forKey: k as NSString)
        return frames
    }

    /// style.css `.cl .av img`: the solid drawn at four hard offsets, a ring that follows its shape.
    private static func halo(_ image: CGImage, px: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let r = CGFloat(px) * 0.035, box = CGRect(x: 0, y: 0, width: px, height: px)
        for (x, y) in [(r, 0), (-r, 0), (0, r), (0, -r)] as [(CGFloat, CGFloat)] { ctx.draw(image, in: box.offsetBy(dx: x, dy: y)) }
        return ctx.makeImage()
    }
}

// MARK: - The live layer

/// A large face drawn as it animates: blinks, and capsule eyes closing to a flat line that bends into an arc.
@MainActor final class LiveFaceLayer: CAMetalLayer {
    private struct Pose { var u: FaceUniforms; var close: Float = 0 }
    private var from: Pose?, to: Pose?
    private var started: CFTimeInterval = -1e9, blinkAt: CFTimeInterval = -1e9
    private var link: CADisplayLink?
    private var inFlight = false, redraw = false, lastLook: FaceLook?
    /// Fewer samples in motion; a slower GPU trades edges for frame rate. Full quality once settled.
    private var motionSamples: Int32 = 2
    private var blinkTimer: Task<Void, Never>?
    private static let tweenTime: CFTimeInterval = 0.34, blinkTime: CFTimeInterval = 0.24
    var calm = false

    override init() { super.init(); setUp() }
    override init(layer: Any) { super.init(layer: layer); setUp() }
    required init?(coder: NSCoder) { super.init(coder: coder); setUp() }

    private func setUp() {
        device = FaceGPU.device
        pixelFormat = .bgra8Unorm
        isOpaque = false
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    func show(_ look: FaceLook) {
        guard look != lastLook else { return }
        lastLook = look
        let target = Pose(u: FaceUniforms(look))
        guard to != nil else { from = target; to = target; draw(); return }
        var carried = pose(at: CACurrentMediaTime()).0   // carry on from what's on screen
        carried.u.shape = carried.u.morph > 0.5 ? carried.u.shape2 : carried.u.shape
        from = carried
        to = target
        started = calm ? -1e9 : CACurrentMediaTime()
        run()
        if calm { draw() }
    }

    /// Draws one settled frame, and keeps a blink coming while it's on screen.
    func onScreen(_ on: Bool) {
        blinkTimer?.cancel()
        link?.invalidate(); link = nil
        guard on else { return }
        draw()
        guard !calm else { return }
        blinkTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.6...5.4)))
                guard !Task.isCancelled, let self, self.lastLook?.state != .needs, self.to?.u.arc == 0 else { continue }
                self.blinkAt = CACurrentMediaTime()
                self.run()
            }
        }
    }

    private func run() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() { draw() }

    private func pose(at now: CFTimeInterval) -> (Pose, busy: Bool) {
        guard let from, let to else { return (Pose(u: FaceUniforms(.otto)), false) }
        func lerp<V: SIMD>(_ a: V, _ b: V, _ k: Float) -> V where V.Scalar == Float { a + (b - a) * k }
        let p = Float(min(1, (now - started) / Self.tweenTime)), k = 1 - pow(1 - p, 3)
        let blink = Float((now - blinkAt) / Self.blinkTime)
        var v = to.u
        v.albedo = lerp(from.u.albedo, to.u.albedo, k); v.eo = lerp(from.u.eo, to.u.eo, k); v.pose = lerp(from.u.pose, to.u.pose, k)
        v.shape = from.u.shape; v.shape2 = to.u.shape
        v.morph = from.u.shape == to.u.shape ? 0 : k
        var close: Float
        if from.u.arc == to.u.arc {
            v.e0 = lerp(from.u.e0, to.u.e0, k); v.e1 = lerp(from.u.e1, to.u.e1, k); v.er = lerp(from.u.er, to.u.er, k); v.arc = to.u.arc
            close = from.close * (1 - k)
            v.bend = from.u.bend + (1 - from.u.bend) * k
        } else {
            // The eye goes through a flat line: a capsule closes into it, an arc straightens into it.
            let s = p * p * (3 - 2 * p), out = s < 0.5, q = out ? s * 2 : s * 2 - 1
            let side = out ? from : to, t = out ? q : 1 - q, isArc = side.u.arc != 0
            let hasCapsule = from.u.arc == 0 || to.u.arc == 0
            let capsule = from.u.arc == 0 ? from : to.u.arc == 0 ? to : from
            func line(_ e: SIMD4<Float>, _ r: Float) -> (w: Float, r: Float) {   // sized to match a fully closed capsule exactly
                guard hasCapsule else { return (e.w, r) }
                let h = (e.w + r) * 0.2
                return (r * 1.25 - h, h)
            }
            func eye(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ e: SIMD4<Float>, _ cap: SIMD4<Float>, _ r: Float) -> SIMD4<Float> {
                let xy = lerp(SIMD2(a.x, a.y), SIMD2(b.x, b.y), s), w = line(cap, r).w
                return SIMD4(xy.x, xy.y, e.z, isArc ? e.w + (w - e.w) * t : e.w)
            }
            v.e0 = eye(from.u.e0, to.u.e0, side.u.e0, capsule.u.e0, capsule.u.er.x)
            v.e1 = eye(from.u.e1, to.u.e1, side.u.e1, capsule.u.e1, capsule.u.er.y)
            let lr = (line(capsule.u.e0, capsule.u.er.x).r, line(capsule.u.e1, capsule.u.er.y).r)
            v.er = isArc ? SIMD2(side.u.er.x + (lr.0 - side.u.er.x) * t, side.u.er.y + (lr.1 - side.u.er.y) * t) : side.u.er
            v.arc = side.u.arc
            close = isArc ? 0 : out ? from.close + (1 - from.close) * q : 1 - q
            v.bend = !isArc ? 1 : out ? from.u.bend * (1 - q) : q
        }
        let blinking = blink >= 0 && blink < 1
        v.b = max(close, blinking && v.arc == 0 ? sin(.pi * blink) : 0)
        return (Pose(u: v, close: close), p < 1 || blinking)
    }

    private func draw() {
        if inFlight { redraw = true; return }   // the settled frame must not be the one dropped
        redraw = false
        guard to != nil, drawableSize.width > 0, let drawable = nextDrawable(),
              let buffer = FaceGPU.queue?.makeCommandBuffer() else { return }
        let (p, busy) = pose(at: CACurrentMediaTime())
        var u = p.u
        u.n = busy ? motionSamples : 4
        u.res = Float(drawableSize.width)
        FaceGPU.encode(u, into: drawable.texture, on: buffer)
        buffer.present(drawable)
        inFlight = true
        let start = CACurrentMediaTime()
        buffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight = false
                    if busy, CACurrentMediaTime() - start > 0.024 { self.motionSamples = 1 }
                    if self.redraw { self.draw() }
                }
            }
        }
        buffer.commit()
        if !busy { link?.invalidate(); link = nil }
    }
}

// MARK: - The view

/// A face at any size, with the mockup's motion. Cached frames unless `live`.
final class FaceUIView: UIView {
    private let driftLayer = CALayer(), wiggleLayer = CALayer(), bodyLayer = CALayer(), imageLayer = CALayer(), ringLayer = CALayer(), ringMask = CALayer(), badgeLayer = CALayer()
    private var liveLayer: LiveFaceLayer?
    private var shown: (look: FaceLook, size: CGFloat, live: Bool, drift: Bool)?
    private var frames: FaceFrames?
    /// Fixed once, so a face doesn't jump to a new moment in its blink when it's reconfigured.
    private let phase = Double.random(in: 0...5)
    var ring: UIColor = .systemBackground { didSet { if ring != oldValue { paint() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(driftLayer)
        driftLayer.addSublayer(wiggleLayer)
        wiggleLayer.addSublayer(bodyLayer)
        wiggleLayer.addSublayer(badgeLayer)
        bodyLayer.addSublayer(ringLayer)
        bodyLayer.addSublayer(imageLayer)
        ringLayer.mask = ringMask
        NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(retryBlank), name: UIApplication.didBecomeActiveNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: FaceUIView, _: UITraitCollection) in v.buildBadge(); v.paint() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var calm: Bool { UIAccessibility.isReduceMotionEnabled }
    private var scale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    func configure(look: FaceLook, size: CGFloat, live: Bool, drift: Bool, ringed: Bool) {
        ringLayer.isHidden = !ringed
        guard shown?.look != look || shown?.size != size || shown?.live != live || shown?.drift != drift else { return }
        let sameFace = shown?.live == true && live && shown?.size == size
        shown = (look, size, live, drift)
        let box = CGRect(x: 0, y: 0, width: size, height: size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [driftLayer, wiggleLayer, badgeLayer, imageLayer, ringLayer, ringMask] { l.frame = box }
        bodyLayer.bounds = box
        bodyLayer.anchorPoint = CGPoint(x: 0.5, y: look.state == .asleep ? 0.98 : 0.5)   // breathes from where it sits
        bodyLayer.position = CGPoint(x: size / 2, y: size * bodyLayer.anchorPoint.y)
        if live { startLive(look, size: size, sameFace: sameFace) } else { stopLive(); loadFrames(look, size: size) }
        buildBadge()
        CATransaction.commit()
        restart()
    }

    private func startLive(_ look: FaceLook, size: CGFloat, sameFace: Bool) {
        let l = liveLayer ?? {
            let l = LiveFaceLayer()
            bodyLayer.addSublayer(l)
            liveLayer = l
            return l
        }()
        imageLayer.isHidden = true
        l.calm = calm
        l.frame = CGRect(x: 0, y: 0, width: size, height: size)
        l.contentsScale = scale
        l.drawableSize = CGSize(width: size * scale, height: size * scale)
        l.show(look)
        if !sameFace { l.onScreen(window != nil) }
    }

    private func stopLive() {
        liveLayer?.onScreen(false)
        liveLayer?.removeFromSuperlayer()
        liveLayer = nil
        imageLayer.isHidden = false
    }

    /// A face asked for while the app was in the background couldn't be drawn; now it can.
    @objc private func retryBlank() {
        if frames == nil, let s = shown, !s.live { loadFrames(s.look, size: s.size) }
    }

    private func loadFrames(_ look: FaceLook, size: CGFloat) {
        let px = max(1, Int((size * scale).rounded()))
        if let f = FaceCache.cached(look, px: px) { apply(f); return }
        frames = nil
        FaceCache.load(look, px: px) { [weak self] f in
            guard let self, self.shown?.look == look, self.shown?.size == size else { return }
            self.apply(f)
        }
    }

    private func apply(_ f: FaceFrames) {
        frames = f
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = f.rest
        ringMask.contents = f.halo
        CATransaction.commit()
        animateBlink()
    }

    private func paint() {
        ringLayer.backgroundColor = ring.resolvedColor(with: traitCollection).cgColor
        buildBadge()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restart() }
        liveLayer?.onScreen(window != nil)
    }

    override func layoutSubviews() { super.layoutSubviews(); paint() }

    // MARK: Motion

    @objc private func restart() {
        guard let shown else { return }
        for l in [driftLayer, wiggleLayer, bodyLayer] { l.removeAllAnimations() }
        animateBlink()
        guard !calm else { return }
        if shown.drift { driftLayer.add(alternating("transform.translation", to: CGSize(width: 1.5, height: -2), 5, phase), forKey: "drift") }
        switch shown.look.state {
        case .working: bodyLayer.add(alternating("transform.translation.y", to: -shown.size * 0.03, 0.7, phase), forKey: "bob")
        case .asleep:
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.toValue = 1.035; a.duration = 1.7; a.autoreverses = true
            bodyLayer.add(looped(a, phase), forKey: "breathe")
        case .needs:
            let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let deg = CGFloat.pi / 180
            a.values = [0, 0, -5 * deg, 4 * deg, -2 * deg, 0]
            a.keyTimes = [0, 0.82, 0.86, 0.91, 0.95, 1]
            a.duration = 4.5
            wiggleLayer.add(looped(a, phase), forKey: "wiggle")
        default: break
        }
    }

    private func animateBlink() {
        imageLayer.removeAnimation(forKey: "blink")
        guard let f = frames, f.blink.count == 3, !calm, shown?.live == false else { return }
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = [f.rest, f.blink[0], f.blink[1], f.blink[2], f.blink[1], f.blink[0], f.rest]
        a.keyTimes = [0, 0.94, 0.95, 0.96, 0.97, 0.98, 0.99, 1]
        a.calculationMode = .discrete
        a.duration = 5.2
        imageLayer.add(looped(a, phase), forKey: "blink")
    }

    private func looped<A: CAAnimation>(_ a: A, _ offset: Double) -> A {
        a.repeatCount = .infinity
        a.timeOffset = offset
        a.isRemovedOnCompletion = false   // survives the app going to the background
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if a is CAKeyframeAnimation { a.timingFunction = nil }
        return a
    }

    private func alternating(_ key: String, to: Any, _ duration: Double, _ offset: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.toValue = to
        a.duration = duration
        a.autoreverses = true
        return looped(a, offset)
    }

    // MARK: Badges (style.css, in the face's 100-unit box)

    private func buildBadge() {
        guard let shown else { return }
        badgeLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let u = shown.size / 100
        func scaled(_ p: CGPath) -> CGPath { var t = CGAffineTransform(scaleX: u, y: u); return p.copy(using: &t) ?? p }
        func shape(_ p: CGPath, fill: UIColor?, stroke: UIColor? = nil, width: CGFloat = 0) -> CAShapeLayer {
            let s = CAShapeLayer()
            s.path = scaled(p)
            s.fillColor = (fill?.resolvedColor(with: traitCollection) ?? .clear).cgColor
            s.strokeColor = (stroke?.resolvedColor(with: traitCollection) ?? .clear).cgColor
            s.lineWidth = width * u
            s.lineCap = .round; s.lineJoin = .round
            badgeLayer.addSublayer(s)
            return s
        }
        func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil) }
        let dark = traitCollection.userInterfaceStyle == .dark
        switch shown.look.state {
        case .working:
            let pill = CGPath(roundedRect: CGRect(x: 60, y: -6, width: 40, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil)
            _ = shape(pill, fill: dark ? UIColor(rgb: 0x3A3A3C) : .white, stroke: UIColor.black.withAlphaComponent(0.08), width: 1)
            for (i, x) in [71, 80, 89].map(CGFloat.init).enumerated() {
                let dot = shape(disc(x, 5, 2.7), fill: dark ? UIColor(rgb: 0xD1D1D6) : UIColor(rgb: 0x8A8A90))
                if !calm { dot.add(Self.dotPulse(delay: Double(i) * 0.18), forKey: "dot") } else { dot.opacity = 0.6 }
            }
        case .needs:
            _ = shape(disc(86, 15, 13), fill: ring, stroke: ring, width: 8)
            _ = shape(disc(86, 15, 13), fill: UIColor(rgb: 0xFF6A00))
            _ = shape(CGPath(roundedRect: CGRect(x: 84.4, y: 7.5, width: 3.2, height: 9), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil), fill: .white)
            _ = shape(disc(86, 21.5, 1.9), fill: .white)
        case .gpt:
            _ = shape(disc(86, 86, 13), fill: ring, stroke: ring, width: 8)
            _ = shape(disc(86, 86, 13), fill: UIColor(rgb: 0x46526B))
            let swap = CGMutablePath()
            swap.addLines(between: [CGPoint(x: 79.5, y: 83.5), CGPoint(x: 91.5, y: 83.5), CGPoint(x: 88.5, y: 80.5)])
            swap.addLines(between: [CGPoint(x: 92.5, y: 88.5), CGPoint(x: 80.5, y: 88.5), CGPoint(x: 83.5, y: 91.5)])
            _ = shape(swap, fill: nil, stroke: .white, width: 1.9)
        case .asleep:
            let z = Self.zPath()
            for i in 0..<3 {
                let l = shape(z, fill: shown.look.tint)
                l.opacity = 0
                if calm {
                    if i == 0 { l.opacity = 0.7 }
                } else {
                    l.add(Self.zee(delay: Double(i) * 1.05, unit: u), forKey: "zee")
                }
            }
        default: break
        }
    }

    /// style.css @keyframes dots.
    static func dotPulse(delay: Double, duration: Double = 1.1) -> CAAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0.3, 1, 0.3, 0.3]
        a.keyTimes = [0, 0.3, 0.6, 1]
        a.duration = duration
        a.repeatCount = .infinity
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        a.isRemovedOnCompletion = false
        return a
    }

    /// style.css @keyframes zee.
    private static func zee(delay: Double, unit: CGFloat) -> CAAnimation {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]; fade.keyTimes = [0, 0.25, 1]
        let move = CABasicAnimation(keyPath: "transform.translation")
        move.fromValue = CGSize(width: 0, height: 4 * unit); move.toValue = CGSize(width: 8 * unit, height: -16 * unit)
        let g = CAAnimationGroup()
        g.animations = [fade, move]
        g.duration = 3.2
        g.repeatCount = .infinity
        g.beginTime = CACurrentMediaTime() + delay
        g.fillMode = .backwards
        g.isRemovedOnCompletion = false
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        return g
    }

    /// The letter as a path, so it stays crisp at every size: 800-weight rounded, 24 units, baseline at (74, 22).
    private static func zPath() -> CGPath {
        let base = UIFont.systemFont(ofSize: 24, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 24) } ?? base
        var ch: UniChar = 122, glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 74, ty: 22)   // glyphs are y-up
        return CTFontCreatePathForGlyph(font, glyph, &t) ?? CGMutablePath()
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// One face. `ringed` cuts the group picture's outline around it; `ring` is the colour behind it.
struct FaceView: UIViewRepresentable {
    let look: FaceLook
    let size: CGFloat
    var live = false
    var drift = false
    var ringed = false
    var ring: UIColor = .systemBackground

    func makeUIView(context: Context) -> FaceUIView { FaceUIView() }
    func updateUIView(_ v: FaceUIView, context: Context) {
        v.ring = ring
        v.configure(look: look, size: size, live: live, drift: drift, ringed: ringed)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FaceUIView, context: Context) -> CGSize? { CGSize(width: size, height: size) }
}

/// A group's picture: faces blobbed in a loose cluster, never a row, Otto largest and on top.
struct GroupFace: View {
    let id: String
    let members: [FaceLook]
    /// Otto is always a member; the rest are the first two pips.
    let otto: FaceLook?
    let size: CGFloat
    var ring: UIColor = .systemBackground

    /// style.css's three clusters, per face: scale, x, y. Picked by the group's id so a picture never reshuffles.
    private static let clusters: [[(k: CGFloat, x: CGFloat, y: CGFloat)]] = [
        [(0.46, 0, 0.46), (0.44, 0.56, 0.52), (0.66, 0.18, 0)],
        [(0.46, 0.52, 0), (0.44, 0, 0.20), (0.60, 0.22, 0.40)],
        [(0.42, 0.06, 0), (0.46, 0.54, 0.12), (0.62, 0.14, 0.38)],
    ]

    var body: some View {
        let cluster = Self.clusters[id.utf8.reduce(0) { ($0 + Int($1)) % 3 }]
        let pips = Array(members.prefix(2))
        ZStack(alignment: .topLeading) {
            ForEach(Array(pips.enumerated()), id: \.offset) { i, look in slot(look, cluster[i]) }
            if let otto { slot(otto, cluster[2]) }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func slot(_ look: FaceLook, _ s: (k: CGFloat, x: CGFloat, y: CGFloat)) -> some View {
        FaceView(look: look, size: (size * s.k).rounded(), drift: true, ringed: true, ring: ring)
            .frame(width: (size * s.k).rounded(), height: (size * s.k).rounded())
            .offset(x: size * s.x, y: size * s.y)
    }
}

/// The three pulsing dots beside an activity line.
struct TypingDots: UIViewRepresentable {
    var dot: CGFloat = 7
    var gap: CGFloat = 4

    final class Dots: UIView {
        var dot: CGFloat = 7, gap: CGFloat = 4
        private var layers: [CALayer] = []
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            layers.forEach { $0.removeFromSuperlayer() }
            layers = (0..<3).map { i in
                let l = CALayer()
                l.frame = CGRect(x: CGFloat(i) * (dot + gap), y: 0, width: dot, height: dot)
                l.cornerRadius = dot / 2
                l.backgroundColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
                if UIAccessibility.isReduceMotionEnabled { l.opacity = 0.6 } else { l.add(FaceUIView.dotPulse(delay: Double(i) * 0.18), forKey: "dot") }
                layer.addSublayer(l)
                return l
            }
        }
    }

    func makeUIView(context: Context) -> Dots { let v = Dots(); v.dot = dot; v.gap = gap; return v }
    func updateUIView(_ v: Dots, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Dots, context: Context) -> CGSize? { CGSize(width: dot * 3 + gap * 2, height: dot) }
}
