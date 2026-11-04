import UIKit

/// The slide-to-type trail, drawn like iOS's: a smooth comet that is full width and bright at
/// the finger and tapers and fades behind it, so only the last moment of the stroke shows.
/// A display link keeps the tail shrinking while the finger rests and after it lifts.
final class SwipeTrail: UIView {
    // ponytail: fixed comet length and width; tune here if the trail feels long or heavy on device.
    private static let life: CFTimeInterval = 0.32
    private static let width: CGFloat = 6

    var color: UIColor = .white
    private var points: [(p: CGPoint, t: CFTimeInterval)] = []
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    func add(_ p: CGPoint) {
        // Ignore jitter: points closer than 2pt only add kinks.
        if let last = points.last, last.p.distance(to: p) < 2 { return }
        points.append((p, CACurrentMediaTime()))
        start()
    }

    /// The finger lifted: let what's left fade out on its own.
    func end() { start() }

    /// A trail that stays put, for screenshots.
    func freeze(_ path: [CGPoint]) {
        link?.invalidate(); link = nil
        let now = CACurrentMediaTime() + 1e6   // far future: nothing ages out
        points = path.enumerated().map { ($0.element, now - Self.life * Double(path.count - $0.offset) / Double(max(1, path.count))) }
        frozenAt = now
        setNeedsDisplay()
    }
    private var frozenAt: CFTimeInterval?

    private func start() {
        guard link == nil else { return }
        frozenAt = nil
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        points.removeAll { now - $0.t > Self.life }
        if points.isEmpty { link?.invalidate(); link = nil }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard points.count > 1, let ctx = UIGraphicsGetCurrentContext() else { return }
        let now = frozenAt ?? CACurrentMediaTime()
        let smooth = Self.catmullRom(points.map(\.p), steps: 4)
        let ages = Self.resampleAges(points.map { now - $0.t }, to: smooth.count)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for i in 1..<smooth.count {
            // 0 at the tail, 1 at the finger.
            let fresh = max(0, 1 - CGFloat(ages[i]) / CGFloat(Self.life))
            ctx.setStrokeColor(color.withAlphaComponent(0.9 * fresh).cgColor)
            ctx.setLineWidth(max(0.5, Self.width * (0.25 + 0.75 * fresh)))
            ctx.move(to: smooth[i - 1])
            ctx.addLine(to: smooth[i])
            ctx.strokePath()
        }
    }

    /// Catmull-Rom through the samples, so a quick flick reads as a curve rather than a zigzag.
    private static func catmullRom(_ p: [CGPoint], steps: Int) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var out: [CGPoint] = [p[0]]
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                func c(_ a: CGFloat, _ b: CGFloat, _ cc: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3)
                }
                out.append(CGPoint(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        return out
    }

    private static func resampleAges(_ a: [CFTimeInterval], to n: Int) -> [CFTimeInterval] {
        guard a.count > 1, n > 1 else { return Array(repeating: a.first ?? 0, count: n) }
        return (0..<n).map { i in
            let x = Double(i) / Double(n - 1) * Double(a.count - 1)
            let lo = Int(x), hi = min(a.count - 1, lo + 1)
            return a[lo] + (a[hi] - a[lo]) * (x - Double(lo))
        }
    }
}
