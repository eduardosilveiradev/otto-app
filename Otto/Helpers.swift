import SwiftUI

// Helpers: the subagents Otto hands parts of a turn to. The socket's "helpers" frame lists them whole each
// time, and keeps coming after the turn is over for as long as one still works:
//   {"type":"helpers","helpers":[{"id","label","state":"working"|"done"|"failed","step"?,"startedAt","endedAt"?,
//     "error"?,"steps":[{"label","ts"}]}]}
// A done one leaves the list 6 s after it ended; a failed one stays until the app says it was seen
// ({"type":"helpers.seen","id"}, sent when the sheet opens). While Otto works they are rows in the thinking
// bubble; after the reply, a capsule over the composer that opens them in a sheet. With no frame ever (an
// older server) none of this shows.

/// One helper as the server sends it. Only an id (or, failing that, a label) is required: an unknown state
/// counts as working, and a field that's missing or the wrong type is left empty rather than losing the frame.
struct Helper: Identifiable, Hashable {
    enum Status: Hashable {
        case working, done, failed
        init(_ wire: String?) {
            switch wire {
            case "done": self = .done
            case "failed": self = .failed
            default: self = .working   // "working", and anything newer this build doesn't know
            }
        }
    }
    struct Step: Hashable { var label: String; var at: Date? }

    let id: String
    var label: String
    var state: Status
    /// What it is doing right now.
    var step: String? = nil
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    var error: String? = nil
    var steps: [Step] = []

    /// How long a done one stays, dimmed, before it leaves.
    static let linger: TimeInterval = 6
    var leavesAt: Date? { state == .done ? endedAt.map { $0 + Self.linger } : nil }

    /// Time at it: still counting while it works, held at its end once it's over. Nil when that can't be known.
    func elapsed(at now: Date) -> TimeInterval? {
        guard let startedAt, let end = state == .working ? now : endedAt else { return nil }
        return max(0, end.timeIntervalSince(startedAt))   // a phone clock behind the Mac's never shows a negative time
    }

    /// The row's second line.
    var line: String? {
        switch state {
        case .working: step
        case .done: String(localized: "Done")
        case .failed: error.map { String(localized: "Stopped: \($0)") } ?? String(localized: "Stopped")
        }
    }

    /// What's still listed at `now`: a done one goes once its 6 s are up.
    static func shown(_ list: [Helper], at now: Date) -> [Helper] { list.filter { $0.leavesAt.map { $0 > now } ?? true } }

    /// The capsule's words: "3 working", "1 working · 1 stopped". Nil when only done ones are left.
    static func summary(_ list: [Helper]) -> String? {
        let working = list.count { $0.state == .working }, failed = list.count { $0.state == .failed }
        let parts = [working > 0 ? String(localized: "\(working) working") : nil, failed > 0 ? String(localized: "\(failed) stopped") : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// m:ss, or h:mm:ss from an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Helper: Decodable {
    private enum Keys: String, CodingKey { case id, label, state, step, startedAt, endedAt, error, steps }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ k: Keys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)).flatMap { $0.isEmpty ? nil : $0 } }
        guard let id = text(.id) ?? text(.label) else { throw DecodingError.dataCorrupted(.init(codingPath: [Keys.id], debugDescription: "a helper with no id")) }
        self.id = id
        label = text(.label) ?? String(localized: "Helper")
        state = Status(text(.state))
        step = text(.step); error = text(.error)
        startedAt = wireDate(c, .startedAt); endedAt = wireDate(c, .endedAt)
        steps = ((try? c.decodeIfPresent([Maybe<Step>].self, forKey: .steps)) ?? []).compactMap(\.value)
    }
}

extension Helper.Step: Decodable {
    private enum Keys: String, CodingKey { case label, text, ts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? (try? c.decodeIfPresent(String.self, forKey: .text)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [Keys.label], debugDescription: "a step with no words"))
        }
        self.label = label
        at = wireDate(c, .ts)
    }
}

