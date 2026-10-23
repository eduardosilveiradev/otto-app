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
            CrewActivityView(state: context.state)
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
            // The island's ends are round: without inset margins the line and the timer ran under the curve.
            .contentMargins(.horizontal, 16, for: .expanded)
            .contentMargins(.top, 8, for: .expanded)
            .widgetURL(URL(string: "otto://crew"))
        }
    }
}

/// The Lock Screen banner, and in StandBy (the phone on its side, charging) a full-screen
/// layout of its own instead of the banner scaled up: the count big, the timer, the last line.
/// At night StandBy dims and tints the screen red; reduced luminance drops the accent so it reads in that tint.
private struct CrewActivityView: View {
    let state: CrewActivityAttributes.ContentState
    @Environment(\.isActivityFullscreen) private var fullscreen
    @Environment(\.isLuminanceReduced) private var dimmed

    private var title: String { state.working == 1 ? "1 working" : "\(state.working) working" }
    private var line: String { state.line.isEmpty ? "Working…" : "\(state.who): \(state.line)" }

    var body: some View {
        if fullscreen { standBy } else { banner }
    }

    private var banner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.3.sequence.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Crew · \(title)").font(.headline)
                Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(state.since, style: .timer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
        }
        .padding(16)
    }

    // StandBy draws this at about twice its point size, so the sizes are Lock Screen sizes, and
    // everything may shrink rather than clip.
    private var standBy: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Label("Crew", systemImage: "person.3.sequence.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                Text("\(state.working)")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("working").font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                Text(state.since, style: .timer)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .minimumScaleFactor(0.7)
        .padding(14)
    }
}
