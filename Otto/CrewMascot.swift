import SwiftUI

/// The crew's faces: Otto's fruit-bowl siblings, one per role, each with the prop of its trade.
/// PM a plum in a bow tie, planner a lime in glasses, designer a peach in a beret, writers
/// lemons in headphones (each a slightly different lemon), reviewer a blueberry with a monocle.
struct CrewMascot: View {
    enum Mood: String, CaseIterable { case calm, focused, waiting, happy, dizzy }

    let role: String
    var index = 1
    var mood: Mood = .calm
    var size: CGFloat = 44

    @State private var blink = false

    var body: some View {
        // Only the moods that move keep a timeline running.
        TimelineView(.animation(paused: mood == .calm || mood == .happy)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                fruit
                eyes(t)
                prop
            }
            .frame(width: size, height: size)
            .offset(y: mood == .focused ? -size * 0.025 * abs(sin(t * 4)) : 0)
            .rotationEffect(.degrees(mood == .dizzy ? 4 * sin(t * 6) : 0))
        }
        .task(id: mood) {
            while !Task.isCancelled && mood == .calm {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5)))
                withAnimation(.easeInOut(duration: 0.08)) { blink = true }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeInOut(duration: 0.08)) { blink = false }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: mood)
        .accessibilityHidden(true)
    }

    // MARK: the fruit

    private var colors: (Color, Color) {
        switch role {
        case "pm": (Color(red: 0.74, green: 0.56, blue: 0.93), Color(red: 0.55, green: 0.36, blue: 0.82))
        case "planner": (Color(red: 0.70, green: 0.90, blue: 0.42), Color(red: 0.42, green: 0.74, blue: 0.24))
        case "designer": (Color(red: 1.0, green: 0.76, blue: 0.66), Color(red: 0.98, green: 0.52, blue: 0.48))
        case "writer": (Color(red: 1.0, green: 0.93, blue: 0.48), Color(red: 0.98, green: 0.80, blue: 0.20))
        default: (Color(red: 0.55, green: 0.68, blue: 1.0), Color(red: 0.34, green: 0.44, blue: 0.88))
        }
    }

    private var fruit: some View {
        let (top, bottom) = colors
        let body = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
        return Group {
            // A lemon is a little wider than it is tall.
            if role == "writer" { Ellipse().fill(body).frame(width: size, height: size * 0.9) }
            else { Circle().fill(body) }
        }
        .hueRotation(.degrees(role == "writer" ? Double(max(0, index - 1) % 4) * -9 : 0))
        .saturation(mood == .dizzy ? 0.6 : 1)
    }

    // MARK: eyes

    private static let ink = Color(white: 0.12)

    @ViewBuilder private func eyes(_ t: Double) -> some View {
        let s = size
        HStack(spacing: s * 0.16) {
            ForEach(0..<2, id: \.self) { _ in
                switch mood {
                case .happy:
                    HappyEye().stroke(Self.ink, style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
                        .frame(width: s * 0.14, height: s * 0.07)
                case .dizzy:
                    Cross().stroke(Self.ink, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
                        .frame(width: s * 0.12, height: s * 0.12)
                case .focused:
                    // Head down over the work, eyes narrowed.
                    Capsule().fill(Self.ink).frame(width: s * 0.1, height: s * 0.11)
                        .offset(y: s * 0.07)
                case .waiting:
                    // Glancing over at whoever it handed off to, and back.
                    Capsule().fill(Self.ink).frame(width: s * 0.1, height: s * 0.19)
                        .offset(x: s * 0.05 * (sin(t * 0.9) > 0 ? 1 : -1), y: -s * 0.03)
                        .animation(.easeInOut(duration: 0.18), value: sin(t * 0.9) > 0)
                case .calm:
                    Capsule().fill(Self.ink).frame(width: s * 0.1, height: blink ? s * 0.02 : s * 0.19)
                }
            }
        }
        .offset(y: -s * 0.03)
    }

    // MARK: props

    @ViewBuilder private var prop: some View {
        let s = size
        switch role {
        case "pm":
            // A leaf on top and a bow tie under the eyes.
            Leaf().fill(Color(red: 0.38, green: 0.66, blue: 0.3))
                .frame(width: s * 0.2, height: s * 0.12).rotationEffect(.degrees(-25))
                .offset(x: s * 0.08, y: -s * 0.48)
            BowTie().fill(Color(red: 0.24, green: 0.12, blue: 0.34))
                .frame(width: s * 0.34, height: s * 0.15)
                .offset(y: s * 0.3)
        case "planner":
            // Round glasses, one lens per eye (eye centres sit at ±0.13).
            HStack(spacing: s * 0.03) {
                Circle().stroke(Self.ink, lineWidth: s * 0.035).frame(width: s * 0.25, height: s * 0.25)
                Circle().stroke(Self.ink, lineWidth: s * 0.035).frame(width: s * 0.25, height: s * 0.25)
            }
            .overlay(Rectangle().fill(Self.ink).frame(width: s * 0.06, height: s * 0.03))
            .offset(y: -s * 0.03)
            Leaf().fill(Color(red: 0.25, green: 0.52, blue: 0.2))
                .frame(width: s * 0.18, height: s * 0.1).rotationEffect(.degrees(20))
                .offset(x: -s * 0.06, y: -s * 0.48)
        case "designer":
            // A beret, worn at an angle, with its little stalk.
            ZStack {
                Ellipse().fill(Color(red: 0.2, green: 0.2, blue: 0.3)).frame(width: s * 0.66, height: s * 0.24)
                Capsule().fill(Color(red: 0.2, green: 0.2, blue: 0.3)).frame(width: s * 0.05, height: s * 0.1)
                    .offset(y: -s * 0.14)
            }
            .rotationEffect(.degrees(-14))
            .offset(x: -s * 0.1, y: -s * 0.4)
        case "writer":
            // Headphones: a band over the top, a cup on each side.
            let gear = Color(red: 0.22, green: 0.24, blue: 0.3)
            Arc().stroke(gear, style: StrokeStyle(lineWidth: s * 0.07, lineCap: .round))
                .frame(width: s * 1.02, height: s * 1.02)
            HStack(spacing: s * 0.84) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: s * 0.06, style: .continuous).fill(gear)
                        .frame(width: s * 0.15, height: s * 0.3)
                }
            }
            .offset(y: s * 0.04)
        default:
            // The blueberry's crown on top, a monocle on its right eye.
            Crown().fill(Color(red: 0.2, green: 0.26, blue: 0.55))
                .frame(width: s * 0.2, height: s * 0.1)
                .offset(y: -s * 0.43)
            let gold = Color(red: 0.93, green: 0.76, blue: 0.3)
            Circle().stroke(gold, lineWidth: s * 0.04).frame(width: s * 0.27, height: s * 0.27)
                .offset(x: s * 0.13, y: -s * 0.03)
            Chain().stroke(gold, style: StrokeStyle(lineWidth: s * 0.02, lineCap: .round))
                .frame(width: s * 0.2, height: s * 0.3)
                .offset(x: s * 0.24, y: s * 0.22)
        }
    }
}

