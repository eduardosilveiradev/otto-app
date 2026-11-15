import SwiftUI

/// Otto's thinking mark: the tangerine face, moving its own way for each kind of work. A port of otto-desktop's
/// design/thinking-spinner.html (the owner-approved prototype) with the same shapes, keyframes, timings and
/// cubic-beziers. Callers pass only the kind. A change of kind is one face easing from loop to loop and never
/// a cut. Amplitudes (the squash, an orbit, the pip, a scale) ease on the app's spring from wherever they are.
/// A pose caught mid-loop (Mull's eyes, Hop's jump) eases home in 280 ms while the next loop waits on the rest face.
struct OttoThinkingSpinner: View {
    /// idle, think (Wobble), look (Mull), away (Pip), do (Hop) or done.
    enum Kind: String { case idle, think, look, away, `do`, done }

    var kind: Kind
    var size: CGFloat = 20
    /// The surface the mark sits on: a ring in this colour keeps Pip's dot apart from the face.
    var ring: Color = Color(.systemBackground)

    @State private var shown: Kind
    /// When `shown` began, and the amplitudes and loop poses as they were at that instant.
    @State private var since = Date.distantPast
    @State private var ampsFrom: Amps
    @State private var posesFrom = Poses.rest
    /// The five-second blink restarts when it changes name: once for think, away and do, once for idle and done.
    @State private var blinkSince = Date.distantPast

    @Environment(\.accessibilityReduceMotion) private var still

    init(kind: Kind, size: CGFloat = 20, ring: Color = Color(.systemBackground)) {
        self.kind = kind
        self.size = size
        self.ring = ring
        _shown = State(initialValue: kind)
        _since = State(initialValue: .now)
        _ampsFrom = State(initialValue: Amps(kind))
    }

    var body: some View {
        TimelineView(.animation(paused: still && (shown == .idle || shown == .done))) { tl in
            draw(snapshot(at: tl.date))
        }
        .frame(width: size, height: size)
        // Every frame is drawn from the clock; an animation from outside (the bubble's spring) would smear it.
        .transaction { $0.animation = nil }
        .onChange(of: kind) { _, new in change(to: new, at: .now) }
        .accessibilityElement()
        .accessibilityLabel(kind.label)
        .accessibilityAddTraits(.isImage)
    }

    private func change(to new: Kind, at now: Date) {
        guard new != shown else { return }
        ampsFrom = amps(at: now)
        posesFrom = poses(at: now)
        if new.blinkSet != shown.blinkSet { blinkSince = now }
        shown = new
        since = now
    }

    // MARK: Drawing. The prototype's rig, outside in; each modifier is one of its layers.

    private func draw(_ f: Frame) -> some View {
        let em = size, o = Optics(size)
        return ZStack {
            pip(f, front: false)
            ZStack {
                Circle().fill(Self.otto)
                    .scaleEffect(x: 1 + f.squash * 0.6, y: 1 - f.squash * 0.6)
                    .rotationEffect(.degrees(f.turnB))
                    .scaleEffect(x: 1 + f.squash, y: 1 - f.squash)
                    .rotationEffect(.degrees(f.turnA))
                ZStack {
                    eye(at: o.ex, f.poses.left)
                    eye(at: 1 - o.ex - o.ew, f.poses.right)
                }
                .frame(width: em, height: em)
                .opacity(f.eyeOpacity)
                .offset(x: f.eyesX * em, y: (f.poses.bob + f.eyesY) * em)
                .rotationEffect(.degrees(f.tilt))
                .offset(y: f.lift * em)
            }
            .scaleEffect(f.faceScale)
            pip(f, front: true)
        }
        .frame(width: em, height: em)
        .scaleEffect(x: f.poses.sqX, y: f.poses.sqY, anchor: .bottom)
        .offset(y: f.poses.jump * em)
        .scaleEffect(f.fit, anchor: .bottom)
        .scaleEffect(x: f.settleX, y: f.settleY)
    }

    private func pip(_ f: Frame, front: Bool) -> some View {
        let em = size
        return Circle().fill(ring).frame(width: 0.21 * em, height: 0.21 * em)   // box-shadow: 0 0 0 .025em var(--ring)
            .overlay { Circle().fill(Self.otto).frame(width: 0.16 * em, height: 0.16 * em) }
            .scaleEffect(f.pipScale)
            .offset(x: f.pipX * em, y: f.pipY * em)
            .frame(width: em, height: em)
            .rotationEffect(.degrees(-20))
            .opacity(f.pipOpacity * (f.pipFront == front ? 1 : 0))
    }

