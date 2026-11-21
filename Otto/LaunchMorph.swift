import SwiftUI
import UIKit

// The cold launch into Otto's thread, ported from the web prototype the owner approved (launch-morph/prototype.html):
// "Otto" slides up beside the face, opens out letter by letter into a greeting while the face hops above it, then the
// greeting folds into the composer's placeholder and the face lifts into the header as the chat fades in around them.
//
// The chat lives in hosting controllers of its own (KeyboardDock), where no matched geometry can reach, so ChatView
// reports where the header's face sits (`.launchSeat()`) and the composer hands over its placeholder label (`hold`). Both
// stay hidden until this overlay's copies land on them. Every value is a pure function of the time since launch, as the
// prototype's single track per element is: nothing stacks, so nothing can drop out, and any touch, a key, or the app
// being opened somewhere else (`skip`) ends it on the finished chat at once. The thread and the server never wait for it.

@MainActor @Observable final class LaunchMorph {
    static let shared = LaunchMorph()
    /// The header's face and the composer's placeholder stay hidden while it runs; the overlay draws them.
    private(set) var running = false
    /// The header's face, in window points.
    var seat: CGRect? { didSet { cached = nil } }
    @ObservationIgnored private(set) weak var placeholder: UILabel?
    /// Reduce Motion: each stage fades in place, nothing travels or reshapes.
    @ObservationIgnored let still = UIAccessibility.isReduceMotionEnabled
    @ObservationIgnored let greeting = LaunchMorph.greeting()
    /// Where the launch's clock is, and the frame it was read on.
    @ObservationIgnored private var clock: (ms: Double, at: Date)?
    @ObservationIgnored private var frozen: Double?
    @ObservationIgnored private var slow = 1.0
    @ObservationIgnored private var cached: (key: [CGFloat], plan: Plan)?
    /// Something other than the icon opened the app (a notification, a widget, Siri, a control): it goes straight there.
    static var routed = false

    private init() {
        // The first time this process shows Otto's thread, unless something opened the app elsewhere or onboarding just
        // finished (both `skip`). The store last: a door opened mid-onboarding must not make it before pairing.
        var play = !Self.routed && OttoStore.shared.pips.current == "app"
        #if DEBUG
        let d = UserDefaults.standard, args = CommandLine.arguments
        if args.contains("-launchCheck") { Self.check() }
        // `-launchAt <ms>` holds one moment, `-launchSlow <n>` plays it n times slower, `-launchMorph` just plays it. Any
        // other arguments mean a fixture (shoot.sh, the check scripts), whose shots and taps are timed: no launch over those.
        if d.object(forKey: "launchAt") != nil { frozen = d.double(forKey: "launchAt") }
        if d.double(forKey: "launchSlow") > 0 { slow = d.double(forKey: "launchSlow") }
        if args.count > 1 && frozen == nil && slow == 1 && !args.contains("-launchMorph") { play = false }
        #endif
        running = play
    }

