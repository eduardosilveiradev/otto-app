import SwiftUI
import WidgetKit

/// Otto outside the app: a Home Screen tile that opens the conversation (and says when an approval
/// is waiting on you), a Lock Screen one that opens the walkie-talkie, and a call in progress on the
/// Lock Screen and in the Dynamic Island. The tiles go through the app's own otto:// links (OttoApp's onOpenURL).
@main
struct OttoWidgets: WidgetBundle {
    var body: some Widget {
        OttoChatWidget()
        OttoWalkieWidget()
        OttoWalkieControl()
        OttoCallActivity()
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
        .configurationDisplayName("Otto walkie-talkie")
        .description("Opens the walkie-talkie.")
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

/// Control Center and the Lock Screen's control slots: the walkie-talkie, one press away.
struct OttoWalkieControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.otto.walkie.control") {
            ControlWidgetButton(action: OpenWalkieControl()) {
                Label("Otto walkie-talkie", systemImage: "waveform")
            }
        }
        .displayName("Otto walkie-talkie")
        .description("Opens the walkie-talkie.")
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
            .accessibilityLabel("Walkie-talkie with Otto")
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