    private func eye(at x: Double, _ pose: EyePose) -> some View {
        let em = size, o = Optics(size)
        return Capsule().fill(Self.eye)
            .frame(width: o.ew * em, height: o.eh * em)
            .scaleEffect(x: pose.sx, y: pose.sy)
            .offset(x: pose.dx * em)
            .position(x: (x + o.ew / 2) * em, y: (o.ey + o.eh / 2) * em)
    }

    // MARK: One frame

    /// Everything the rig needs at one instant, in em (the mark's size) and degrees.
    struct Frame {
        var poses = Poses.rest
        var squash = 0.0, turnA = 0.0, turnB = 0.0
        var lift = 0.0, tilt = 0.0, eyesX = 0.0, eyesY = 0.0, eyeOpacity = 1.0
        var faceScale = 1.0, fit = 1.0, settleX = 1.0, settleY = 1.0
        var pipOpacity = 0.0, pipX = 0.435, pipY = 0.0, pipScale = 1.0, pipFront = true
    }

    func snapshot(at now: Date) -> Frame {
        let o = Optics(size), t = now.timeIntervalSinceReferenceDate
        var f = Frame()
        if still {
            // Reduce Motion, as the prototype: a still pose that still differs by kind, and only the eyes fade.
            let a = Amps(shown)
            f.lift = -1.3 * o.g * a.think
            f.eyesX = o.g * a.think + 1.4 * o.g * a.away
            f.tilt = -8 * a.look
            f.faceScale = 1 - 0.36 * a.away
            f.fit = 1 - 0.14 * a.do
            f.pipOpacity = a.pip
            if shown != .idle && shown != .done { f.eyeOpacity = 1 - 0.65 * Self.alternate(t, 1.6, Self.easeInOut) }
            return f
        }
        let a = amps(at: now)
        f.poses = poses(at: now)
        // Wobble: one circle squashed twice about axes turning every 7 s and 3.4 s (reversed); the eyes ride
        // level on a small orbit every 3.8 s, lifted.
        f.squash = o.w * a.think
        f.turnA = 360 * Self.mod(t, 7) / 7
        f.turnB = -360 * Self.mod(t, 3.4) / 3.4
        f.lift = -1.3 * o.g * a.think
        let gaze = 2 * Double.pi * Self.mod(t, 3.8) / 3.8
        f.eyesX = cos(gaze) * o.g * a.think
        f.eyesY = sin(gaze) * o.g * a.think
        // Mull: the eyes' axis tilts.
        f.tilt = -8 * a.look
        // Pip: the dot's x and y are two sine loops a quarter-beat apart on an ellipse tilted -20°; one copy under
        // the face and one over it swap at the far ends. The eyes follow on an orbit locked to it.
        f.pipOpacity = a.pip
        f.pipX = -0.435 + 0.87 * Self.alternate(t, 1.2, Self.sine)
        let e = Self.alternate(t + 0.6, 1.2, Self.sine)
        f.pipY = -0.13 + 0.26 * e
        f.pipScale = 0.8 + 0.32 * e
        f.pipFront = Self.mod(t, 2.4) < 1.2
        let watch = -2 * Double.pi * Self.mod(t + 4.0 / 3, 2.4) / 2.4
        f.eyesX += cos(watch) * 1.4 * o.g * a.away
        f.eyesY += sin(watch) * 1.4 * o.g * a.away
        f.faceScale = 1 - 0.36 * a.away
        // Hop: the face shrinks into its box for headroom.
        f.fit = 1 - 0.14 * a.do
        // Done: one short squash as it arrives.
        if shown == .done {
            let u = now.timeIntervalSince(since) / 0.5
            if u < 1 {
                f.settleX = Self.track(u, [(0, 1), (0.35, 1.07), (1, 1)]) { _ in Self.easeInOut }
                f.settleY = Self.track(u, [(0, 1), (0.35, 0.94), (1, 1)]) { _ in Self.easeInOut }
            }
        }
        return f
    }

    // MARK: Amplitudes: transitions, so they ease in and out from any phase

    struct Amps {
        var think = 0.0, look = 0.0, away = 0.0, `do` = 0.0, pip = 0.0
        init(_ k: Kind) {
            think = k == .think ? 1 : 0
            look = k == .look ? 1 : 0
            away = k == .away ? 1 : 0
            self.do = k == .do ? 1 : 0
            pip = away
        }
    }