/// The "helpers" frame. One helper that won't decode is left out; the rest still arrive. A frame without the
/// list at all is refused, so it can't empty what's shown.
struct HelperFrame: Decodable {
    let helpers: [Helper]
    private enum Keys: String, CodingKey { case helpers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.contains(.helpers) else { throw DecodingError.keyNotFound(Keys.helpers, .init(codingPath: [], debugDescription: "no list")) }
        var ids = Set<String>()
        helpers = ((try? c.decodeIfPresent([Maybe<Helper>].self, forKey: .helpers)) ?? []).compactMap(\.value).filter { ids.insert($0.id).inserted }
    }
}

private struct Maybe<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// An ISO string, or epoch seconds or milliseconds.
private func wireDate<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ k: K) -> Date? {
    if let s = try? c.decodeIfPresent(String.self, forKey: k) { return LiveBackend.date(s) }
    if let n = try? c.decodeIfPresent(Double.self, forKey: k) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
    return nil
}

// MARK: - The mark

/// Where a helper stands, drawn as the Mac app draws it on jobs: working is a 3×3 matrix of dots that
/// twinkle, done a solid dot, failed a circled X. A change of state cross-fades the marks; under Reduce
/// Motion the dots hold still and the change is opacity only.
struct StatusMark: View {
    let state: Helper.Status
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var still

    static let working = Color(red: 0x0E / 255, green: 0xA5 / 255, blue: 0xE9 / 255)
    static let done = Color(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255)
    static let failed = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    /// Each dot's head start into its 2.4 s cycle (the Mac's negative animation-delays), row by row.
    static let offsets: [Double] = [0, 1.6, 0.8, 2.0, 0.4, 1.2, 2.2, 0.6, 1.4]
    /// Full for the first half of its cycle, 30% for the second, stepping rather than fading.
    static func lit(_ dot: Int, at t: Double) -> Bool { (t + offsets[dot]).truncatingRemainder(dividingBy: 2.4) < 1.2 }

