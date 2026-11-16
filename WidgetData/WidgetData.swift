import ActivityKit
import AppIntents
import Foundation

/// What the app hands its widgets, through the app group. Built into both the app and the widget extension.
enum WidgetData {
    private static let suite = UserDefaults(suiteName: "group.dev.otto.app")

    /// An approval waiting on the owner: what it asks, and when the Mac drops it.
    struct Ask: Codable, Equatable {
        let text: String
        let expires: Date
    }

    /// Written by the app while it runs. ponytail: one decided on the Mac while the app is suspended stays
    /// on the widget until it would have lapsed (30 minutes at most); a push would need APNs.
    static var ask: Ask? {
        get { suite?.data(forKey: "widgetAsk").flatMap { try? JSONDecoder().decode(Ask.self, from: $0) } }
        set { suite?.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "widgetAsk") }
    }
}

/// A web call with Otto, on the Lock Screen and in the Dynamic Island while it lasts. The app starts and
/// ends it (CallManager); nothing updates it from outside, so it needs no push.
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var started: Date
        var muted = false
    }
}

/// Otto at work on something that takes a while, on the Lock Screen and in the Dynamic Island. The app starts
/// it and keeps it current (WorkActivity); nothing reaches it from outside, so past its stale date it says
/// to open Otto instead of naming a step that may be over.
struct WorkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// What Otto is doing right now ("Reading mail", "Coding: fix the share sheet").
        var status: String
        var started: Date
        /// Something is waiting on the owner (an approval, a job's question): the tangerine mark, and a tap opens it.
        var needsYou = false
        var done = false
    }
}

/// The work activity's words for each of its states: working, waiting on you, done, and stale (the app was
/// suspended, so what it last knew may be old: it says where to look, not what it was).
struct WorkLine {
    let title: String, detail: String
    let needsYou: Bool, running: Bool
    var url: URL? { URL(string: needsYou ? "otto://approval" : "otto://chat") }

    init(_ s: WorkActivityAttributes.ContentState, stale: Bool) {
        needsYou = s.needsYou
        running = !s.done && !stale
        if s.done { title = "Otto is done"; detail = "The answer is in the chat." }
        else if stale { title = "Otto"; detail = "Open the app for where it’s got to." }
        else if s.needsYou { title = "Otto needs you"; detail = s.status }
        else { title = "Otto is working"; detail = s.status }
    }
}

/// The call's own buttons on its Live Activity. A LiveActivityIntent runs in the app, where the call is
/// (its audio keeps the app running); the app points `run` at the call, and in the widget it's never called.
struct MuteOttoCall: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or unmute the call with Otto"
    static let isDiscoverable = false
    @MainActor static var run: () -> Void = {}
    @MainActor func perform() async throws -> some IntentResult { Self.run(); return .result() }
}

struct HangUpOttoCall: LiveActivityIntent {
    static let title: LocalizedStringResource = "Hang up on Otto"
    static let isDiscoverable = false
    @MainActor static var run: () -> Void = {}
    @MainActor func perform() async throws -> some IntentResult { Self.run(); return .result() }
}

/// The Control Center (and Lock Screen) button: opens the app on the walkie-talkie. In both targets, as a
/// control's intent must be; with openAppWhenRun it runs in the app, which points `run` at the walkie.
struct OpenWalkieControl: AppIntent {
    static let title: LocalizedStringResource = "Otto walkie-talkie"
    static let isDiscoverable = false
    static let openAppWhenRun = true
    @MainActor static var run: () -> Void = {}
    @MainActor func perform() async throws -> some IntentResult { Self.run(); return .result() }
}