    /// The finished chat: the timer, a touch, a key, the app leaving the front, or a way in from outside.
    func finish() {
        guard running else { return }
        running = false
        placeholder?.alpha = 1
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// Doors, a notification, Siri, onboarding's end: wherever the app is being opened to comes up as it is, never
    /// behind a launch.
    static func skip() { routed = true; shared.finish() }

    /// The composer's placeholder, out of sight until the greeting lands in it.
    func hold(_ label: UILabel) {
        guard running, placeholder == nil else { return }
        placeholder = label
        label.alpha = 0
    }

    /// Milliseconds into the launch, the prototype's clock. It moves with the frames drawn, at most 50 ms a frame: a cold
    /// launch's first frames are its slowest, and a stall there held the screen while a stage played out unseen.
    /// It starts on the first frame drawn while the app is in front, and holds while it isn't.
    func time(_ now: Date) -> Double {
        if let frozen { return frozen }
        guard UIApplication.shared.applicationState == .active else { clock = clock.map { ($0.ms, now) }; return clock?.ms ?? 0 }
        // The overlay ends it when its clock runs out; this is only the net under a clock that stopped being drawn.
        if clock == nil { Task { [slow = self.slow] in try? await Task.sleep(for: .seconds(10 * slow)); LaunchMorph.shared.finish() } }
        let ms = clock.map { $0.ms + min(now.timeIntervalSince($0.at), 0.05) * 1000 / slow } ?? 0
        clock = (ms, now)
        return ms
    }

    var end: Double { still ? T.stillEnd : T.end }

    static func greeting(at date: Date = .now) -> String {
        let h = Calendar.current.component(.hour, from: date)
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    /// Each letter of the short line paired with one of the long line's: the same letter where the long line has it within
    /// three of its even share, that share otherwise, never a space (prototype.html's `pair`). Empty when it can't pair.
    nonisolated static func pair(_ short: [Character], _ long: [Character]) -> [Int] {
        guard !short.isEmpty, long.count >= short.count else { return [] }
        var out: [Int] = []
        for (k, c) in short.enumerated() {
            let from = k > 0 ? out[k - 1] + 1 : 0, to = long.count - (short.count - k)
            let share = ((Double(k) + 0.5) * Double(long.count) / Double(short.count)).rounded(.down)   // JS Math.round(x - 0.5)
            let even = min(to, max(from, Int(share)))
            var best = -1
            for i in from...to where long[i].lowercased() == c.lowercased() && (best < 0 || abs(i - even) < abs(best - even)) { best = i }
            var pick = best >= 0 && abs(best - even) <= 3 ? best : even
            while pick < to && long[pick].isWhitespace { pick += 1 }
            out.append(pick)
        }
        return out
    }

    fileprivate func plan(_ size: CGSize, _ origin: CGPoint) -> Plan {
        let ph = placeholder.flatMap { $0.window == nil ? nil : $0.convert($0.bounds, to: nil) }
        let shown: CGFloat = placeholder?.isHidden == false ? 1 : 0
        let at: CGRect = ph ?? .null
        let key: [CGFloat] = [size.width, size.height, origin.x, origin.y, at.minX, at.minY, at.height, shown]
        if let cached, cached.key == key { return cached.plan }
        let p = Plan(size: size, origin: origin, greeting: greeting, seat: seat, placeholder: ph.flatMap { f in placeholder.map { (frame: f, label: $0) } }, still: still)
        cached = (key, p)
        return p
    }

    #if DEBUG
    /// `-launchCheck`: the pairing against prototype.html's own answers, and the greeting's hours, as LAUNCHCHECK lines.
    private static func check() {
        let cases: [(String, String, [Int])] = [
            ("Otto", "Good morning", [1, 5, 7, 10]), ("Message", "Good morning", [0, 2, 5, 6, 7, 9, 11]),
            ("Otto", "Good afternoon", [1, 7, 8, 12]), ("Message", "Good afternoon", [1, 3, 5, 7, 9, 11, 13]),
            ("Otto", "Good evening", [1, 5, 7, 10]), ("Message", "Good evening", [0, 5, 6, 7, 8, 9, 11]),
            ("Message", "Hi", []), ("", "Hi", []),
        ]
        for (s, l, want) in cases {
            let got = pair(Array(s), Array(l))
            print("LAUNCHCHECK \(got == want ? "PASS" : "FAIL") \(s.isEmpty ? "(empty)" : s) -> \(l): \(got)")
        }
        let hours = [0, 11, 12, 17, 18, 23].map { greeting(at: Calendar.current.date(bySettingHour: $0, minute: 0, second: 0, of: .now)!) }
        let want = ["Good morning", "Good morning", "Good afternoon", "Good afternoon", "Good evening", "Good evening"]
        print("LAUNCHCHECK \(hours == want ? "PASS" : "FAIL") greeting by hour: \(hours)")
    }
    #endif
}

/// prototype.html's timeline, in milliseconds.
private enum T {
    static let into = 250.0, morphAt = 550.0, morph = 400.0, landAt = 1700.0, land = 520.0
    static let opened = morphAt + morph, l1 = landAt + land * 0.42, l2 = landAt + land * 0.62, landed = landAt + land
    /// The face blinks once it has landed (the live face's own blink, 240 ms), and then it's over.
    static let blink = landed + 260, end = blink + 260
    /// Reduce Motion's path: the chat fades in from 1900 over 240 ms.
    static let stillEnd = landAt + 460
}

private extension UnitCurve {
    /// prototype.html's two curves.
    static var out: UnitCurve { .bezier(startControlPoint: UnitPoint(x: 0.23, y: 1), endControlPoint: UnitPoint(x: 0.32, y: 1)) }
    static var inOut: UnitCurve { .bezier(startControlPoint: UnitPoint(x: 0.77, y: 0), endControlPoint: UnitPoint(x: 0.175, y: 1)) }
}

private protocol Tween { static func mix(_ a: Self, _ b: Self, _ p: CGFloat) -> Self }
extension CGFloat: Tween { fileprivate static func mix(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p } }

/// A letter moved by (x, y) and scaled by (sx, sy) from its leading middle, as `translate() scale()` with the prototype's
/// `transform-origin: 0 50%`. For the face, (x, y) is its top-left corner and sx its size.
private struct Pose: Tween {
    var x: CGFloat = 0, y: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1
    static let home = Pose()
    static func mix(_ a: Pose, _ b: Pose, _ p: CGFloat) -> Pose {
        Pose(x: .mix(a.x, b.x, p), y: .mix(a.y, b.y, p), sx: .mix(a.sx, b.sx, p), sy: .mix(a.sy, b.sy, p))
    }
}

/// One keyframe of one property: when, what, and the curve on to the next keyframe (linear without one), as the
/// prototype's `track` reads its steps.
private struct K<V: Tween> {
    let t: Double, v: V, curve: UnitCurve?
    init(_ t: Double, _ v: V, _ curve: UnitCurve? = nil) { self.t = t; self.v = v; self.curve = curve }
}

private func at<V: Tween>(_ keys: [K<V>], _ t: Double) -> V {
    guard let n = keys.firstIndex(where: { $0.t > t }) else { return keys[keys.count - 1].v }
    guard n > 0 else { return keys[0].v }
    let a = keys[n - 1], b = keys[n], p = (t - a.t) / (b.t - a.t)
    return V.mix(a.v, b.v, CGFloat(a.curve?.value(at: p) ?? p))
}

private struct Box { var x, cy, w: CGFloat }

/// Each letter's box along a line set in `font`, kerning between letters included, from x = 0.
private func letters(_ s: [Character], _ font: UIFont, kern: CGFloat = 0) -> [Box] {
    func width(_ n: Int) -> CGFloat { NSAttributedString(string: String(s.prefix(n)), attributes: [.font: font, .kern: kern]).size().width }
    return s.indices.map { i in let a = width(i); return Box(x: a, cy: 0, w: Swift.max(width(i + 1) - a, 0.01)) }
}

private extension Array where Element == Box {
    var width: CGFloat { last.map { $0.x + $0.w } ?? 0 }
    func placed(x: CGFloat, cy: CGFloat) -> [Box] { map { Box(x: $0.x + x, cy: cy, w: $0.w) } }
}

/// Where each letter of the long line sits squeezed into the short one (`packed`), and where each of the short line's
/// letters sits spread over the long one (`spread`). The long line's unpaired letters wait at a tenth of their width
/// between the paired ones (prototype.html's `boxes`).
private func trade(long lb: [Box], short sb: [Box], map: [Int], tall: CGFloat) -> (packed: [Pose], spread: [Pose]) {
    let thin: CGFloat = 0.1
    var packed = [Pose](repeating: .home, count: lb.count), spread = [Pose](repeating: .home, count: sb.count)
    var cursor = sb[0].x - lb.prefix(map[0]).reduce(0) { $0 + $1.w * thin }
    for (i, l) in lb.enumerated() {
        if let k = map.firstIndex(of: i) {
            let s = sb[k]
            packed[i] = Pose(x: s.x - l.x, y: s.cy - l.cy, sx: s.w / l.w, sy: tall)
            spread[k] = Pose(x: l.x - s.x, y: l.cy - s.cy, sx: l.w / s.w, sy: 1 / tall)
            cursor = s.x + s.w
        } else {
            packed[i] = Pose(x: cursor - l.x, y: sb[0].cy - l.cy, sx: thin, sy: tall)
            cursor += l.w * thin
        }
    }
    return (packed, spread)
}

/// Everything that holds still for the launch: the three lines' letters and where they sit, how the greeting trades
/// places with the wordmark and with the placeholder, and the face's three places. All in the overlay's own points.
private struct Plan {
    static let mark = UIFont.systemFont(ofSize: 44, weight: .semibold)
    let hello: UIFont, ph: UIFont?
    let w: [Character], g: [Character], p: [Character]
    let wb: [Box], gb: [Box], pb: [Box]
    /// Off when a draft fills the composer: the greeting folds into the box and is gone.
    let phShown: Bool
    let open: (packed: [Pose], spread: [Pose])
    let fold: (packed: [Pose], spread: [Pose])?
    let beside: Pose, home: Pose, seated: Pose?

    init(size: CGSize, origin: CGPoint, greeting: String, seat: CGRect?, placeholder: (frame: CGRect, label: UILabel)?, still: Bool) {
        let mid = size.width / 2
        w = Array("Otto"); g = Array(greeting)
        // 27 pt, narrower only if a greeting outgrows a small screen.
        let wide = letters(g, .systemFont(ofSize: 27)).width
        hello = .systemFont(ofSize: 27 * Swift.min(1, (size.width - 32) / wide))
        // The greeting block (face, 14 pt, the line) sits in the middle of the top 92% of the screen, as in the prototype.
        let lineH = hello.lineHeight, top = size.height * 0.46 - (34 + 14 + lineH) / 2, cy = top + 48 + lineH / 2
        let gl = letters(g, hello)
        gb = gl.placed(x: mid - gl.width / 2, cy: cy)
        // The wordmark rests on the greeting's line, after a 44 pt slot for the face and a 12 pt gap; under Reduce Motion
        // it stands alone, centred where the greeting will be.
        let wl = letters(w, Self.mark, kern: -0.44), left = mid - (56 + wl.width) / 2
        wb = wl.placed(x: still ? mid - wl.width / 2 : left + 56, cy: cy)
        beside = Pose(x: left, y: cy - 22, sx: 44, sy: 44)
        home = Pose(x: mid - 17, y: top, sx: 34, sy: 34)
        seated = seat.map { Pose(x: $0.minX - origin.x, y: $0.minY - origin.y, sx: $0.width, sy: $0.width) }
        open = trade(long: gb, short: wb, map: LaunchMorph.pair(w, g), tall: Self.mark.pointSize / hello.pointSize)
        if let placeholder, let font = placeholder.label.font, let text = placeholder.label.text {
            ph = font; p = Array(text)
            let f = placeholder.frame
            pb = letters(p, font).placed(x: f.minX - origin.x, cy: f.midY - origin.y)
            phShown = !placeholder.label.isHidden
            let map = LaunchMorph.pair(p, g)
            fold = map.isEmpty ? nil : trade(long: gb, short: pb, map: map, tall: font.pointSize / hello.pointSize)
        } else {
            ph = nil; p = []; pb = []; phShown = false; fold = nil
        }
    }
}

/// The launch, over the chat. Up only while `LaunchMorph.running`; the chat is laid out and live underneath from the
/// first frame.
struct LaunchOverlay: View {
    let store: OttoStore
    @Environment(\.scenePhase) private var phase
    @FocusState private var keys: Bool
    private var m: LaunchMorph { .shared }

    var body: some View {
        if m.running {
            GeometryReader { geo in
                TimelineView(.animation) { ctx in
                    let t = m.time(ctx.date)
                    moment(t, m.plan(geo.size, geo.frame(in: .global).origin))
                        .task(id: t >= m.end) { if t >= m.end { m.finish() } }
                }
            }
            .ignoresSafeArea()
            .environment(\.layoutDirection, .leftToRight)   // every place here is in screen points
            .contentShape(.rect)
            // Any touch or key goes straight to the finished chat.
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in m.finish() })
            .focusable().focused($keys).focusEffectDisabled()
            .onKeyPress { _ in m.finish(); return .ignored }
            .onAppear { keys = true }
            .onOpenURL { _ in m.finish() }
            .onChange(of: phase) { _, p in if p == .background { m.finish() } }
        }
    }