/// The mood each status wears, and a beat of happy when a run finishes.
extension CrewMascot.Mood {
    init(status: String) {
        switch status {
        case "working": self = .focused
        case "waiting": self = .waiting
        case "error": self = .dizzy
        default: self = .calm
        }
    }

    var label: String {
        switch self {
        case .calm: "Free"
        case .focused: "On it"
        case .waiting: "Waiting on someone"
        case .happy: "Done"
        case .dizzy: "Something broke"
        }
    }
}

// MARK: shapes

private struct HappyEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
        return p
    }
}

private struct Cross: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}

private struct Leaf: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.5))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.midY), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.5))
        return p
    }
}

private struct BowTie: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let knot = r.width * 0.1
        p.move(to: CGPoint(x: r.midX - knot, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        p.move(to: CGPoint(x: r.midX + knot, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath()
        p.addEllipse(in: CGRect(x: r.midX - knot * 1.3, y: r.midY - r.height * 0.28, width: knot * 2.6, height: r.height * 0.56))
        return p
    }
}

/// The headphone band: the top half of a circle, ending level with the ears.
private struct Arc: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                 startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
        return p
    }
}

/// A blueberry's five-point crown.
private struct Crown: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        for i in 0..<5 {
            let x0 = r.minX + r.width * CGFloat(i) / 5
            p.addLine(to: CGPoint(x: x0 + r.width / 10, y: r.minY))
            p.addLine(to: CGPoint(x: x0 + r.width / 5, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// The monocle's chain, hanging off the lens.
private struct Chain: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX * 0.7, y: r.maxY), control: CGPoint(x: r.maxX, y: r.midY * 0.6))
        return p
    }
}

