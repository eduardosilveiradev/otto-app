import SwiftUI
import ThinkingOrbsKit

/// A ThinkingOrb that morphs when its state changes instead of cutting: the old
/// shape draws in to a ring at its centre and fades, and the new one blooms out
/// of it. Each dot is pulled toward the ring at its own angle, so the two states
/// need no dot-to-dot pairing (the engine's frames carry no identities) and
/// nothing jumps. The same transition the dashboard mockup runs on the web.
struct MorphingOrb: View {
    let state: OrbState
    var size: OrbSize = .px20
    var morph: Double = 0.9

    @State private var from: OrbState?
    @State private var shown: OrbState
    @State private var since = Date.distantPast

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: OrbState, size: OrbSize = .px20, morph: Double = 0.9) {
        self.state = state
        self.size = size
        self.morph = morph
        _shown = State(initialValue: state)
    }

    var body: some View {
        let side = Double(size.rawValue)
        Group {
            if reduceMotion {
                ThinkingOrb(state: state, size: size)
            } else {
                TimelineView(.animation) { timeline in
                    let now = timeline.date
                    Canvas(rendersAsynchronously: false) { context, _ in
                        let u = now.timeIntervalSince(since) / morph
                        if let from, u < 1 {
                            draw(condense(frame(from, now), k: ease(u / 0.55), alpha: 1 - ease((u - 0.4) / 0.25)), in: &context)
                            draw(condense(frame(shown, now), k: 1 - ease((u - 0.45) / 0.55), alpha: ease((u - 0.35) / 0.25)), in: &context)
                        } else {
                            draw(frame(shown, now), in: &context)
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .onChange(of: state) { _, new in
            from = shown
            shown = new
            since = .now
        }
        .accessibilityElement()
        .accessibilityLabel(state.label)
        .accessibilityAddTraits(.isImage)
    }

    private func frame(_ s: OrbState, _ date: Date) -> OrbFrame {
        let preset = resolvePreset(s, size)
        return orbFrame(preset, size: Double(size.rawValue), t: date.timeIntervalSinceReferenceDate * preset.speed)
    }

    /// Pull every mark toward the ring (k 0 untouched, 1 on it) and scale its opacity.
    private func condense(_ f: OrbFrame, k: Double, alpha: Double) -> OrbFrame {
        let c = Double(size.rawValue) / 2, ring = Double(size.rawValue) * 0.3125
        func pull(_ x: Double, _ y: Double) -> (Double, Double) {
            let dx = x - c, dy = y - c, d = max(hypot(dx, dy), 0.0001)
            return (x + (c + dx / d * ring - x) * k, y + (c + dy / d * ring - y) * k)
        }
        var out = f
        for i in out.dots.indices {
            (out.dots[i].x, out.dots[i].y) = pull(out.dots[i].x, out.dots[i].y)
            out.dots[i].a *= alpha
        }
        for i in out.lines.indices {
            (out.lines[i].x1, out.lines[i].y1) = pull(out.lines[i].x1, out.lines[i].y1)
            (out.lines[i].x2, out.lines[i].y2) = pull(out.lines[i].x2, out.lines[i].y2)
            out.lines[i].a *= alpha
        }
        return out
    }

    /// The package's painter, line for line: lines first, then the already z-sorted dots.
    private func draw(_ f: OrbFrame, in context: inout GraphicsContext) {
        for l in f.lines {
            var path = Path()
            path.move(to: CGPoint(x: l.x1, y: l.y1))
            path.addLine(to: CGPoint(x: l.x2, y: l.y2))
            context.stroke(path, with: .color(ink(l.white, l.a)), lineWidth: l.w)
        }
        for d in f.dots {
            context.fill(Path(ellipseIn: CGRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2)),
                         with: .color(ink(d.white, d.a)))
        }
    }

    private func ink(_ white: Double, _ alpha: Double) -> Color {
        let w = min(1, max(0, white))
        let g = ((colorScheme == .dark ? 1 - w : w) * 255).rounded(.toNearestOrAwayFromZero) / 255
        return Color(.sRGB, red: g, green: g, blue: g, opacity: alpha)
    }

    private func ease(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        return x * x * (3 - 2 * x)
    }
}
