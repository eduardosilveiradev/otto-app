import SwiftUI
import WidgetKit

/// Otto outside the app: a Home Screen tile that opens the conversation (and says when an approval
/// is waiting on you), a Lock Screen one that opens talk mode, and a call or a talk in progress on the Lock
/// Screen and in the Dynamic Island. The tiles go through the app's own otto:// links (OttoApp's onOpenURL).
@main
struct OttoWidgets: WidgetBundle {
    var body: some Widget {
        OttoChatWidget()
        OttoArrivingWidget()
        OttoWalkieWidget()
        OttoWalkieControl()
        OttoCallActivity()
        OttoTalkActivity()
        OttoFlightActivity()
    }
}

struct DoorEntry: TimelineEntry {
    let date: Date
    /// An approval waiting on you, from the app; nil once the Mac would have dropped it.
    var ask: WidgetData.Ask? = nil
}

/// The app reloads the tile when what's waiting changes; the timeline itself only has to clear it at its expiry.
struct DoorProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoorEntry { DoorEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (DoorEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DoorEntry>) -> Void) {
        let now = entry()
        guard let ask = now.ask else { return completion(Timeline(entries: [now], policy: .never)) }
        completion(Timeline(entries: [now, DoorEntry(date: ask.expires)], policy: .never))
    }
    private func entry() -> DoorEntry {
        DoorEntry(date: .now, ask: WidgetData.ask.flatMap { $0.expires > .now ? $0 : nil })
    }
}

struct OttoChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.otto.chat", provider: DoorProvider()) { entry in
            ChatDoor(ask: entry.ask)
                .containerBackground(.background, for: .widget)
                // With an approval waiting, straight to its sheet; otherwise the thread.
                .widgetURL(URL(string: entry.ask == nil ? "otto://chat" : "otto://approval"))
        }
        .configurationDisplayName("Message Otto")
        .description("Opens your conversation with Otto, and shows an approval waiting on you.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct OttoWalkieWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.otto.walkie", provider: WalkieProvider()) { _ in
            WalkieDoor()
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
                .widgetURL(URL(string: "otto://walkie"))
        }
        .configurationDisplayName("Talk with Otto")
        .description("Opens talk mode: talk hands-free, and Otto answers out loud.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// The round Lock Screen one never changes.
struct WalkieProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoorEntry { DoorEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (DoorEntry) -> Void) { completion(DoorEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DoorEntry>) -> Void) {
        completion(Timeline(entries: [DoorEntry(date: .now)], policy: .never))
    }
}

/// The small tile: the face and the name, and under them what a tap does, or, when an approval is
/// waiting, what it asks and until when (tangerine marks what needs you; the rest is the text colours).
struct ChatDoor: View {
    var ask: WidgetData.Ask?
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if family == .accessoryRectangular { lockScreen } else { tile }
    }

    /// The Lock Screen's line: who, and what's waiting (hidden while locked, as below) or what a tap does.
    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                OttoEyes(size: 18, colour: .primary).frame(width: 18, height: 18)
                Text(ask == nil ? "Otto" : "Otto needs you").font(.headline).widgetAccentable()
            }
            if let ask {
                Text(ask.text).font(.subheadline).lineLimit(1).privacySensitive()
                Text("Until \(ask.expires, style: .time)").font(.caption)
            } else {
                Text("Message").font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DoorLabel(waiting: ask != nil))
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            OttoFace(size: ask == nil ? 48 : 40)
            Spacer(minLength: 6)
            if let ask {
                HStack(spacing: 5) {
                    Circle().fill(Color.tangerine).frame(width: 7, height: 7).widgetAccentable()
                        .accessibilityLabel("Otto needs you")
                    Text("Until \(ask.expires, style: .time)").font(.caption).foregroundStyle(.secondary)
                }
                // What it asks (an amount, a payee) is hidden while the phone is locked, as in StandBy.
                Text(ask.text).font(.subheadline.weight(.semibold)).lineLimit(3).padding(.top, 2).privacySensitive()
            } else {
                Text("Otto").font(.headline)
                Text("Message").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .modifier(DoorLabel(waiting: ask != nil))
    }
}

/// What VoiceOver reads. With something waiting it reads the tile's own texts (the dot says "Otto needs you"),
/// so what it asks keeps their privacy (hidden while locked); one label written over them would read it regardless.
struct DoorLabel: ViewModifier {
    let waiting: Bool
    func body(content: Content) -> some View {
        if waiting {
            content.accessibilityElement(children: .combine)
        } else {
            content.accessibilityElement(children: .ignore).accessibilityLabel("Message Otto")
        }
    }
}