    private func amps(at now: Date) -> Amps {
        let to = Amps(shown), dt = now.timeIntervalSince(since)
        let s = Self.spring.value(at: min(1, dt / 0.45)), p = Self.ease.value(at: min(1, dt / 0.25))
        var a = to
        a.think = ampsFrom.think + (to.think - ampsFrom.think) * s
        a.look = ampsFrom.look + (to.look - ampsFrom.look) * s
        a.away = ampsFrom.away + (to.away - ampsFrom.away) * s
        a.do = ampsFrom.do + (to.do - ampsFrom.do) * s
        a.pip = ampsFrom.pip + (to.pip - ampsFrom.pip) * p
        return a
    }

    // MARK: Pose loops: each starts and ends on the rest face

    struct EyePose { var dx = 0.0, sx = 1.0, sy = 1.0 }
    /// The prototype's `.loop` layers: j-jump, j-sq, j-bob and the two eyes.
    struct Poses {
        var jump = 0.0, sqX = 1.0, sqY = 1.0, bob = 0.0
        var left = EyePose(), right = EyePose()
        static let rest = Poses()

        func mixed(toward b: Poses, _ k: Double) -> Poses {
            func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
            func m(_ x: EyePose, _ y: EyePose) -> EyePose { EyePose(dx: m(x.dx, y.dx), sx: m(x.sx, y.sx), sy: m(x.sy, y.sy)) }
            return Poses(jump: m(jump, b.jump), sqX: m(sqX, b.sqX), sqY: m(sqY, b.sqY), bob: m(bob, b.bob),
                         left: m(left, b.left), right: m(right, b.right))
        }
    }

    private func poses(at now: Date) -> Poses {
        let dt = now.timeIntervalSince(since)
        // The prototype's setKind: whatever was mid-flight is frozen and eased to rest, cubic-bezier(.22, 1, .36, 1).
        if dt < 0.28 { return posesFrom.mixed(toward: .rest, Self.home.value(at: dt / 0.28)) }
        return Self.loops(shown, t: dt - 0.28, blink: now.timeIntervalSince(blinkSince))
    }

    /// The loops of one kind, `t` seconds after its 280 ms wait.
    static func loops(_ kind: Kind, t: Double, blink: Double) -> Poses {
        var p = Poses.rest
        switch kind {
        case .look:
            // Mull, 1.9 s linear: the eyes travel round the sphere, half a turn a beat, so the loop has no seam.
            let u = mod(t, 1.9) / 1.9
            p.left = mull(u, az: -mullAZ)
            p.right = mull(u, az: mullAZ)
            return p
        case .do:
            // Hop, 1.15 s: a crouch, a jump on a parabola, a landing, standing again.
            let u = mod(t, 1.15) / 1.15
            p.jump = track(u, [(0, 0), (0.13, 0), (0.5, -0.17), (0.87, 0), (1, 0)]) { [rise, rise, fall, ease][$0] }
            p.sqX = track(u, [(0, 1), (0.13, 1.1), (0.24, 0.94), (0.5, 1), (0.76, 0.95), (0.87, 1.1), (1, 1)]) { _ in easeInOut }
            p.sqY = track(u, [(0, 1), (0.13, 0.87), (0.24, 1.08), (0.5, 1), (0.76, 1.07), (0.87, 0.87), (1, 1)]) { _ in easeInOut }
            p.bob = track(u, [(0, 0), (0.13, 0.035), (0.5, -0.03), (0.87, 0.035), (1, 0)]) { _ in easeInOut }
        default: break
        }
        // A blink every five seconds; arriving at done adds one more, 0.4 s, after the wait.
        var sy = track(mod(blink, 5) / 5, [(0, 1), (0.94, 1), (0.97, 0.1), (1, 1)]) { _ in easeInOut }
        if kind == .done && t >= 0 && t < 0.4 { sy = track(t / 0.4, [(0, 1), (0.5, 0.1), (1, 1)]) { _ in easeInOut } }
        p.left.sy = sy
        p.right.sy = sy
        return p
    }

