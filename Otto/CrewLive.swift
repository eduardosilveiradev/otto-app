import ActivityKit
import Foundation

/// Runs the crew's Live Activity from the app. iOS only lets an app start one while it is in the
/// foreground; updates also work from the background, which the keep-awake makes most of the time.
/// `update` returns false when there's no activity to show it on, and the caller falls back to the
/// quiet status notification.
@MainActor
enum CrewLive {
    private static var current: Activity<CrewActivityAttributes>? {
        Activity<CrewActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    @discardableResult
    static func update(working: Int, who: String? = nil, line: String? = nil) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        if let a = current {
            var s = a.content.state
            s.working = max(working, 1)
            if let who { s.who = who }
            if let line { s.line = line }
            Task { await a.update(ActivityContent(state: s, staleDate: nil)) }
            return true
        }
        let s = CrewActivityAttributes.ContentState(working: max(working, 1), who: who ?? "", line: line ?? "", since: .now)
        return (try? Activity.request(attributes: CrewActivityAttributes(), content: ActivityContent(state: s, staleDate: nil))) != nil
    }

    static func end() {
        for a in Activity<CrewActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