    var body: some View {
        ZStack {
            Group {
            // Every step lands on a multiple of 0.2 s, so this ticks exactly when a dot changes and no oftener.
            if state == .working && !still {
                TimelineView(.periodic(from: .init(timeIntervalSinceReferenceDate: 0), by: 0.2)) { tl in
                    mark(at: tl.date.timeIntervalSinceReferenceDate)
                }
            } else {
                mark(at: 0)
            }
            }
            .id(state)
            .transition(still ? .opacity : .opacity.combined(with: .scale(scale: 0.25)).combined(with: .modifier(active: Blurred(radius: 4), identity: Blurred(radius: 0))))
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.3, bounce: 0), value: state)
        .accessibilityHidden(true)
    }

    private func mark(at t: Double) -> some View {
        Canvas { ctx, box in
            switch state {
            case .working:   // the Mac's 16-unit box: dots of radius 1.4 at 3.5, 8 and 12.5
                let u = box.width / 16, at: [Double] = [3.5, 8, 12.5]
                for i in 0..<9 {
                    let r = CGRect(x: (at[i % 3] - 1.4) * u, y: (at[i / 3] - 1.4) * u, width: 2.8 * u, height: 2.8 * u)
                    ctx.fill(Path(ellipseIn: r), with: .color(Self.working.opacity(Self.lit(i, at: t) ? 1 : 0.3)))
                }
            case .done:      // a dot of radius 3.5 in the same box
                let u = box.width / 16
                ctx.fill(Path(ellipseIn: CGRect(x: 4.5 * u, y: 4.5 * u, width: 7 * u, height: 7 * u)), with: .color(Self.done))
            case .failed:    // a 24-unit box: a ring of radius 10 and an X, stroked 2
                let u = box.width / 24
                var p = Path(ellipseIn: CGRect(x: 2 * u, y: 2 * u, width: 20 * u, height: 20 * u))
                p.move(to: CGPoint(x: 15 * u, y: 9 * u)); p.addLine(to: CGPoint(x: 9 * u, y: 15 * u))
                p.move(to: CGPoint(x: 9 * u, y: 9 * u)); p.addLine(to: CGPoint(x: 15 * u, y: 15 * u))
                ctx.stroke(p, with: .color(Self.failed), style: StrokeStyle(lineWidth: 2 * u, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - A row

/// One helper: its mark, its name and its time on the first line, what it is doing on the second.
/// The bubble and the sheet both draw these.
struct HelperRow: View {
    let helper: Helper
    /// How far above the first line's baseline the mark's centre sits: on the name's x-height.
    @ScaledMetric(relativeTo: .subheadline) private var lift: CGFloat = 5

    var body: some View {
        TimelineView(.periodic(from: helper.startedAt ?? .now, by: 1)) { tl in
            row(elapsed: helper.elapsed(at: tl.date))
        }
    }

    private func row(elapsed: TimeInterval?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusMark(state: helper.state)
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 + lift }
            VStack(alignment: .leading, spacing: 2) {
                // The time stays on the name's first line; a long name wraps to two before it's cut.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(helper.label)
                        .font(size: 15, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let elapsed {
                        Text(Helper.clock(elapsed))
                            .font(size: 13, relativeTo: .footnote).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if let line = helper.line {
                    Text(line)
                        .font(size: 13, relativeTo: .footnote)
                        .foregroundStyle(helper.state == .failed ? AnyShapeStyle(Color.redInk) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        // A new step cross-fades in over the last.
                        .contentTransition(.opacity)
                }
            }
        }
        // Done: dimmed for the few seconds before it leaves.
        .opacity(helper.state == .done ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.2), value: helper.line)
        .animation(.easeOut(duration: 0.25), value: helper.state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(elapsed))
    }

    /// "Tests, working, 2 minutes, 14 seconds, Running the suite".
    private func spoken(_ elapsed: TimeInterval?) -> String {
        let word = switch helper.state {
        case .working: String(localized: "working")
        case .done: String(localized: "done")
        case .failed: String(localized: "stopped")
        }
        let time = elapsed.map { Duration.seconds(Int($0)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)) }
        let detail = helper.state == .failed ? helper.error : helper.state == .working ? helper.step : nil
        return [helper.label, word, time, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The rows inside the thinking bubble, under Otto's own step.
struct HelperList: View {
    let helpers: [Helper]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(helpers) { HelperRow(helper: $0).transition(.opacity) }
        }
    }
}

// MARK: - After the reply

/// Helpers still at it once Otto has answered: "3 working" in a small capsule over the composer.
/// The failed mark takes over while one has stopped, since that one waits on you to see it.
struct HelperCapsule: View {
    let helpers: [Helper]
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        if let text = Helper.summary(helpers) {
            Button(action: open) {
                HStack(spacing: 7) {
                    StatusMark(state: helpers.contains { $0.state == .failed } ? .failed : .working)
                    Text(text).monospacedDigit()
                        .contentTransition(still ? .opacity : .numericText())
                }
                .font(size: 14, weight: .medium, relativeTo: .footnote)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                // 44pt to tap, reaching into the gap above the box rather than up into the thread.
                .padding(.bottom, 10).contentShape(.rect).padding(.bottom, -10)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .animation(.snappy(duration: 0.22), value: text)
            .accessibilityLabel(String(localized: "Helpers: \(text)"))
            .accessibilityHint("Shows what they are doing")
            #if DEBUG
            // `-helpersOpen`: opened once it's on screen; a sheet that starts out open never shows from the composer.
            .task { if ProcessInfo.processInfo.arguments.contains("-helpersOpen") { try? await Task.sleep(for: .seconds(1)); open() } }
            #endif
        }
    }
}

/// The capsule, opened: the same rows in a list, each one opening on its steps so far. Failed ones are told
/// to the Mac as seen while this is open, and stay here until it closes even once the Mac has let them go.
struct HelperSheet: View {
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var kept: [Helper] = []
    @State private var open: Set<String> = ProcessInfo.processInfo.arguments.contains("-helpersStepsOpen") ? ["sample-tests"] : []

    private var failed: [Helper] { store.helpers.filter { $0.state == .failed } }
    private var rows: [Helper] { store.helpers + kept.filter { k in !store.helpers.contains { $0.id == k.id } } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { h in
                        Button { withAnimation(.snappy(duration: 0.22)) { open.formSymmetricDifference([h.id]) } } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HelperRow(helper: h)
                                if open.contains(h.id) { steps(h).transition(.opacity) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(open.contains(h.id) ? "Hides its steps" : "Shows its steps so far")
                    }
                } footer: {
                    Text("Tap one to see its steps so far.")
                }
            }
            .listStyle(.insetGrouped)
            .animation(.snappy(duration: 0.22), value: rows.map(\.id))
            .navigationTitle("In the background").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close", systemImage: "xmark") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: failed.map(\.id), initial: true) {
            kept += failed.filter { f in !kept.contains { $0.id == f.id } }
            store.sawHelpers()
        }
        // The last one gone: nothing left to show.
        .onChange(of: rows.isEmpty) { if rows.isEmpty { dismiss() } }
    }

    /// What it did so far, oldest first, each at its time into the run.
    private func steps(_ h: Helper) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if h.steps.isEmpty {
                Text("No steps yet.").font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(h.steps.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(s.at.flatMap { at in h.startedAt.map { Helper.clock(max(0, at.timeIntervalSince($0))) } } ?? "")
                        .font(size: 13, relativeTo: .footnote).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 38, alignment: .leading)
                    Text(s.label).font(size: 13, relativeTo: .footnote).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Lined up under the name, past the mark.
        .padding(.leading, 22)
    }
}

// MARK: - Sample data and the check

#if DEBUG
extension Helper {
    /// `-helpers <set>`: live (three at work, Otto typing), after (the reply is in, three still at work),
    /// mixed (one done, one stopped, one still at work, the reply in), one, eight, and worst (long names,
    /// an hour-long run, a long error, a state this build doesn't know).
    static func sample(_ set: String, now: Date = .now) -> [Helper] {
        func ago(_ s: Double) -> Date { now - s }
        func steps(_ labels: [String], from start: Double) -> [Step] {
            labels.enumerated().map { i, l in Step(label: l, at: ago(start - Double(i) * start / Double(labels.count))) }
        }
        let notes = Helper(id: "sample-notes", label: "Meeting notes", state: .working, step: "Pulling out the action items",
                           startedAt: ago(134), steps: steps(["Reading the three transcripts", "Matching names to the invite list", "Pulling out the action items"], from: 134))
        let prices = Helper(id: "sample-prices", label: "Flight prices", state: .working, step: "Checking the airline’s own site",
                            startedAt: ago(98), steps: steps(["Searching three booking sites", "Checking the airline’s own site"], from: 98))
        let tests = Helper(id: "sample-tests", label: "Failing tests", state: .working, step: "Running the three failing tests",
                           startedAt: ago(71), steps: steps(["Cloning the project", "Installing what it needs", "Running the three failing tests"], from: 71))
        switch set {
        case "mixed":
            // The done one ends in the future so a screenshot taken seconds after launch still has it.
            var d = notes; d.state = .done; d.endedAt = now + 30; d.step = nil
            var f = tests; f.state = .failed; f.endedAt = ago(20); f.error = "the test machine didn’t answer"
            return [d, prices, f]
        case "one": return [prices]
        case "eight":
            let names = ["Receipts", "Gym timetable", "Car insurance", "Holiday dates", "Book list", "Printer drivers"]
            return [notes, prices] + names.enumerated().map { i, n in
                Helper(id: "sample-\(i)", label: n, state: .working, step: "Reading what’s there", startedAt: ago(Double(20 + i * 9)))
            }
        case "worst":
            return [
                Helper(id: "worst-long", label: "Compare the renewal quotes from all four home insurers against last year’s policy, line by line",
                       state: .working, step: "Reading the exclusions on page 14 of the second quote, which runs to forty pages of small print",
                       startedAt: ago(3754)),
                Helper(id: "worst-unknown", label: "Tidy", state: .init("paused-by-host"), startedAt: ago(5)),
                Helper(id: "worst-nostart", label: "Plan the week", state: .working),
                Helper(id: "worst-failed", label: "Back up the photo library to the external drive",
                       state: .failed, startedAt: ago(900), endedAt: ago(30),
                       error: "the drive was unplugged halfway through, and after three tries the copy gave up with 2,481 photos left"),
                Helper(id: "worst-script", label: "領収書を月ごとに整理する", state: .working, step: "三月分を読んでいます", startedAt: ago(61)),
            ]
        default: return [notes, prices, tests]
        }
    }
}

/// Run with `-helpersCheck`; it asserts, prints "helpers check ok" and carries on.
enum HelpersCheck {
    static func run() {
        func frame(_ json: String) -> [Helper]? { try? JSONDecoder().decode(HelperFrame.self, from: Data(json.utf8)).helpers }
        let full = frame(#"""
        {"type":"helpers","helpers":[
          {"id":"a","label":"Notes","state":"working","step":"Reading","startedAt":"2026-11-22T10:00:00Z","steps":[{"label":"Opened","ts":"2026-11-22T10:00:05Z"}]},
          {"id":"b","label":"Tests","state":"failed","startedAt":"2026-11-22T10:00:00.250Z","endedAt":1795341720000,"error":"no answer"},
          {"id":"c","state":"paused-by-host"},
          {"label":"No id"},
          {"state":"done"},
          {"id":"a","label":"Again"},
          {"id":"d","label":"Odd","state":7,"step":3,"startedAt":"yesterday","steps":[{"ts":1},{"text":"Old shape"}]}
        ]}
        """#)
        assert(full?.map(\.id) == ["a", "b", "c", "No id", "d"], "one bad helper drops alone, a repeat id doesn't come twice")
        assert(full?[0].state == .working && full?[0].steps.first?.label == "Opened" && full?[0].steps.first?.at != nil && full?[0].startedAt != nil, "a whole one")
        assert(full?[1].state == .failed && full?[1].startedAt != nil && full?[1].endedAt == Date(timeIntervalSince1970: 1_795_341_720), "fractions and epoch ms")
        assert(full?[2].state == .working && full?[2].label == "Helper", "an unknown state counts as working; no label reads Helper")
        assert(full?[4].state == .working && full?[4].step == nil && full?[4].startedAt == nil && full?[4].steps.map(\.label) == ["Old shape"], "wrong types are left empty")
        assert(frame(#"{"type":"helpers","helpers":[]}"#)?.isEmpty == true && frame(#"{"type":"helpers","helpers":null}"#)?.isEmpty == true, "none left")
        assert(frame(#"{"type":"helpers"}"#) == nil && frame(#"{"type":"helpers","helpers":"x"}"#)?.isEmpty == true, "no list is no frame")

        let t = Date(timeIntervalSince1970: 1_000_000)
        func h(_ id: String, _ s: Helper.Status, ended: Double? = nil, error: String? = nil) -> Helper {
            Helper(id: id, label: id, state: s, startedAt: t - 134, endedAt: ended.map { t + $0 }, error: error)
        }
        assert(Helper.summary([h("a", .working), h("b", .working), h("c", .working)]) == "3 working", "three at work")
        assert(Helper.summary([h("a", .working), h("b", .done, ended: 0), h("c", .failed)]) == "1 working · 1 stopped", "mixed")
        assert(Helper.summary([h("c", .failed)]) == "1 stopped" && Helper.summary([h("b", .done, ended: 0)]) == nil && Helper.summary([]) == nil, "nothing to show")

        let done = h("b", .done, ended: 0)
        assert(Helper.shown([done], at: t + 5.9).count == 1 && Helper.shown([done], at: t + 6).isEmpty, "a done one leaves 6 s after it ended")
        assert(Helper.shown([h("c", .failed, ended: 0), h("x", .done)], at: t + 3600).count == 2, "a stopped one stays; a done one with no end waits for the Mac")
        assert(done.leavesAt == t + 6 && h("a", .working).leavesAt == nil, "leavesAt")

        assert(h("a", .working).elapsed(at: t) == 134 && done.elapsed(at: t + 999) == 134 && h("x", .done).elapsed(at: t) == nil, "elapsed counts, then holds")
        assert(Helper(id: "s", label: "s", state: .working, startedAt: t + 5).elapsed(at: t) == 0, "a clock behind the Mac's shows 0:00")
        assert(Helper.clock(0) == "0:00" && Helper.clock(134.9) == "2:14" && Helper.clock(3599) == "59:59" && Helper.clock(3754) == "1:02:34", "the clock")
        assert(h("c", .failed, error: "no answer").line == "Stopped: no answer" && h("c", .failed).line == "Stopped" && done.line == "Done", "the second line")

        assert((0..<9).map { StatusMark.lit($0, at: 0) } == [true, false, true, false, true, false, false, true, false], "the matrix at rest")
        assert((0..<9).allSatisfy { StatusMark.lit($0, at: 7.2) == StatusMark.lit($0, at: 0) }, "a 2.4 s cycle")
        print("helpers check ok")
    }
}
#endif