    /// One Mull eye at beat progress `u`: an eye at angle a sits at x = r·sin a and is cos a wide; past the edge
    /// it is the next eye coming round the other side. Relative to where the eye rests.
    static func mull(_ u: Double, az: Double) -> EyePose {
        let quart = u < 0.5 ? 8 * pow(u, 4) : 1 - 8 * pow(1 - u, 4)
        let a = az + quart * .pi, c = cos(a)
        return EyePose(dx: 0.45 * sin(a) * (c < 0 ? -1 : 1) - 0.45 * sin(az), sx: max(0.02, abs(c)) / cos(az))
    }
    static let mullAZ = 16.5 * Double.pi / 180

    // MARK: Curves, from the prototype's CSS

    static let spring = bezier(0.3, 1.18, 0.5, 1)      // --spring, the app's
    static let sine = bezier(0.37, 0, 0.63, 1)         // --sine
    static let rise = bezier(0.33, 0.67, 0.67, 1)      // --rise
    static let fall = bezier(0.33, 0, 0.67, 0.33)      // --fall
    static let home = bezier(0.22, 1, 0.36, 1)         // setKind's ease home
    static let easeInOut = bezier(0.42, 0, 0.58, 1)    // CSS ease-in-out
    static let ease = bezier(0.25, 0.1, 0.25, 1)       // CSS ease
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> UnitCurve {
        .bezier(startControlPoint: UnitPoint(x: x1, y: y1), endControlPoint: UnitPoint(x: x2, y: y2))
    }

    /// A CSS keyframe track at progress `u`: (offset, value) stops, each segment eased by `curve(i)`.
    static func track(_ u: Double, _ keys: [(Double, Double)], _ curve: (Int) -> UnitCurve) -> Double {
        for i in 1..<keys.count where u <= keys[i].0 {
            let (a, va) = keys[i - 1], (b, vb) = keys[i]
            return b > a ? va + (vb - va) * curve(i - 1).value(at: (u - a) / (b - a)) : vb
        }
        return keys[keys.count - 1].1
    }

    /// `animation-direction: alternate` over `dur`: 0→1 then back, eased each way.
    static func alternate(_ t: Double, _ dur: Double, _ curve: UnitCurve) -> Double {
        let u = mod(t, 2 * dur) / dur
        return curve.value(at: u < 1 ? u : 2 - u)
    }

    static func mod(_ t: Double, _ m: Double) -> Double { let r = t.truncatingRemainder(dividingBy: m); return r < 0 ? r + m : r }

    // MARK: Look

    /// The redesign's tangerine (Theme.swift), so the mark matches every other mark of Otto's in the thread.
    static let otto = Color.otto
    static let eye = Color(red: 0x20 / 255, green: 0x20 / 255, blue: 0x20 / 255)      // #202020

    /// The eyes are drawn per optical size: thicker and moving further at text size.
    struct Optics {
        let ew, eh, ex, ey, w, g: Double
        init(_ size: CGFloat) {
            let v = size < 19 ? (0.125, 0.25, 0.3125, 0.3125, 0.07, 0.0625)       // data-sz 16
                : size < 44 ? (0.125, 0.2083, 0.3125, 0.354, 0.055, 0.045)          // data-sz 24
                : (0.1, 0.19, 0.32, 0.374, 0.045, 0.035)                            // 64
            (ew, eh, ex, ey, w, g) = v
        }
    }
}

extension OttoThinkingSpinner.Kind {
    var label: String {
        switch self {
        case .idle: "Otto"
        case .think: "Otto is thinking"
        case .look: "Otto is looking"
        case .away: "Otto is waiting"
        case .do: "Otto is working"
        case .done: "Otto is done"
        }
    }

    /// Which five-second blink runs: it restarts only when this changes. Mull has none.
    fileprivate var blinkSet: Int { self == .look ? 0 : self == .idle || self == .done ? 1 : 2 }

