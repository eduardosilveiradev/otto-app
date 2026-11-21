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

/// What the removed "Otto is working" Live Activity carried. Nothing starts one any more; the type stays only so
/// the app can end one an older build left running (OttoApp's launch). Its shape must match theirs to read them.
struct WorkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var started: Date
        var needsYou = false
        var done = false
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

/// A talk with Otto while it lasts, on the Lock Screen and in the Dynamic Island. The app starts it and keeps
/// it current from its own process (TalkSession; the microphone keeps the app running), so it needs no push.
struct TalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Where the talk is ("Listening", "Working"), and the words that go with it: what Otto said, or its latest step.
        var title: String
        var line: String
        /// The SF Symbol for the island's compact side.
        var symbol: String
        var started: Date
        var muted = false
    }
}

/// The talk's own buttons on its Live Activity, run in the app (the app points `run` at the talk).
struct MuteOttoTalk: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or unmute the talk with Otto"
    static let isDiscoverable = false
    @MainActor static var run: () -> Void = {}
    @MainActor func perform() async throws -> some IntentResult { Self.run(); return .result() }
}

struct EndOttoTalk: LiveActivityIntent {
    static let title: LocalizedStringResource = "End the talk with Otto"
    static let isDiscoverable = false
    @MainActor static var run: () -> Void = {}
    @MainActor func perform() async throws -> some IntentResult { Self.run(); return .result() }
}

/// The Control Center (and Lock Screen) button: opens the app on talk mode. In both targets, as a control's
/// intent must be; with openAppWhenRun it runs in the app, which points `run` at talk. Still named for the
/// walkie-talkie it replaced, so controls already placed keep working.
struct OpenWalkieControl: AppIntent {
    static let title: LocalizedStringResource = "Talk with Otto"
    static let isDiscoverable = false
    static let openAppWhenRun = true
    @MainActor static var run: () -> Void = {}
    @MainActor func perform() async throws -> some IntentResult { Self.run(); return .result() }
}
