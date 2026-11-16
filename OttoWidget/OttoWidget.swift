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
                .widgetURL(URL(string: "otto://chat"))
        }
        .configurationDisplayName("Message Otto")
        .description("Opens your conversation with Otto.")
        .supportedFamilies([.systemSmall])
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OttoFace(size: ask == nil ? 48 : 40)
            Spacer(minLength: 6)
            if let ask {
                HStack(spacing: 5) {
                    Circle().fill(Color.tangerine).frame(width: 7, height: 7).widgetAccentable()
                    Text("Until \(ask.expires, style: .time)").font(.caption).foregroundStyle(.secondary)
                }
                Text(ask.text).font(.subheadline.weight(.semibold)).lineLimit(3).padding(.top, 2)
            } else {
                Text("Otto").font(.headline)
                Text("Message").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ask.map { "Otto needs you: \($0.text), until \($0.expires.formatted(date: .omitted, time: .shortened))" } ?? "Message Otto")
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
                    Text("Open Otto to mute or hang up").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                CallTime(started: context.state.started).font(.title3)
            }
            .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { OttoFace(size: 36) }
                DynamicIslandExpandedRegion(.center) { Text("Call with Otto").font(.headline) }
                DynamicIslandExpandedRegion(.trailing) { CallTime(started: context.state.started).font(.headline) }
            } compactLeading: {
                OttoFace(size: 22)
            } compactTrailing: {
                CallTime(started: context.state.started).font(.footnote).frame(maxWidth: 44)
            } minimal: {
                OttoFace(size: 22)
            }
        }
    }
}

/// How long the call has run, kept current by the system (m:ss, then h:mm:ss).
struct CallTime: View {
    let started: Date
    var body: some View {
        Text(timerInterval: started...Date.distantFuture, countsDown: false)
            .monospacedDigit().multilineTextAlignment(.trailing)
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