    @ViewBuilder private func moment(_ t: Double, _ plan: Plan) -> some View {
        let still = m.still
        let seated = plan.seated ?? plan.home
        // The wordmark: slides up 40 pt and fades in, then each letter trades places with its partner in the greeting.
        let mark: CGFloat = still ? at([K(0, 0), K(200, 1)], t) * at([K(T.morphAt, 1), K(T.morphAt + 200, 0)], t) : at([K(0, 0, .out), K(T.into, 1)], t)
        let lift: CGFloat = still ? 0 : at([K(0, 40, .out), K(T.into, 0)], t)
        // The greeting: hidden until the wordmark opens, then folds down into the composer.
        let gOn: CGFloat = still ? at([K(T.morphAt + 180, 0), K(T.morphAt + 380, 1), K(T.landAt, 1), K(T.landAt + 200, 0)], t)
            : at([K(T.morphAt, 0, .out), K(T.morphAt + 70, 1), K(T.l1, 1), K(T.l2, 0)], t)
        let pOn: CGFloat = (plan.phShown ? 1 : 0) * (still ? at([K(T.landAt + 200, 0), K(T.landAt + 400, 1)], t) : at([K(T.l1, 0), K(T.l2, 1)], t))
        let face: Pose = still ? (t < T.landAt + 200 ? plan.home : seated)
            : at([K(0, Pose(x: plan.beside.x, y: plan.beside.y + 40, sx: 44, sy: 44), .out), K(T.into, plan.beside),
                  K(T.morphAt, plan.beside, .out), K(T.morphAt + 260, plan.home), K(T.landAt, plan.home, .inOut), K(T.landed, seated)], t)
        // Without a seat to land in (a pip's thread under it), the face fades out with the greeting.
        let faceOn: CGFloat = still ? at([K(0, 0), K(200, 1), K(T.landAt, 1), K(T.landAt + 199, 0), K(T.landAt + 200, 0), K(T.landAt + 400, plan.seated == nil ? 0 : 1)], t)
            : at([K(0, 0, .out), K(T.into, 1)] + (plan.seated == nil ? [K(T.l1, 1), K(T.l2, 0)] : []), t)
        // The chat fades in around them a little before the landing ends.
        let cover: CGFloat = still ? at([K(T.landAt + 200, 1, .out), K(T.landAt + 440, 0)], t) : at([K(T.landed - 220, 1, .out), K(T.landed + 20, 0)], t)
        let size = plan.seated?.sx ?? 60

        ZStack(alignment: .topLeading) {
            Color(.systemBackground).opacity(cover)
            // Each line's letters are drawn, not laid out as views, so the line is one element and is never read letter by letter.
            Canvas { ctx, _ in
                for k in plan.w.indices {
                    let pose: Pose = still ? .home : at([K(T.morphAt, .home, .out), K(T.opened, plan.open.spread[k])], t)
                    let on: CGFloat = still ? mark : mark * at([K(T.morphAt, 1, .out), K(T.morphAt + 70, 0)], t)
                    draw(plan.w[k], Plan.mark, .primary, plan.wb[k], Pose(x: pose.x, y: pose.y + lift, sx: pose.sx, sy: pose.sy), on, in: ctx)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Otto")
            .accessibilityHidden(t >= (still ? T.morphAt + 200 : T.opened))
            Canvas { ctx, _ in
                for i in plan.g.indices {
                    let pose: Pose = still ? .home : at([K(T.morphAt, plan.open.packed[i], .out), K(T.opened, .home),
                                                         K(T.landAt, .home, .inOut), K(T.landed, plan.fold?.packed[i] ?? .home)], t)
                    draw(plan.g[i], plan.hello, .primary, plan.gb[i], pose, gOn, in: ctx)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(m.greeting)
            .accessibilityHidden(t < T.morphAt || t >= T.landAt)
            if let ph = plan.ph, let fold = plan.fold {
                Canvas { ctx, _ in
                    for k in plan.p.indices {
                        let pose: Pose = still ? .home : at([K(T.landAt, fold.spread[k], .inOut), K(T.landed, .home)], t)
                        draw(plan.p[k], ph, Color(.placeholderText), plan.pb[k], pose, pOn, in: ctx)
                    }
                }
                .accessibilityHidden(true)
            }
            // Otto's face, as the header draws it; it blinks once it has landed.
            FaceView(look: .otto.with(store.asleep ? .asleep : store.ottoTyping ? .working : .rest), size: size, live: true,
                     blinks: !still && t >= T.blink ? 1 : 0)
                .frame(width: size, height: size)
                .scaleEffect(face.sx / size, anchor: .topLeading)
                .opacity(faceOn)
                .position(x: face.x + size / 2, y: face.y + size / 2)
                .accessibilityHidden(true)
        }
    }

    /// One letter in its box, moved and scaled from its leading middle.
    private func draw(_ c: Character, _ font: UIFont, _ color: Color, _ box: Box, _ pose: Pose, _ on: CGFloat, in ctx: GraphicsContext) {
        guard on > 0 else { return }
        var ctx = ctx
        ctx.opacity = on
        ctx.translateBy(x: box.x + pose.x, y: box.cy + pose.y)
        ctx.scaleBy(x: pose.sx, y: pose.sy)
        ctx.draw(ctx.resolve(Text(String(c)).font(Font(font as CTFont)).foregroundStyle(color)), at: .zero, anchor: .leading)
    }
}

extension View {
    /// The header's face: where the launch's face lands, reported to it and hidden until it has.
    func launchSeat() -> some View {
        opacity(LaunchMorph.shared.running ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                if LaunchMorph.shared.running { LaunchMorph.shared.seat = f }
            }
    }
}
