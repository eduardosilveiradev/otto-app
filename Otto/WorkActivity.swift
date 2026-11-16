import ActivityKit
import Foundation

/// Otto's work on the Lock Screen and in the Dynamic Island while it takes a while (WorkActivityAttributes;
/// drawn by OttoWorkActivity in the widget). The store's one-second tick calls `sync` with what is true now,
/// and this decides when that starts, changes or ends the activity.
///
/// No push: only the app can start or change it. So it starts from the foreground (iOS lets nothing else),
/// follows the work for as long as the app runs (keep-awake holds it in the background), and every update
/// sets it to go stale two minutes on. If iOS suspends the app after all, the activity says to open Otto
/// instead of showing a step that may be long over. Without keep-awake the app is suspended moments after it
/// leaves the screen, so the activity ends there and then.
@MainActor enum WorkActivity {
    private static var activity: Activity<WorkActivityAttributes>?
    /// When this stretch of work began, activity or not: one starts once it has lasted `patience`.
    private static var began: Date?
    private static var shown: WorkActivityAttributes.ContentState?
    private static var pushed = Date.distantPast
    static let patience: TimeInterval = 20

    /// `status` nil means Otto isn't working. `alive`: the app will go on running (in front, or kept awake).
    static func sync(status: String?, needsYou: Bool, foreground: Bool, alive: Bool, now: Date = .now) {
        guard let status, alive else {
            if status == nil { began = nil }
            guard let a = activity else { return }
            activity = nil
            let last = shown; shown = nil
            Task {
                // Done: its last frame says so for a few seconds. Leaving without keep-awake: gone at once.
                if status == nil, var done = last {
                    done.done = true; done.needsYou = needsYou
                    await a.end(.init(state: done, staleDate: nil), dismissalPolicy: .after(.now + 6))
                } else { await a.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        let start = began ?? now
        began = start
        let state = WorkActivityAttributes.ContentState(status: status, started: start, needsYou: needsYou)
        if activity == nil {
            guard starts(after: now.timeIntervalSince(start), foreground: foreground), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(attributes: WorkActivityAttributes(), content: content(state, now))
            shown = state; pushed = now
        } else if state != shown || now.timeIntervalSince(pushed) >= 60 {
            // Once a minute even with nothing new, to move the stale date on: silence then means the app was suspended.
            shown = state; pushed = now
            Task { [activity] in await activity?.update(content(state, now)) }
        }
    }

    /// Work shorter than `patience` never gets one, and nothing starts one from the background.
    nonisolated static func starts(after seconds: TimeInterval, foreground: Bool) -> Bool { foreground && seconds >= patience }

    private static func content(_ state: WorkActivityAttributes.ContentState, _ now: Date) -> ActivityContent<WorkActivityAttributes.ContentState> {
        .init(state: state, staleDate: now.addingTimeInterval(120))
    }

    /// At launch: one left over from a run that was killed mid-work describes nothing any more.
    static func endLeftovers() async {
        for a in Activity<WorkActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