struct ArrivingEntry: TimelineEntry {
    let date: Date
    var parcels: [WidgetData.Arriving.Parcel] = []
}

/// The app writes today's packages and reloads this; the timeline itself only has to clear them at midnight.
struct ArrivingProvider: TimelineProvider {
    /// For the widget gallery and the placeholder only.
    private let sample = ArrivingEntry(date: .now, parcels: [.init(id: "sample", what: "Running shoes", carrier: "DHL", out: true)])
    func placeholder(in context: Context) -> ArrivingEntry { sample }
    func getSnapshot(in context: Context, completion: @escaping (ArrivingEntry) -> Void) {
        let now = entry().0
        completion(context.isPreview && now.parcels.isEmpty ? sample : now)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ArrivingEntry>) -> Void) {
        let (now, until) = entry()
        completion(Timeline(entries: until.map { [now, ArrivingEntry(date: $0)] } ?? [now], policy: .never))
    }
    private func entry() -> (ArrivingEntry, Date?) {
        guard let a = WidgetData.arriving, a.until > .now, !a.parcels.isEmpty else { return (ArrivingEntry(date: .now), nil) }
        return (ArrivingEntry(date: .now, parcels: a.parcels), a.until)
    }
}

struct OttoArrivingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.otto.arriving", provider: ArrivingProvider()) { entry in
            ArrivingDoor(parcels: entry.parcels)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "otto://packages"))
        }
        .configurationDisplayName("Arriving today")
        .description("Shows a package that’s out for delivery or due today, and its carrier.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

/// What's coming today and who brings it; a tap opens Packages, where Mark delivered is. Tangerine marks a day
/// with something to stay in for. Item names show while the phone is locked (that glance is the point), tracking
/// numbers never: the app doesn't hand them over.
struct ArrivingDoor: View {
    let parcels: [WidgetData.Arriving.Parcel]
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let lock = family == .accessoryRectangular
        VStack(alignment: .leading, spacing: lock ? 1 : 2) {
            if !lock {
                Image(systemName: "shippingbox.fill").font(.title2)
                    .foregroundStyle(parcels.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.tangerine))
                    .widgetAccentable().accessibilityHidden(true)
                Spacer(minLength: 6)
            }
            HStack(spacing: 4) {
                if lock { Image(systemName: "shippingbox.fill").imageScale(.small).accessibilityHidden(true) }
                Text(parcels.isEmpty ? "Packages" : parcels.count > 2 ? "\(parcels.count) arriving today" : "Arriving today")
            }
            .font(.headline).lineLimit(1).minimumScaleFactor(0.75).widgetAccentable()   // shrinks a little at the largest sizes before it's cut
            if parcels.isEmpty {
                Text("Nothing today").font(.subheadline).foregroundStyle(.secondary)
            } else if parcels.count == 1, let p = parcels.first {
                Text(p.what).font(.subheadline).lineLimit(lock ? 1 : 2)
                Text(p.out ? "\(p.carrier) · Out for delivery" : p.carrier).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            } else {
                // One line each. Item and carrier share the width, so a long carrier ("Poste Italiane") can't squeeze the item out.
                ForEach(parcels.prefix(2)) { p in
                    HStack(spacing: 0) {
                        Text(p.what).lineLimit(1)
                        Text(" · \(p.carrier)").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.subheadline)
                    // Read as "Desk lamp, UPS", whole, not the dot as a fragment of its own.
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(p.what), \(p.carrier)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: lock ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Control Center and the Lock Screen's control slots: talk mode, one press away. Kinds keep the walkie-talkie's
/// names, so the widgets and controls people already placed open talk now.
struct OttoWalkieControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.otto.walkie.control") {
            ControlWidgetButton(action: OpenWalkieControl()) {
                Label("Talk with Otto", systemImage: "waveform")
            }
        }
        .displayName("Talk with Otto")
        .description("Opens talk mode.")
    }
}

/// A web call with Otto while it lasts: the face and how long it's run, on the Lock Screen and in the Dynamic Island.
struct OttoCallActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            HStack(spacing: 12) {
                OttoFace(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Call with Otto").font(.headline)
                    CallTime(started: context.state.started, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                CallButtons(muted: context.state.muted)
            }
            .padding(16)
            // Dark in either appearance, as the Phone app's own call is: the buttons are drawn for it.
            .environment(\.colorScheme, .dark)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { OttoFace(size: 36) }
                DynamicIslandExpandedRegion(.center) { Text("Call with Otto").font(.headline) }
                DynamicIslandExpandedRegion(.trailing) { CallTime(started: context.state.started).font(.headline) }
                DynamicIslandExpandedRegion(.bottom) { CallButtons(muted: context.state.muted) }
            } compactLeading: {
                OttoFace(size: 22)
            } compactTrailing: {
                // Room for h:mm:ss after the first hour, shrinking a little rather than cutting the time off.
                CallTime(started: context.state.started).font(.footnote).minimumScaleFactor(0.75).frame(maxWidth: 56)
            } minimal: {
                OttoFace(size: 22)
            }
        }
    }
}

