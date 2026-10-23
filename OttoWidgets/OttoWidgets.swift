import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OttoWidgets: WidgetBundle {
    var body: some Widget { CrewLiveActivity() }
}

/// The crew run: how many are working, who spoke last and what they said, and how long it's been going.
/// Tapping it opens the crew overview.
struct CrewLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CrewActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.working == 1 ? "Crew · 1 working" : "Crew · \(context.state.working) working")
                        .font(.headline)
                    Text(context.state.line.isEmpty ? "Working…" : "\(context.state.who): \(context.state.line)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(context.state.since, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
            }
            .padding(16)
            .widgetURL(URL(string: "otto://crew"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.working)", systemImage: "person.3.sequence.fill")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.since, style: .timer)
                        .font(.caption.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.line.isEmpty ? "Working…" : "\(context.state.who): \(context.state.line)")
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "person.3.sequence.fill")
            } compactTrailing: {
                Text("\(context.state.working)").monospacedDigit()
            } minimal: {
                Image(systemName: "person.3.sequence.fill")
            }
            .widgetURL(URL(string: "otto://crew"))
        }
    }
}
