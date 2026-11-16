import ActivityKit
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
    }
}