/// A talk with Otto while you're elsewhere: where it's got to, Otto's words or its latest step, how long it's
/// run, and Mute and End. A tap brings the talk back up (otto://walkie, talk's door).
struct OttoTalkActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TalkActivityAttributes.self) { context in
            HStack(spacing: 12) {
                OttoFace(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        if context.state.sharing { Sees() }
                        CallTime(started: context.state.started, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                    }
                    // Otto's words can name what it's reading or buying: hidden while the phone is locked.
                    if !context.state.line.isEmpty {
                        Text(context.state.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).privacySensitive()
                    }
                }
                Spacer(minLength: 8)
                TalkButtons(muted: context.state.muted)
            }
            .padding(16)
            .environment(\.colorScheme, .dark)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "otto://walkie"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { OttoFace(size: 36) }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 6) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        if context.state.sharing { Sees() }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) { CallTime(started: context.state.started).font(.headline) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(context.state.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading).privacySensitive()
                        TalkButtons(muted: context.state.muted)
                    }
                }
            } compactLeading: {
                OttoFace(size: 22)
            } compactTrailing: {
                Image(systemName: context.state.symbol).accessibilityLabel(context.state.title)
            } minimal: {
                OttoFace(size: 22)
            }
            .widgetURL(URL(string: "otto://walkie"))
        }
    }
}

/// Today's flight: the gate, terminal, seat and time to departure, with what flight status says, kept current by
/// the app (GateWatch). Dark in either appearance, as the call and the talk are. A tap opens the thread, whose
/// banner holds the pass.
struct OttoFlightActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FlightName(flight: context.attributes)
                    Spacer(minLength: 8)
                    FlightStatus(state: context.state).layoutPriority(1)
                }
                FlightFacts(state: context.state, over: context.isStale)
            }
            .padding(16)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)   // inside the Lock Screen's 160pt
            .environment(\.colorScheme, .dark)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "otto://chat"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { FlightName(flight: context.attributes, stacked: true) }
                DynamicIslandExpandedRegion(.trailing) { FlightStatus(state: context.state) }
                DynamicIslandExpandedRegion(.bottom) { FlightFacts(state: context.state, over: context.isStale).padding(.top, 8) }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: "airplane")
                    if let gate = context.state.gate { Text(gate).fontWeight(.semibold) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(context.state.gate.map { "Gate \($0)" } ?? "Flight \(context.attributes.flight)")
            } compactTrailing: {
                FlightClock(state: context.state, over: context.isStale).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "airplane").accessibilityLabel("Flight \(context.attributes.flight)")
            }
            .widgetURL(URL(string: "otto://chat"))
        }
    }
}

