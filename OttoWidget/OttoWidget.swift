import SwiftUI
import WidgetKit

/// Otto outside the app: a Home Screen tile that opens the conversation, and a Lock Screen one
/// that opens the walkie-talkie. Doors, not dashboards: nothing to fetch, so nothing goes stale,
/// and both go through the app's own otto:// links (OttoApp's onOpenURL).
@main
struct OttoWidgets: WidgetBundle {
    var body: some Widget {
        OttoChatWidget()
        OttoWalkieWidget()
    }
}

struct DoorEntry: TimelineEntry { let date: Date }

/// One entry, once: there is nothing on either widget that changes.
struct DoorProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoorEntry { DoorEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (DoorEntry) -> Void) { completion(DoorEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DoorEntry>) -> Void) {
        completion(Timeline(entries: [DoorEntry(date: .now)], policy: .never))
    }
}

struct OttoChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.otto.chat", provider: DoorProvider()) { _ in
            ChatDoor()
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
        StaticConfiguration(kind: "dev.otto.walkie", provider: DoorProvider()) { _ in
            WalkieDoor()
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
                .widgetURL(URL(string: "otto://walkie"))
        }
        .configurationDisplayName("Otto walkie-talkie")
        .description("Hold to talk to Otto, from the Lock Screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// The small tile: the face, the name, and what a tap does.
struct ChatDoor: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OttoFace(size: 48)
            Spacer(minLength: 8)
            Text("Otto").font(.headline)
            Text("Message").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Message Otto")
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
        Circle().fill(Color(red: 1, green: 0.486, blue: 0.102))   // #FF7C1A, the face's own tangerine
            .overlay { OttoEyes(size: size, colour: Color(white: 0.125)) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
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
