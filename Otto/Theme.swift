import SwiftUI

/// Otto's contact photo: a tangerine circle with two eyes that blink, bob while
/// thinking, and close (breathing, with drifting Zs) while asleep.
struct OttoAvatar: View {
    var size: CGFloat = 44
    var thinking = false
    var asleep = false
    /// The composer has focus: Otto looks down at the keyboard and sways a little.
    var lookingAtCursor = false
    private var movingEyes: Bool { lookingAtCursor || thinking }

    @State private var blink = false
    @State private var bob = false
    @State private var breathe = false

    var body: some View {
        // Paused while he isn't looking, so an idle avatar costs nothing.
        TimelineView(.animation(paused: !movingEyes)) { tl in
            let sway = movingEyes ? 3 * sin(tl.date.timeIntervalSinceReferenceDate * 1.5) : 0
            face(sway: sway)
                .rotation3DEffect(.degrees(sway), axis: (x: 0, y: 0.1, z: 0))
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: lookingAtCursor)
        .scaleEffect(asleep && breathe ? 1.04 : 1)
        .offset(y: bob ? -2 : 0)
        .overlay(alignment: .topTrailing) {
            if asleep { Zzz(size: size).offset(x: size * 0.3, y: -size * 0.35).transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if thinking && !asleep {
                Typist(size: size).offset(y: -size * 0.04)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: thinking && !asleep)
        .animation(thinking ? .easeInOut(duration: 0.5).repeatForever() : .default, value: bob)
        .animation(asleep ? .easeInOut(duration: 2.2).repeatForever() : .default, value: breathe)
        .animation(.easeInOut(duration: 0.4), value: asleep)
        .onChange(of: thinking, initial: true) { bob = thinking && !asleep }
        .onChange(of: asleep, initial: true) { breathe = asleep }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5)))
                guard !asleep else { continue }
                withAnimation(.easeInOut(duration: 0.08)) { blink = true }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeInOut(duration: 0.08)) { blink = false }
            }
        }
    }

    private var lookingDown: Bool { lookingAtCursor || (thinking && !asleep) }

    private func face(sway: Double) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.74, blue: 0.4), Color(red: 1, green: 0.58, blue: 0.2)],
                                         startPoint: .top, endPoint: .bottom))
                .saturation(asleep ? 0.75 : 1)
            HStack(spacing: size * 0.16) {
                ForEach(0..<2, id: \.self) { _ in
                    if asleep {
                        ClosedEye().stroke(Color(white: 0.12), style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                            .frame(width: size * 0.16, height: size * 0.07)
                    } else {
                        Capsule().fill(Color(white: 0.12))
                            .frame(width: size * 0.1, height: blink ? size * 0.02 : size * 0.19)
                            .rotation3DEffect(.degrees(lookingDown ? 15 : 0), axis: (x: -0.1, y: 0, z: 0))
                            .offset(x: sway, y: lookingDown ? size * 0.18 : 0)
                    }
                }
            }
            .offset(y: asleep ? size * 0.02 : -size * 0.03)
        }
        .frame(width: size, height: size)
    }
}

/// While Otto is replying: a little keyboard in front of him, two fingers tapping away.
private struct Typist: View {
    let size: CGFloat
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .top) {
                // The keyboard: a slab with three rows of keys.
                RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                    .fill(Color(white: 0.85))
                    .overlay {
                        VStack(spacing: size * 0.02) {
                            ForEach(0..<3, id: \.self) { _ in
                                HStack(spacing: size * 0.02) {
                                    ForEach(0..<6, id: \.self) { _ in
                                        RoundedRectangle(cornerRadius: size * 0.01).fill(.white)
                                    }
                                }
                            }
                        }
                        .padding(size * 0.03)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    .frame(width: size * 0.78, height: size * 0.26)
                    .offset(y: size * 0.05)
                // Fingers, alternating, each hopping to a slightly different key.
                HStack(spacing: size * 0.26) {
                    ForEach(0..<2, id: \.self) { i in
                        let phase = t * 9 + Double(i) * .pi
                        Capsule()
                            .fill(Color(red: 1, green: 0.66, blue: 0.3))
                            .overlay(Capsule().strokeBorder(Color(red: 0.85, green: 0.48, blue: 0.15), lineWidth: max(0.5, size * 0.012)))
                            .frame(width: size * 0.12, height: size * 0.18)
                            .offset(x: size * 0.04 * sin(t * 2.3 + Double(i) * 2),
                                    y: -size * 0.05 * max(0, sin(phase)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A closed eye: a shallow downward curve.
private struct ClosedEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6))
        return p
    }
}

/// Three Zs that rise, drift right, grow and fade, one after another, forever.
private struct Zzz: View {
    let size: CGFloat
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .bottomLeading) {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1) // 0→1 per Z
                    Text("z")
                        .font(.system(size: size * (0.18 + 0.14 * p), weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.24))
                        .opacity(p < 0.15 ? p / 0.15 : 1 - (p - 0.15) / 0.85)
                        .offset(x: size * 0.22 * p, y: -size * 0.5 * p)
                }
            }
        }
        .frame(width: size * 0.5, height: size * 0.6, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

// Preview structure (for testing the result)
struct OttoAvatar_Previews: PreviewProvider {
    static var previews: some View {
        OttoAvatar()
    }
}