/// "TA 482  SFO → JFK", or the two on their own lines in the island's narrow corner.
struct FlightName: View {
    let flight: FlightActivityAttributes
    var stacked = false
    private var route: String? {
        guard let from = flight.from, let to = flight.to else { return flight.from ?? flight.to }
        return "\(from) → \(to)"
    }
    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    name
                    if let route { Text(route).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                // Beside a long status the route gives way, not the flight number.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        name
                        if let route { Text(route).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    name
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Flight \(flight.flight)", flight.from.flatMap { f in flight.to.map { "\(f) to \($0)" } }].compactMap { $0 }.joined(separator: ", "))
    }
    private var name: some View { Label(flight.flight, systemImage: "airplane.departure").font(.headline) }
}

/// What flight status says, in the boarding pass's colours for a dark ground.
struct FlightStatus: View {
    let state: FlightActivityAttributes.ContentState
    var body: some View {
        Text(state.status)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
    }
    private var ink: Color {
        switch state.tone {
        case .ok: Color(red: 0.447, green: 0.839, blue: 0.690)    // #72D6B0
        case .late: .tangerine                                     // a delay needs you
        case .bad: Color(red: 0.976, green: 0.439, blue: 0.400)   // #F97066
        case .quiet: .secondary
        }
    }
}

/// Gate, terminal and seat, and the time to departure.
struct FlightFacts: View {
    let state: FlightActivityAttributes.ContentState
    /// Past departure (the content's stale date): the time, not a countdown.
    let over: Bool
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 20) {
            fact("Gate", state.gate)
            fact("Terminal", state.terminal)
            fact("Seat", state.seat)
            VStack(alignment: .trailing, spacing: 2) {
                // The banner's words: "09:25, was 08:45" when it moved.
                Text(FlightClock.counting(state, over: over) ? state.was.map { "\(state.time), was \($0)" } ?? "Departs \(state.time)" : "Departs")
                    .font(.caption).foregroundStyle(.secondary)
                FlightClock(state: state, over: over).font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func fact(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.title2.weight(.semibold))
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(title) \($0)" } ?? "\(title) not known yet")
    }
}

/// The countdown to departure, kept by the system; once it's gone (or the flight's cancelled), the time instead.
struct FlightClock: View {
    let state: FlightActivityAttributes.ContentState
    let over: Bool
    static func counting(_ s: FlightActivityAttributes.ContentState, over: Bool) -> Bool { !over && s.tone != .bad }
    var body: some View {
        if Self.counting(state, over: over) {
            // From no later than the end: a range past its end would trap if the view draws after departure.
            Text(timerInterval: min(.now, state.departs)...state.departs, countsDown: true)
                .monospacedDigit().multilineTextAlignment(.trailing)
        } else {
            Text(state.time).monospacedDigit()
        }
    }
}

/// Otto sees your screen: a phone beside the talk's title, as the compact island shows it.
struct Sees: View {
    var body: some View {
        Image(systemName: "iphone").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityLabel("Otto sees your screen")
    }
}

/// Mute and End for a talk, drawn as the call's are.
struct TalkButtons: View {
    let muted: Bool
    var body: some View {
        HStack(spacing: 12) {
            Button(intent: MuteOttoTalk()) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.title3).foregroundStyle(muted ? Color.black : Color.white)
                    .frame(width: 44, height: 44)
                    .background(muted ? Color.white : Color.white.opacity(0.2), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            Button(intent: EndOttoTalk()) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.red, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End talk")
        }
    }
}

/// Mute and hang up, as the Phone app draws them: a white disc while muted, red to end. They run in the app,
/// which the call's audio keeps alive (WidgetData's LiveActivityIntents).
struct CallButtons: View {
    let muted: Bool
    var body: some View {
        HStack(spacing: 12) {
            Button(intent: MuteOttoCall()) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.title3).foregroundStyle(muted ? Color.black : Color.white)
                    .frame(width: 44, height: 44)
                    .background(muted ? Color.white : Color.white.opacity(0.2), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            Button(intent: HangUpOttoCall()) {
                Image(systemName: "phone.down.fill")
                    .font(.title3).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.red, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hang up")
        }
    }
}

/// How long the call has run, kept current by the system (m:ss, then h:mm:ss).
struct CallTime: View {
    let started: Date
    /// A timer's text takes all the width it's offered, so this says which side of it the time sits on.
    var alignment: TextAlignment = .trailing
    var body: some View {
        Text(timerInterval: started...Date.distantFuture, countsDown: false)
            .monospacedDigit().multilineTextAlignment(alignment)
    }
}

/// The Lock Screen's round one: Otto's eyes on the system's disc, in whatever tint the Lock Screen gives it.
struct WalkieDoor: View {
    var body: some View {
        OttoEyes(size: 44, colour: .primary)
            .accessibilityLabel("Talk with Otto")
    }
}

/// Otto's face, drawn: a tangerine disc and two capsule eyes, in the header face's proportions.
struct OttoFace: View {
    let size: CGFloat
    var body: some View {
        Circle().fill(Color.tangerine)
            // A tinted or clear Home Screen draws the disc in its accent and the eyes in its other tone, so they stay apart.
            .widgetAccentable()
            .overlay { OttoEyes(size: size, colour: Color(white: 0.125)) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Color {
    /// #FF7C1A, the face's own tangerine.
    static let tangerine = Color(red: 1, green: 0.486, blue: 0.102)
}

/// Two capsule eyes as the header's face draws them on its sphere (measured off a screenshot): about
/// an eighth of the face wide, under a third tall, a little above the middle. The icon's are smaller, for a square.
struct OttoEyes: View {
    let size: CGFloat
    let colour: Color
    var body: some View {
        HStack(spacing: size * 0.13) {
            Capsule().fill(colour).frame(width: size * 0.13, height: size * 0.28)
            Capsule().fill(colour).frame(width: size * 0.13, height: size * 0.28)
        }
        .offset(y: -size * 0.03)
    }
}