// MARK: contact card

/// What a crew member is for, what it may touch, and how it's doing. Opened from its thread's header.
struct CrewContactCard: View {
    let id: String
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("crewShowTools") private var showTools = false

    private var agent: CrewAgent? { store.crew.agents.first { $0.id == id } }
    private var role: String { agent?.role ?? id.split(separator: "-").first.map(String.init) ?? id }
    private var index: Int { Int(id.split(separator: "-").last ?? "") ?? 1 }
    private var thread: [CrewEvent] { store.crew.threads[id] ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        CrewMascot(role: role, index: index, mood: .init(status: agent?.status ?? "idle"), size: 104)
                            .padding(.vertical, 6)
                        Text(crewName(id)).font(.title.weight(.semibold))
                        Text(Self.blurb(role)).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if let agent {
                            Label(CrewMascot.Mood(status: agent.status).label, systemImage: "circle.fill")
                                .font(.footnote.weight(.medium))
                                .labelStyle(StatusLabel(color: CrewAvatar.color(agent.status)))
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)

                    HStack(spacing: 10) {
                        action("Message", "message.fill") { dismiss() }
                        action("Stop", "stop.fill", disabled: agent?.status != "working") {
                            Task { await store.crew.stop(id) }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section("Can") {
                    ForEach(Self.can(role), id: \.self) { Label($0, systemImage: "checkmark").foregroundStyle(.primary) }
                }
                Section("Can't") {
                    ForEach(Self.cant(role), id: \.self) { Label($0, systemImage: "xmark").foregroundStyle(.secondary) }
                }
                Section {
                    LabeledContent("Model", value: ["pm", "planner"].contains(role) ? "Opus" : "Sonnet")
                    LabeledContent("Messages", value: "\(thread.filter { $0.kind == "message" }.count)")
                    LabeledContent("Tool calls", value: "\(thread.filter { $0.kind == "tool" }.count)")
                    if let at = agent?.lastAt.flatMap(LiveBackend.date) {
                        LabeledContent("Last active", value: shortWhen(at))
                    }
                }
                Section {
                    Toggle("Show tool calls", isOn: $showTools)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func action(_ title: String, _ symbol: String, disabled: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary : Color.blue)
        .disabled(disabled)
    }

    private struct StatusLabel: LabelStyle {
        let color: Color
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon.font(.system(size: 7)).foregroundStyle(color)
                configuration.title.foregroundStyle(.secondary)
            }
        }
    }

    // Mirrors the server's role definitions (otto/crew.ts in otto-core).
    static func blurb(_ role: String) -> String {
        switch role {
        case "pm": "Owns the spec. Checks finished work against it and merges."
        case "planner": "Cuts a feature into tickets, one per file or feature, and hands them out."
        case "designer": "Writes the UI spec the writers build from."
        case "writer": "Takes one ticket, builds it in its own branch, and sends it for review."
        default: "Reviews a writer's diff with fresh eyes. Two rounds, then it goes up."
        }
    }

    static func can(_ role: String) -> [String] {
        switch role {
        case "pm": ["Read code", "Edit markdown", "Look at git history", "Merge crew branches", "Message the crew"]
        case "planner", "designer": ["Read code", "Edit markdown", "Message the crew"]
        case "writer": ["Read code", "Edit code in its worktree", "Build and run tests", "Message the crew"]
        default: ["Read code", "Read diffs and history", "Run tests and builds", "Message the crew"]
        }
    }

    static func cant(_ role: String) -> [String] {
        switch role {
        case "pm": ["Edit code"]
        case "planner", "designer": ["Edit code", "Merge"]
        case "writer": ["Merge", "Touch Otto's own files"]
        default: ["Edit anything", "Merge"]
        }
    }
}