    /// The kind of work a step label from the server (toolstatus.ts) describes, read off its leading words.
    /// nil for to-do bookkeeping, which keeps the mark that's showing. No step is plain thinking, and so is a
    /// step nothing here places.
    /// ponytail: word lists over the label; the server sending the kind beside it is the upgrade.
    init?(step: String?) {
        let s = (step ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = s.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard let first = words.first, !first.isEmpty else { self = .think; return }
        if s.hasSuffix("to-do") || s.hasSuffix("to-do list") { return nil }
        // Waiting on the network, a subagent, a job or a pip, or on the owner.
        let away = ["searching the web", "searching a website", "reading a web", "opening ", "running a subagent",
                    "starting a subagent", "asking ", "waiting", "reconnecting", "checking the browser", "checking the website"]
        if away.contains(where: s.hasPrefix) { self = .away; return }
        if first == "reading", words.count == 2, Self.isHost(words[1]) { self = .away; return }
        // A tool's own name before a better label lands: "Code job", "Pip handoff", "Delegate".
        if !first.hasSuffix("ing"), words.prefix(4).contains(where: ["pip", "pips", "job", "jobs", "delegate", "relay"].contains) {
            self = .away; return
        }
        let look: Set = ["reading", "rereading", "searching", "looking", "checking", "remembering", "recalling", "finding",
                         "listing", "viewing", "inspecting", "comparing", "counting", "showing", "grepping", "locating",
                         "measuring", "verifying", "querying", "scanning", "diffing", "watching"]
        if look.contains(first) { self = .look; return }
        // Any other verb is doing something: running, writing, editing, building, saving, filling in a form.
        self = first != "thinking" && first.hasSuffix("ing") ? .do : .think
    }

    /// "developer.apple.com", not "README.md": the last label is a web TLD and not a file extension.
    private static func isHost(_ w: String) -> Bool {
        let parts = w.split(separator: ".")
        return parts.count > 1 && ["com", "org", "net", "io", "dev", "ai", "co", "edu", "gov", "it", "uk", "de", "fr", "eu", "us", "ca", "info"]
            .contains(String(parts[parts.count - 1]))
    }
}

#if DEBUG
/// The one runnable check: the step table, and the pose maths against the prototype's CSS at its keyframes.
/// Run with `-spinnerCheck`; it asserts, prints "spinner check ok" and carries on.
enum OttoThinkingSpinnerCheck {
    static func run() {
        typealias K = OttoThinkingSpinner.Kind
        let table: [(String?, K?)] = [
            (nil, .think), ("Thinking", .think), ("Toolbox call", .think),
            ("Reading app.css", .look), ("Reading README.md", .look), ("Reading jobs.ts", .look), ("Searching for job", .look),
            ("Looking for *.css", .look), ("Remembering", .look), ("Rereading the chat", .look), ("Checking mail", .look),
            ("Looking up Sam", .look), ("Checking your day", .look),
            ("Searching the web for tangerine", .away), ("Reading developer.apple.com", .away), ("Reading github.com", .away),
            ("Opening github.com", .away), ("Running a subagent: check the orb", .away), ("Reconnecting…", .away),
            ("Asking for your approval", .away), ("Code job", .away), ("Pip handoff", .away), ("Delegate", .away),
            ("Searching a website", .away), ("Opening a browser tab", .away),
            ("Editing thinking.jsx", .do), ("Writing notes.md", .do), ("Running tests", .do), ("Building the app", .do),
            ("Committing and pushing", .do), ("Running JavaScript on a website", .do), ("Filling in a form", .do),
            ("Noting that down", .do), ("Running tests for jobs", .do),
            ("Adding to the to-do list", nil), ("Ticking off a to-do", nil), ("Starting the next to-do", nil),
        ]
        for (step, want) in table { assert(K(step: step) == want, "\(step ?? "nil") → \(String(describing: K(step: step)))") }

        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.002 }
        let hop = { (u: Double) in OttoThinkingSpinner.loops(.do, t: u * 1.15, blink: 0) }
        assert(near(hop(0.5).jump, -0.17) && near(hop(0.13).sqX, 1.1) && near(hop(0.13).sqY, 0.87) && near(hop(0.24).sqY, 1.08))
        assert(near(hop(0).jump, 0) && near(hop(0.999).sqX, 1), "a loop starts and ends on the rest face")
        assert(OttoThinkingSpinner.spring.value(at: 0.7) > 1, "--spring overshoots, past 1 near 0.7")
        let m = OttoThinkingSpinner.mull(0, az: OttoThinkingSpinner.mullAZ)
        assert(near(m.dx, 0) && near(m.sx, 1), "Mull starts on the rest face")
        let half = OttoThinkingSpinner.mull(1, az: OttoThinkingSpinner.mullAZ)
        assert(near(half.dx, 0) && near(half.sx, 1), "half a turn shows the same face")
        // At t = 0 the pip is at the left, and the eyes look left and down with it.
        let x = -0.435 + 0.87 * OttoThinkingSpinner.alternate(0, 1.2, OttoThinkingSpinner.sine)
        let watch = -2 * Double.pi * (4.0 / 3) / 2.4
        assert(near(x, -0.435) && cos(watch) < 0 && sin(watch) > 0)
        print("spinner check ok")
    }
}
#endif
